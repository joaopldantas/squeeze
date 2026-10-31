import Foundation
import SqueezeCore
@testable import SqueezeUI

/// A compressor whose behaviour each test scripts: which files fail, whether a job blocks until cancelled.
final class FakeCompressor: VideoCompressing, @unchecked Sendable {
    private let lock = NSLock()
    private let real = VideoCompressor()
    private var _unreadable: Set<String> = []
    private var _failing: [String: SqueezeError] = [:]
    private var _blocking: Set<String> = []
    private var _growing: Set<String> = []
    private var _compressed: [(name: String, preset: Preset)] = []

    func markUnreadable(_ name: String) { lock.withLock { _ = _unreadable.insert(name) } }
    func fail(_ name: String, with error: SqueezeError) { lock.withLock { _failing[name] = error } }
    func block(_ name: String) { lock.withLock { _ = _blocking.insert(name) } }
    func grow(_ name: String) { lock.withLock { _ = _growing.insert(name) } }

    var compressed: [(name: String, preset: Preset)] { lock.withLock { _compressed } }

    func preview(_ request: ConversionRequest) async throws -> ConversionPreview {
        let name = request.source.lastPathComponent
        if lock.withLock({ _unreadable.contains(name) }) {
            throw SqueezeError.unreadableFile(reason: "fake")
        }
        let info = MediaInfo.sample(url: request.source)
        let plan = try EncodingPlanner().plan(for: request.preset, source: info, overrides: request.overrides)
        let estimate = SizeComparison(
            originalBytes: info.fileSize,
            outputBytes: SizeEstimator.estimatedBytes(for: plan, source: info)
        )
        return ConversionPreview(request: request, info: info, motion: .normal, plan: plan, estimate: estimate)
    }

    func replan(_ preview: ConversionPreview, for request: ConversionRequest) throws -> ConversionPreview {
        try real.replan(preview, for: request)
    }

    func compress(
        _ request: ConversionRequest,
        preview: ConversionPreview?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult {
        let name = request.source.lastPathComponent
        let (failure, blocks, grows) = lock.withLock {
            _compressed.append((name, request.preset))
            return (_failing[name], _blocking.contains(name), _growing.contains(name))
        }
        progress(0.5)
        if blocks {
            while true {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        if let failure { throw failure }

        let preview = try await self.preview(request)
        let original = preview.info.fileSize
        let output = grows ? original + 1_000 : preview.estimate.outputBytes
        return ConversionResult(
            outputURL: request.source.deletingPathExtension().appendingPathExtension("mp4"),
            info: preview.info,
            plan: preview.plan,
            comparison: SizeComparison(originalBytes: original, outputBytes: output),
            elapsed: .seconds(1),
            suggestedPreset: grows ? request.preset.moreAggressive : nil
        )
    }
}

struct NoThumbnails: ThumbnailProviding {
    func thumbnail(for url: URL, maxPixelSize: Int) async -> Thumbnail? { nil }
}

final class MemorySettingsStore: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CompressionSettings?

    init(_ settings: CompressionSettings? = nil) {
        stored = settings
    }

    var saved: CompressionSettings? { lock.withLock { stored } }

    func load() -> CompressionSettings? { lock.withLock { stored } }
    func save(_ settings: CompressionSettings) { lock.withLock { stored = settings } }
}

extension MediaInfo {
    /// A 60 s 1080p30 HEVC file at 40 Mbps with AAC audio (~301 MB).
    static func sample(url: URL) -> MediaInfo {
        MediaInfo(
            url: url,
            fileSize: 301_920_000,
            duration: 60,
            video: VideoTrackInfo(
                codec: "hvc1", naturalSize: PixelSize(width: 1920, height: 1080), frameRate: 30, bitrate: 40_000_000
            ),
            audio: AudioTrackInfo(format: "aac ", bitrate: 256_000, sampleRate: 48_000, channelCount: 2)
        )
    }
}

/// Polls the main actor until `condition` holds, failing after `timeout`.
@MainActor
func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

final class FakeTrash: FileTrashing, @unchecked Sendable {
    private let lock = NSLock()
    private var _trashed: [URL] = []
    private var _fails = false

    var trashed: [URL] { lock.withLock { _trashed } }
    func failEverything() { lock.withLock { _fails = true } }

    func trash(_ url: URL) throws {
        try lock.withLock {
            if _fails { throw CocoaError(.fileWriteNoPermission) }
            _trashed.append(url)
        }
    }
}
