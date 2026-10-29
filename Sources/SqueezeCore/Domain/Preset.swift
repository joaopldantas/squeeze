import Foundation

public enum WebResolution: Int, Hashable, Sendable, Codable, CaseIterable {
    case p720 = 720
    case p1080 = 1080

    /// Long edge for a 16:9 frame, so portrait videos are limited the same way as landscape ones.
    public var maxLongEdge: Int {
        switch self {
        case .p720: 1280
        case .p1080: 1920
        }
    }
}

public enum Preset: Hashable, Sendable, Codable {
    case highQuality
    case balanced
    case smallest
    /// H.264 for sharing in messengers and browsers.
    case web(WebResolution)
    /// Picks the bitrate so the file lands close to this size (decimal megabytes).
    case targetSize(megabytes: Double)
    /// Remux to MP4 without re-encoding.
    case original

    public static let `default`: Preset = .balanced

    /// What to offer when the output came out larger than the source.
    public var moreAggressive: Preset? {
        switch self {
        case .original, .highQuality: .balanced
        case .balanced: .smallest
        case .web(.p1080): .web(.p720)
        case .smallest, .web(.p720), .targetSize: nil
        }
    }
}

/// Manual settings from the "advanced" panel. `nil` means "use the preset's choice".
public struct EncodingOverrides: Hashable, Sendable, Codable {
    public var codec: VideoCodec?
    public var maxLongEdge: Int?
    public var frameRate: FrameRatePolicy?
    /// Video bits per second.
    public var videoBitrate: Int?
    public var audio: AudioPolicy?

    public init(
        codec: VideoCodec? = nil,
        maxLongEdge: Int? = nil,
        frameRate: FrameRatePolicy? = nil,
        videoBitrate: Int? = nil,
        audio: AudioPolicy? = nil
    ) {
        self.codec = codec
        self.maxLongEdge = maxLongEdge
        self.frameRate = frameRate
        self.videoBitrate = videoBitrate
        self.audio = audio
    }

    public static let none = EncodingOverrides()
}

/// The knobs each re-encoding preset turns.
struct PresetProfile: Equatable {
    var codec: VideoCodec
    /// HEVC bitrate for 1080p30 content with typical motion; scaled to the actual output.
    var referenceBitrate: Int
    var maxLongEdge: Int?
    var frameRate: FrameRatePolicy
    var audio: AudioPolicy
    /// Whether screen-recording detection may lower the bitrate.
    var adaptsToMotion: Bool

    static func profile(for preset: Preset) -> PresetProfile? {
        switch preset {
        case .highQuality:
            PresetProfile(
                codec: .hevc, referenceBitrate: 8_000_000, maxLongEdge: nil,
                frameRate: .keep, audio: .aac(bitrate: 192_000), adaptsToMotion: true
            )
        case .balanced:
            PresetProfile(
                codec: .hevc, referenceBitrate: 4_000_000, maxLongEdge: nil,
                frameRate: .keep, audio: .aac(bitrate: 128_000), adaptsToMotion: true
            )
        case .smallest:
            PresetProfile(
                codec: .hevc, referenceBitrate: 1_800_000, maxLongEdge: 1920,
                frameRate: .limit(30), audio: .aac(bitrate: 96_000), adaptsToMotion: true
            )
        case .web(let resolution):
            PresetProfile(
                codec: .h264, referenceBitrate: 4_000_000, maxLongEdge: resolution.maxLongEdge,
                frameRate: .limit(30), audio: .aac(bitrate: 128_000), adaptsToMotion: true
            )
        case .targetSize:
            PresetProfile(
                codec: .hevc, referenceBitrate: 4_000_000, maxLongEdge: nil,
                frameRate: .keep, audio: .aac(bitrate: 96_000), adaptsToMotion: false
            )
        case .original:
            nil
        }
    }
}
