import Foundation

public struct ConversionRequest: Hashable, Sendable {
    public var source: URL
    public var preset: Preset
    public var overrides: EncodingOverrides
    public var output: OutputLocation

    public init(
        source: URL,
        preset: Preset = .default,
        overrides: EncodingOverrides = .none,
        output: OutputLocation = .besideOriginal
    ) {
        self.source = source
        self.preset = preset
        self.overrides = overrides
        self.output = output
    }
}

/// What the user sees before converting: source facts, the resolved plan and the size estimate.
public struct ConversionPreview: Hashable, Sendable {
    public var request: ConversionRequest
    public var info: MediaInfo
    public var motion: MotionLevel
    public var plan: EncodingPlan
    public var estimate: SizeComparison

    public init(
        request: ConversionRequest,
        info: MediaInfo,
        motion: MotionLevel,
        plan: EncodingPlan,
        estimate: SizeComparison
    ) {
        self.request = request
        self.info = info
        self.motion = motion
        self.plan = plan
        self.estimate = estimate
    }
}

public struct ConversionResult: Hashable, Sendable {
    public var outputURL: URL
    public var info: MediaInfo
    public var plan: EncodingPlan
    public var comparison: SizeComparison
    public var elapsed: Duration

    /// Set when a re-encode came out larger than the source: the preset to offer instead.
    public var suggestedPreset: Preset?
    /// The plan's warnings, minus any the finished file proved unnecessary.
    public var warnings: [ConversionWarning]

    public init(
        outputURL: URL,
        info: MediaInfo,
        plan: EncodingPlan,
        comparison: SizeComparison,
        elapsed: Duration,
        suggestedPreset: Preset? = nil,
        warnings: [ConversionWarning] = []
    ) {
        self.outputURL = outputURL
        self.info = info
        self.plan = plan
        self.comparison = comparison
        self.elapsed = elapsed
        self.suggestedPreset = suggestedPreset
        self.warnings = warnings
    }

    public var outputGrewUnexpectedly: Bool {
        VideoCompressor.outputGrewUnexpectedly(comparison, plan: plan)
    }
}

/// Entry point of SqueezeCore: inspect → analyse → plan → rewrite → place.
public struct VideoCompressor: Sendable {
    private let inspector: MediaInspector
    private let motionAnalyzer: MotionAnalyzer
    private let planner: EncodingPlanner

    public init(
        inspector: MediaInspector = MediaInspector(),
        motionAnalyzer: MotionAnalyzer = MotionAnalyzer(),
        planner: EncodingPlanner = EncodingPlanner()
    ) {
        self.inspector = inspector
        self.motionAnalyzer = motionAnalyzer
        self.planner = planner
    }

    /// Reads the file (tracks, motion) and plans the conversion. Motion is always analysed, so the
    /// preview can later be re-planned for any preset with `replan(_:for:)` without touching the file again.
    public func preview(_ request: ConversionRequest) async throws -> ConversionPreview {
        do {
            let info = try await inspector.inspect(request.source)
            let motion = await motionAnalyzer.analyze(request.source, duration: info.duration)
            return try plan(request, info: info, motion: motion)
        } catch {
            throw SqueezeError.classify(error)
        }
    }

    /// Plans `request` from facts a previous preview already gathered. Synchronous and cheap:
    /// meant for updating estimates live while the user changes settings.
    public func replan(_ preview: ConversionPreview, for request: ConversionRequest) throws -> ConversionPreview {
        do {
            return try plan(request, info: preview.info, motion: preview.motion)
        } catch {
            throw SqueezeError.classify(error)
        }
    }

    private func plan(_ request: ConversionRequest, info: MediaInfo, motion: MotionLevel) throws -> ConversionPreview {
        let plan = try planner.plan(for: request.preset, source: info, motion: motion, overrides: request.overrides)
        let estimate = SizeComparison(
            originalBytes: info.fileSize,
            outputBytes: SizeEstimator.estimatedBytes(for: plan, source: info)
        )
        return ConversionPreview(request: request, info: info, motion: motion, plan: plan, estimate: estimate)
    }

    /// Converts `request.source`. Pass a `preview` computed earlier to skip inspecting the file again.
    ///
    /// Cancelling the calling task stops the job and removes every temporary file.
    public func compress(
        _ request: ConversionRequest,
        preview: ConversionPreview? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ConversionResult {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let preview = if let preview, preview.request == request {
                preview
            } else {
                try await self.preview(request)
            }
            try Task.checkCancellation()

            let directory = request.output.directory(for: request.source)
            if let available = Self.availableCapacity(at: directory) {
                try SqueezeError.checkDiskSpace(estimatedBytes: preview.estimate.outputBytes, availableBytes: available)
            }

            let workspace = try OutputWorkspace(near: directory)
            defer { workspace.cleanUp() }

            let rewriter = try await AssetRewriter.make(
                for: preview.plan, source: preview.info, outputURL: workspace.temporaryFileURL
            )
            let skippedSeconds = try await rewriter.run(progress: progress)
            try Task.checkCancellation()

            let outputURL = try workspace.claimFinalURL(for: request.source, in: directory)
            Self.copyFileDates(from: request.source, to: outputURL)
            progress(1)

            let comparison = SizeComparison(originalBytes: preview.info.fileSize, outputBytes: Self.fileSize(outputURL))
            return ConversionResult(
                outputURL: outputURL,
                info: preview.info,
                plan: preview.plan,
                comparison: comparison,
                elapsed: clock.now - start,
                suggestedPreset: Self.outputGrewUnexpectedly(comparison, plan: preview.plan)
                    ? request.preset.moreAggressive
                    : nil,
                warnings: await confirmedWarnings(preview.plan.warnings, outputURL: outputURL)
                    + (skippedSeconds > 0 ? [.damagedEndSkipped(seconds: skippedSeconds)] : [])
            )
        } catch {
            throw SqueezeError.classify(error)
        }
    }

    // MARK: Helpers

    /// A remux only adds container overhead (well under 1%), which isn't worth a warning.
    static func outputGrewUnexpectedly(_ comparison: SizeComparison, plan: EncodingPlan) -> Bool {
        comparison.outputIsLarger && !(plan.isPassthrough && comparison.savedFraction > -0.01)
    }

    /// Recent VideoToolbox versions regenerate Dolby Vision 8.4 metadata when encoding HLG,
    /// so the "Dolby Vision dropped" warning is only kept if the output really lost it.
    private func confirmedWarnings(_ warnings: [ConversionWarning], outputURL: URL) async -> [ConversionWarning] {
        let droppedDolbyVision = warnings.contains { warning in
            if case .dolbyVisionMetadataDropped = warning { return true }
            return false
        }
        guard droppedDolbyVision,
              (try? await inspector.inspect(outputURL))?.video.dynamicRange == .dolbyVision
        else { return warnings }
        return warnings.filter { warning in
            if case .dolbyVisionMetadataDropped = warning { return false }
            return true
        }
    }

    private static func availableCapacity(at directory: URL) -> Int64? {
        // The destination may not exist yet; measure the closest existing ancestor on the same volume.
        var url = directory
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// Keeps Finder's "Created" date, so compressed clips sort next to their originals.
    private static func copyFileDates(from source: URL, to destination: URL) {
        guard let created = try? source.resourceValues(forKeys: [.creationDateKey]).creationDate else { return }
        try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: destination.path)
    }
}
