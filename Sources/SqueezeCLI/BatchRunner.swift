import Foundation
import SqueezeCore

struct BatchSummary: Equatable {
    var succeeded = 0
    var failed = 0
    var cancelled = false
    var total = SizeComparison(originalBytes: 0, outputBytes: 0)
}

/// Converts files one after another. Ctrl-C cancels the current job (cleaning up its temporary
/// file) and skips the rest, instead of killing the process mid-write.
struct BatchRunner {
    let compressor = VideoCompressor()
    let reporter: Reporter
    let dryRun: Bool

    func run(_ requests: [ConversionRequest]) async -> BatchSummary {
        let interrupt = InterruptHandler()
        defer { interrupt.stop() }
        var summary = BatchSummary()

        for (index, request) in requests.enumerated() {
            guard !interrupt.isInterrupted else {
                summary.cancelled = true
                break
            }
            reporter.start(request, index: index + 1, count: requests.count)
            let task = Task { [compressor, reporter, dryRun] in
                try await Self.process(request, compressor: compressor, reporter: reporter, dryRun: dryRun)
            }
            interrupt.track(task)

            do {
                if let result = try await task.value {
                    summary.succeeded += 1
                    summary.total.originalBytes += result.comparison.originalBytes
                    summary.total.outputBytes += result.comparison.outputBytes
                }
            } catch {
                let error = SqueezeError.classify(error)
                reporter.failed(error)
                if error == .cancelled {
                    summary.cancelled = true
                    break
                }
                summary.failed += 1
            }
        }
        if !dryRun || summary.failed > 0 {
            reporter.summary(summary)
        }
        return summary
    }

    /// Returns `nil` in dry-run mode.
    private static func process(
        _ request: ConversionRequest,
        compressor: VideoCompressor,
        reporter: Reporter,
        dryRun: Bool
    ) async throws -> ConversionResult? {
        let preview = try await compressor.preview(request)
        reporter.preview(preview)
        guard !dryRun else { return nil }
        let result = try await compressor.compress(request, preview: preview) { reporter.progress($0) }
        reporter.finished(result)
        return result
    }
}

/// Turns SIGINT into task cancellation for the job currently running.
final class InterruptHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Task<ConversionResult?, any Error>?
    private var interrupted = false
    private let source: DispatchSourceSignal

    init() {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in self?.interrupt() }
        source.resume()
    }

    var isInterrupted: Bool {
        lock.withLock { interrupted }
    }

    func track(_ task: Task<ConversionResult?, any Error>) {
        lock.withLock {
            current = task
            if interrupted { task.cancel() }
        }
    }

    func stop() {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }

    private func interrupt() {
        lock.withLock {
            // A second Ctrl-C means "really quit now".
            if interrupted { Darwin.exit(130) }
            interrupted = true
            current?.cancel()
        }
    }
}
