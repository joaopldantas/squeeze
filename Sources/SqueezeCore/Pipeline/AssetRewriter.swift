@preconcurrency import AVFoundation
import Foundation
import os

/// One reader output feeding one writer input.
struct Lane: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let reportsProgress: Bool
    /// Mutable per-lane state. Only touched on the lane's own dispatch queue.
    let context: LaneContext
}

final class LaneContext: @unchecked Sendable {
    var frameRateLimiter: FrameRateLimiter?

    init(frameRateLimit: Int? = nil) {
        frameRateLimiter = frameRateLimit.map(FrameRateLimiter.init(maxFrameRate:))
    }

    func shouldKeep(_ timestamp: Double) -> Bool {
        frameRateLimiter?.shouldKeep(timestamp: timestamp) ?? true
    }
}

/// Moves samples from an `AVAssetReader` to an `AVAssetWriter`, lane by lane, with progress and cancellation.
///
/// Each lane is pumped with `requestMediaDataWhenReady` on its own serial queue, so audio and video are
/// interleaved by the writer's own back-pressure instead of a fixed schedule. Every suspension is bridged to
/// a checked continuation that is resumed exactly once, whether the lane drains, the writer fails or the
/// task is cancelled. `@unchecked Sendable` is sound because the AV objects are only used from those queues
/// (or before they start / after they finish), and shared state lives behind `state`'s lock.
final class AssetRewriter: @unchecked Sendable {
    private struct State {
        var isCancelled = false
        var finishedLanes: Set<Int> = []
        var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
        var furthestTimestamp = 0.0
        var lastReportedProgress = -1.0
    }

    private static let progressGranularity = 0.005

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let lanes: [Lane]
    private let duration: Double
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(reader: AVAssetReader, writer: AVAssetWriter, lanes: [Lane], duration: Double) {
        self.reader = reader
        self.writer = writer
        self.lanes = lanes
        self.duration = duration
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await transfer(progress: progress)
        } onCancel: {
            cancel()
        }
    }

    private func transfer(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard reader.startReading() else { throw failure(reader.error) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw failure(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for index in lanes.indices {
                group.addTask { await self.pump(index, progress: progress) }
            }
        }

        if state.withLock(\.isCancelled) {
            abort()
            throw SqueezeError.cancelled
        }
        if writer.status == .failed {
            reader.cancelReading()
            throw failure(writer.error)
        }
        if reader.status == .failed {
            abort()
            throw failure(reader.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw failure(writer.error) }
    }

    private func abort() {
        reader.cancelReading()
        if writer.status == .writing {
            writer.cancelWriting()
        }
    }

    private func failure(_ error: (any Error)?) -> SqueezeError {
        error.map(SqueezeError.classify) ?? .encodingFailed(reason: "Status de leitura/escrita inesperado")
    }

    // MARK: Lanes

    private func pump(_ index: Int, progress: @escaping @Sendable (Double) -> Void) async {
        let lane = lanes[index]
        let queue = DispatchQueue(label: "app.squeeze.lane.\(index)", qos: .userInitiated)
        await withCheckedContinuation { continuation in
            guard register(continuation, for: index) else { return }
            lane.input.requestMediaDataWhenReady(on: queue) { [self] in
                drain(index, progress: progress)
            }
        }
    }

    /// Called on the lane's queue whenever the writer input can take more data.
    private func drain(_ index: Int, progress: @Sendable (Double) -> Void) {
        let lane = lanes[index]
        while lane.input.isReadyForMoreMediaData {
            guard !isFinished(index) else { return }
            guard let sample = lane.output.copyNextSampleBuffer() else {
                if !isFinished(index) {
                    lane.input.markAsFinished()
                }
                finish(index)
                return
            }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard lane.context.shouldKeep(timestamp) else { continue }
            guard lane.input.append(sample) else {
                // The writer failed; nothing else can be written, so release every lane.
                finishAll()
                return
            }
            if lane.reportsProgress {
                report(timestamp, to: progress)
            }
        }
    }

    /// Stores the continuation, or resumes it immediately if the job was already cancelled.
    private func register(_ continuation: CheckedContinuation<Void, Never>, for index: Int) -> Bool {
        let accepted = state.withLock { state in
            guard !state.isCancelled, !state.finishedLanes.contains(index) else { return false }
            state.continuations[index] = continuation
            return true
        }
        if !accepted {
            continuation.resume()
        }
        return accepted
    }

    private func isFinished(_ index: Int) -> Bool {
        state.withLock { $0.finishedLanes.contains(index) }
    }

    private func finish(_ index: Int) {
        let continuation = state.withLock { state in
            state.finishedLanes.insert(index)
            return state.continuations.removeValue(forKey: index)
        }
        continuation?.resume()
    }

    private func finishAll() {
        let continuations = state.withLock { state in
            state.finishedLanes.formUnion(lanes.indices)
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        continuations.forEach { $0.resume() }
    }

    private func cancel() {
        state.withLock { $0.isCancelled = true }
        finishAll()
        reader.cancelReading()
    }

    private func report(_ timestamp: Double, to progress: @Sendable (Double) -> Void) {
        guard duration > 0, timestamp.isFinite else { return }
        let value: Double? = state.withLock { state in
            // B-frames arrive out of presentation order, so track the furthest point reached.
            state.furthestTimestamp = max(state.furthestTimestamp, timestamp)
            let fraction = min(1, state.furthestTimestamp / duration)
            guard fraction - state.lastReportedProgress >= Self.progressGranularity else { return nil }
            state.lastReportedProgress = fraction
            return fraction
        }
        if let value {
            progress(value)
        }
    }
}
