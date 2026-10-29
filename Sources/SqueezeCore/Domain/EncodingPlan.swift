import Foundation

public struct VideoEncodingSettings: Hashable, Sendable, Codable {
    public var codec: VideoCodec
    public var size: PixelSize
    /// `nil` keeps every source frame.
    public var frameRateLimit: Int?
    /// Average bits per second.
    public var bitrate: Int
    /// Dynamic range written to the output; `.sdr` means HDR sources are tone-mapped.
    public var dynamicRange: DynamicRange
}

public struct AACSettings: Hashable, Sendable, Codable {
    public var bitrate: Int
    public var sampleRate: Double
    public var channelCount: Int
}

/// Things the user should know before (or after) converting.
public enum ConversionWarning: Hashable, Sendable, Codable {
    /// H.264 output can't carry HDR, so colours are converted to SDR.
    case hdrConvertedToSDR
    /// Re-encoding keeps the HDR base layer but drops Dolby Vision dynamic metadata.
    case dolbyVisionMetadataDropped(keptAs: DynamicRange)
    /// The source audio codec isn't allowed in MP4, so it is converted to AAC even in passthrough mode.
    case audioReencodedForMP4
}

/// Fully resolved instructions for one conversion.
public struct EncodingPlan: Hashable, Sendable, Codable {
    public enum Video: Hashable, Sendable, Codable {
        case passthrough
        case encode(VideoEncodingSettings)
    }

    public enum Audio: Hashable, Sendable, Codable {
        case none
        case passthrough
        case encode(AACSettings)
    }

    public var video: Video
    public var audio: Audio
    public var warnings: [ConversionWarning]

    public var isPassthrough: Bool { video == .passthrough }

    public var videoSettings: VideoEncodingSettings? {
        if case .encode(let settings) = video { return settings }
        return nil
    }

    public var audioSettings: AACSettings? {
        if case .encode(let settings) = audio { return settings }
        return nil
    }
}
