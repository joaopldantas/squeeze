import Foundation

/// Width × height in pixels, as stored in the encoded stream (before any rotation).
public struct PixelSize: Hashable, Sendable, Codable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixelCount: Int { width * height }
    public var longEdge: Int { max(width, height) }
    public var isPortrait: Bool { height > width }
    public var description: String { "\(width)×\(height)" }
}

public enum VideoCodec: String, Hashable, Sendable, Codable, CaseIterable {
    /// H.265 – the default: roughly 30–40% smaller than H.264 at the same perceived quality.
    case hevc
    /// H.264 – plays everywhere (WhatsApp, old browsers, Windows without extensions).
    case h264

    /// Bitrate multiplier needed to match HEVC quality. All reference bitrates are expressed in HEVC terms.
    var bitrateFactor: Double {
        switch self {
        case .hevc: 1.0
        case .h264: 1.4
        }
    }
}

public enum FrameRatePolicy: Hashable, Sendable, Codable {
    case keep
    /// Drops frames so the output never exceeds this rate. Sources at or below it are untouched.
    case limit(Int)

    var limit: Int? {
        if case .limit(let fps) = self { return fps }
        return nil
    }
}

public enum AudioPolicy: Hashable, Sendable, Codable {
    case aac(bitrate: Int)
    case remove
}

/// Transfer characteristics of the source video, which determine whether it is HDR.
public enum DynamicRange: String, Hashable, Sendable, Codable {
    case sdr
    case hdr10
    case hlg
    case dolbyVision

    public var isHDR: Bool { self != .sdr }
}

/// Where the compressed file goes.
public enum OutputLocation: Hashable, Sendable, Codable {
    case besideOriginal
    case folder(URL)

    public func directory(for source: URL) -> URL {
        switch self {
        case .besideOriginal: source.deletingLastPathComponent()
        case .folder(let url): url
        }
    }
}

/// Decimal units, matching what Finder shows.
public enum ByteUnits {
    public static let megabyte: Int64 = 1_000_000

    public static func bytes(megabytes: Double) -> Int64 {
        Int64((megabytes * Double(megabyte)).rounded())
    }
}
