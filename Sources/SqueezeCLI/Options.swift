import ArgumentParser
import SqueezeCore

/// Preset names as typed on the command line.
enum PresetChoice: String, CaseIterable, ExpressibleByArgument {
    case high
    case balanced
    case smallest
    case web720
    case web1080
    case original

    var preset: Preset {
        switch self {
        case .high: .highQuality
        case .balanced: .balanced
        case .smallest: .smallest
        case .web720: .web(.p720)
        case .web1080: .web(.p1080)
        case .original: .original
        }
    }
}

enum CodecChoice: String, CaseIterable, ExpressibleByArgument {
    case hevc
    case h264

    var codec: VideoCodec {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        }
    }
}

enum FrameRateChoice: String, CaseIterable, ExpressibleByArgument {
    case keep
    case fps30 = "30"
    case fps60 = "60"

    var policy: FrameRatePolicy {
        switch self {
        case .keep: .keep
        case .fps30: .limit(30)
        case .fps60: .limit(60)
        }
    }
}

extension PresetChoice {
    /// The CLI spelling of a core preset, for suggestions like "tente --preset smallest".
    init?(_ preset: Preset) {
        guard let match = Self.allCases.first(where: { $0.preset == preset }) else { return nil }
        self = match
    }
}
