import Foundation

/// CoreMedia colour tags as their raw string values (e.g. `ITU_R_709_2`), kept framework-free for testability.
public struct ColorDescription: Hashable, Sendable, Codable {
    public var primaries: String?
    public var transferFunction: String?
    public var yCbCrMatrix: String?

    public init(primaries: String? = nil, transferFunction: String? = nil, yCbCrMatrix: String? = nil) {
        self.primaries = primaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
    }
}

public struct VideoTrackInfo: Hashable, Sendable, Codable {
    /// Four-character codec code, e.g. `hvc1`, `avc1`, `apcn`.
    public var codec: String
    /// Encoded size, before the track's preferred transform is applied.
    public var naturalSize: PixelSize
    /// Size as shown to the viewer (portrait videos have width and height swapped).
    public var displaySize: PixelSize
    public var frameRate: Double
    /// Average bits per second; 0 when the container doesn't report it.
    public var bitrate: Int
    public var dynamicRange: DynamicRange
    public var color: ColorDescription

    public init(
        codec: String,
        naturalSize: PixelSize,
        displaySize: PixelSize? = nil,
        frameRate: Double,
        bitrate: Int,
        dynamicRange: DynamicRange = .sdr,
        color: ColorDescription = ColorDescription()
    ) {
        self.codec = codec
        self.naturalSize = naturalSize
        self.displaySize = displaySize ?? naturalSize
        self.frameRate = frameRate
        self.bitrate = bitrate
        self.dynamicRange = dynamicRange
        self.color = color
    }

    /// Codecs the MP4 container accepts as-is, which makes a passthrough remux possible.
    static let mp4CompatibleCodecs: Set<String> = ["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe"]

    public var canBeRemuxedToMP4: Bool { Self.mp4CompatibleCodecs.contains(codec) }
}

public struct AudioTrackInfo: Hashable, Sendable, Codable {
    /// Four-character format code, e.g. `aac `, `lpcm`.
    public var format: String
    public var bitrate: Int
    public var sampleRate: Double
    public var channelCount: Int

    public init(format: String, bitrate: Int, sampleRate: Double, channelCount: Int) {
        self.format = format
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    static let mp4CompatibleFormats: Set<String> = ["aac ", "aach", "aacp", "ac-3", "ec-3"]

    public var canBeRemuxedToMP4: Bool { Self.mp4CompatibleFormats.contains(format) }
}

/// Everything the planner needs to know about a source file.
public struct MediaInfo: Hashable, Sendable, Codable {
    public var url: URL
    public var fileSize: Int64
    /// Seconds.
    public var duration: Double
    public var video: VideoTrackInfo
    public var audio: AudioTrackInfo?
    public var creationDate: Date?

    public init(
        url: URL,
        fileSize: Int64,
        duration: Double,
        video: VideoTrackInfo,
        audio: AudioTrackInfo? = nil,
        creationDate: Date? = nil
    ) {
        self.url = url
        self.fileSize = fileSize
        self.duration = duration
        self.video = video
        self.audio = audio
        self.creationDate = creationDate
    }
}
