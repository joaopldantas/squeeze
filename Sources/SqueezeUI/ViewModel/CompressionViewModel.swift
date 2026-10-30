import Foundation
import Observation
import SqueezeCore
import UniformTypeIdentifiers

/// What one batch achieved, for the end-of-batch notification.
public struct BatchReport: Equatable, Sendable {
    public var completed = 0
    public var failed = 0
    public var cancelled = 0
    public var sizes = SizeComparison(originalBytes: 0, outputBytes: 0)

    public init() {}

    mutating func record(_ phase: QueueItem.Phase) {
        switch phase {
        case .completed(let result):
            completed += 1
            sizes.originalBytes += result.comparison.originalBytes
            sizes.outputBytes += result.comparison.outputBytes
        case .failed: failed += 1
        case .cancelled: cancelled += 1
        default: break
        }
    }
}

/// Totals shown in the bottom bar.
public struct QueueSummary: Equatable, Sendable {
    /// Files not converted yet that can be: current size → estimated size.
    public var pendingCount = 0
    public var pending = SizeComparison(originalBytes: 0, outputBytes: 0)
    public var completedCount = 0
    public var completed = SizeComparison(originalBytes: 0, outputBytes: 0)
}

/// Owns the list of files and drives analysis and conversion. Views only read state and call intents.
///
/// Work is pulled from the list by small loops ("pumps") instead of being scheduled up front, so files
/// added, removed or cancelled mid-batch need no special bookkeeping: each loop just picks the next match.
@MainActor
@Observable
public final class CompressionViewModel {
    public private(set) var items: [QueueItem] = []
    public var settings: CompressionSettings {
        didSet {
            guard settings != oldValue else { return }
            store?.save(settings)
            replanAll()
        }
    }
    /// A short message about the last action, e.g. files that were skipped.
    public private(set) var notice: String?

    /// Called when a batch starts. The app asks for notification permission here, in context.
    public var onBatchStarted: (@MainActor () -> Void)?
    /// Called when a batch drains, with what it achieved. The app uses it for the notification.
    public var onBatchFinished: (@MainActor (BatchReport) -> Void)?

    private let compressor: any VideoCompressing
    private let thumbnails: any ThumbnailProviding
    private let store: (any SettingsStoring)?
    private var analysisLoop: Task<Void, Never>?
    private var conversionLoop: Task<Void, Never>?
    private var batch = BatchReport()

    public init(
        compressor: any VideoCompressing = VideoCompressor(),
        thumbnails: any ThumbnailProviding = VideoThumbnailProvider(),
        store: (any SettingsStoring)? = UserDefaultsSettingsStore()
    ) {
        self.compressor = compressor
        self.thumbnails = thumbnails
        self.store = store
        self.settings = store?.load() ?? CompressionSettings()
    }

    // MARK: State

    public var isConverting: Bool { conversionLoop != nil }

    public var canConvert: Bool { items.contains(where: \.canConvert) }

    public var summary: QueueSummary {
        var summary = QueueSummary()
        for item in items {
            if let result = item.result {
                summary.completedCount += 1
                summary.completed.originalBytes += result.comparison.originalBytes
                summary.completed.outputBytes += result.comparison.outputBytes
            } else if let preview = item.preview, item.planError == nil, item.phase != .analyzing {
                summary.pendingCount += 1
                summary.pending.originalBytes += preview.estimate.originalBytes
                summary.pending.outputBytes += preview.estimate.outputBytes
            }
        }
        return summary
    }

    // MARK: Adding and removing

    /// Adds videos (and the videos directly inside dropped folders), skipping duplicates and other files.
    public func add(_ urls: [URL]) {
        let known = Set(items.map(\.url.standardizedFileURL))
        var added = 0
        var skipped = 0
        for url in urls.flatMap(Self.expandFolders) {
            let standardized = url.standardizedFileURL
            guard Self.isVideo(standardized) else {
                skipped += 1
                continue
            }
            guard !known.contains(standardized), !items.contains(where: { $0.url == standardized }) else { continue }
            items.append(QueueItem(url: standardized))
            added += 1
        }
        notice = skipped > 0 ? "\(skipped) arquivo(s) ignorado(s): não são vídeos." : nil
        if added > 0 {
            startAnalysis()
        }
    }

    public func remove(_ item: QueueItem) {
        cancel(item)
        items.removeAll { $0.id == item.id }
    }

