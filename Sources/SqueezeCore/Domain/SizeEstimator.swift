import Foundation

public enum SizeEstimator {
    /// Expected output size in bytes. Encoders in average-bitrate mode land close to the target,
    /// usually slightly under it on static content, so this is a reasonable upper estimate.
    public static func estimatedBytes(for plan: EncodingPlan, source: MediaInfo) -> Int64 {
        let videoBitrate: Int = switch plan.video {
        case .passthrough: source.video.bitrate
        case .encode(let settings): settings.bitrate
        }
        let totalBitrate = Double(videoBitrate + plan.audio.bitrate(source: source.audio))
        let payload = totalBitrate * max(0, source.duration) / 8
        return Int64((payload * (1 + BitrateCalculator.containerOverhead)).rounded())
    }
}

/// Before/after size, as shown in the queue.
public struct SizeComparison: Hashable, Sendable, Codable {
    public var originalBytes: Int64
    public var outputBytes: Int64

    public init(originalBytes: Int64, outputBytes: Int64) {
        self.originalBytes = originalBytes
        self.outputBytes = outputBytes
    }

    public var savedBytes: Int64 { originalBytes - outputBytes }

    /// 0.75 means "75% smaller". Negative when the output grew.
    public var savedFraction: Double {
        guard originalBytes > 0 else { return 0 }
        return Double(savedBytes) / Double(originalBytes)
    }

    public var outputIsLarger: Bool { outputBytes > originalBytes }
}
