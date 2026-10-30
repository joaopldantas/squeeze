import Foundation

/// How two sampled frames differ, as shares of their pixels.
public struct FrameDifference: Hashable, Sendable {
    /// Pixels whose luma moved more than the noise threshold: real motion.
    public var changed: Double
    /// Pixels that are (almost) bit-identical. Screen content stays pixel-exact between frames;
    /// camera footage never does, because of sensor grain and subtle movement.
    public var identical: Double

    public init(changed: Double, identical: Double) {
        self.changed = changed
        self.identical = identical
    }

    /// Compares two equally sized greyscale frames. Mismatched sizes count as "no information".
    public init(_ lhs: [UInt8], _ rhs: [UInt8], threshold: UInt8 = 12) {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            self.init(changed: 0, identical: 0)
            return
        }
        let limit = Int(threshold)
        var changed = 0
        var identical = 0
        for index in lhs.indices {
            let delta = abs(Int(lhs[index]) - Int(rhs[index]))
            if delta > limit { changed += 1 }
            if delta <= 1 { identical += 1 }
        }
        let count = Double(lhs.count)
        self.init(changed: Double(changed) / count, identical: Double(identical) / count)
    }
}

/// How much the picture changes over time. Screen recordings are usually `.low`.
public enum MotionLevel: String, Hashable, Sendable, Codable {
    case low
    case normal
    case high

    static let lowChangedThreshold = 0.03
    static let lowIdenticalThreshold = 0.97
    static let highChangedThreshold = 0.30

    var bitrateFactor: Double {
        switch self {
        case .low: 0.55
        case .normal: 1.0
        case .high: 1.15
        }
    }

    /// Classifies by the medians over sampled frame pairs; the median keeps a single scene cut
    /// from making a static recording look busy.
    ///
    /// `.low` needs both little change *and* pixel-exact stillness: a slow aerial pan barely changes
    /// either, but its grain means only ~85% of pixels repeat, and starving it of bits shows.
    public static func classify(_ samples: [FrameDifference]) -> MotionLevel {
        guard !samples.isEmpty else { return .normal }
        let changed = median(samples.map(\.changed))
        let identical = median(samples.map(\.identical))
        if changed >= highChangedThreshold { return .high }
        if changed < lowChangedThreshold, identical >= lowIdenticalThreshold { return .low }
        return .normal
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