    public func clearCompleted() {
        items.removeAll { $0.result != nil }
    }

    /// The Finder action: add the files and convert them with the current settings, no further clicks.
    public func addAndConvert(_ urls: [URL]) {
        let before = Set(items.map(\.id))
        add(urls)
        for item in items where !before.contains(item.id) {
            item.convertsWhenReady = true
        }
    }

    public func dismissNotice() {
        notice = nil
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie)
    }

    private static func expandFolders(_ url: URL) -> [URL] {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return [url] }
        let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return (contents ?? []).filter(isVideo).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Converting

    public func convertAll() {
        for item in items where item.canConvert {
            item.phase = .queued
        }
        startConversions()
    }

    public func convert(_ item: QueueItem) {
        guard item.canConvert else { return }
        item.phase = .queued
        startConversions()
    }

    /// Converts this file again with a more aggressive preset (offered when the output grew).
    public func retry(_ item: QueueItem, with preset: Preset) {
        guard !item.isBusy else { return }
        item.presetOverride = preset
        replan(item)
        if item.planError == nil {
            item.phase = .queued
            startConversions()
        }
    }

    public func cancel(_ item: QueueItem) {
        switch item.phase {
        case .queued:
            item.phase = .ready
        case .converting:
            item.conversion?.cancel()
        default:
            break
        }
    }

    public func cancelAll() {
        items.filter(\.isBusy).forEach(cancel)
    }

    /// Starts `maxConcurrentJobs` workers that each claim the next queued file until none is left.
    private func startConversions() {
        guard conversionLoop == nil else { return }
        batch = BatchReport()
        onBatchStarted?()
        let workers = settings.maxConcurrentJobs
        conversionLoop = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<workers {
                    group.addTask { [weak self] in await self?.work() }
                }
            }
            guard let self else { return }
            self.conversionLoop = nil
            self.onBatchFinished?(self.batch)
        }
    }

    private func work() async {
        while let next = claimNext() {
            await run(next)
        }
    }

    /// Marks the next queued file as converting before any suspension, so two workers can't take the same one.
    private func claimNext() -> QueueItem? {
        guard let next = items.first(where: { $0.phase == .queued }) else { return nil }
        next.phase = .converting(progress: 0)
        return next
    }

    private func run(_ item: QueueItem) async {
        guard let preview = item.preview else {
            item.phase = .ready
            return
        }
        let compressor = compressor
        let request = preview.request
        let task = Task { @MainActor [weak item] in
            do {
                let result = try await compressor.compress(request, preview: preview) { fraction in
                    Task { @MainActor in
                        // Progress callbacks can arrive after completion; never overwrite a final state.
                        if case .converting = item?.phase { item?.phase = .converting(progress: fraction) }
                    }
                }
                item?.phase = .completed(result)
            } catch {
                let error = SqueezeError.classify(error)
                item?.phase = error == .cancelled ? .cancelled : .failed(error)
            }
        }
        item.conversion = task
        await task.value
        item.conversion = nil
        batch.record(item.phase)
    }

    // MARK: Analysis and planning

    private func startAnalysis() {
        guard analysisLoop == nil else { return }
        analysisLoop = Task { [weak self] in
            while let self, let next = self.items.first(where: { $0.phase == .analyzing }) {
                await self.analyze(next)
            }
            self?.analysisLoop = nil
        }
    }

    private func analyze(_ item: QueueItem) async {
        item.thumbnail = await thumbnails.thumbnail(for: item.url, maxPixelSize: 320)
        do {
            // Balanced never fails to plan, so this only fails if the file itself is unusable;
            // the real settings are applied right after by `replan`.
            item.analysis = try await compressor.preview(ConversionRequest(source: item.url, preset: .balanced))
            item.phase = .ready
            replan(item)
            if item.convertsWhenReady {
                convert(item)
            }
        } catch {
            item.phase = .failed(SqueezeError.classify(error))
        }
    }

    private func replanAll() {
        for item in items where !item.isBusy && item.result == nil {
            item.presetOverride = nil
            replan(item)
        }
    }

    private func replan(_ item: QueueItem) {
        guard let analysis = item.analysis else { return }
        let request = settings.request(for: item.url, preset: item.presetOverride)
        do {
            item.preview = try compressor.replan(analysis, for: request)
            item.planError = nil
        } catch {
            item.preview = nil
            item.planError = SqueezeError.classify(error)
        }
    }
}
