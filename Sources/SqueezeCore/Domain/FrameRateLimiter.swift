import Foundation

/// Decides which frames to keep so the output never exceeds a frame rate.
///
/// Works on presentation timestamps, so it also handles variable-frame-rate iPhone footage.
struct FrameRateLimiter: Sendable {
    let interval: Double
    private let tolerance: Double
    private var nextTimestamp: Double?

    init(maxFrameRate: Int) {
        interval = 1 / Double(max(1, maxFrameRate))
        // A quarter interval absorbs timestamp jitter without letting adjacent 60 fps frames through at 30 fps.
        tolerance = interval / 4
    }

    mutating func shouldKeep(timestamp: Double) -> Bool {
        if let nextTimestamp, timestamp < nextTimestamp - tolerance {
            return false
        }
        let next = (nextTimestamp ?? timestamp) + interval
        // After a gap (e.g. a dropped frame in the source) resynchronise instead of letting a burst through.
        nextTimestamp = next < timestamp ? timestamp + interval : next
        return true
    }
}
