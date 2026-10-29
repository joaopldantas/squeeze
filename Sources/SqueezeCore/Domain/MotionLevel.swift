import Foundation

/// How much the picture changes over time. Screen recordings are usually `.low`.
public enum MotionLevel: String, Hashable, Sendable, Codable {
    case low
    case normal
    case high

    static let lowThreshold = 0.03
    static let highThreshold = 0.30

    var bitrateFactor: Double {
        switch self {
        case .low: 0.55
        case .normal: 1.0
        case .high: 1.15
        }
    }

    /// Classifies by the median share of pixels that changed between sampled frame pairs.
    /// The median keeps a single scene cut from making a static recording look busy.
    public static func classify(changedFractions: [Double]) -> MotionLevel {
        guard !changedFractions.isEmpty else { return .normal }
        let sorted = changedFractions.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        switch median {
        case ..<lowThreshold: return .low
        case highThreshold...: return .high
        default: return .normal
        }
    }

    /// Share of pixels whose luma differs by more than `threshold` between two equally sized frames.
    public static func changedFraction(_ lhs: [UInt8], _ rhs: [UInt8], threshold: UInt8 = 12) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let limit = Int(threshold)
        var changed = 0
        for index in lhs.indices where abs(Int(lhs[index]) - Int(rhs[index])) > limit {
            changed += 1
        }
        return Double(changed) / Double(lhs.count)
    }
}
