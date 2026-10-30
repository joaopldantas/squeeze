@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import SqueezeCore

/// The engine as the UI sees it. `VideoCompressor` is the real one; tests inject fakes.
public protocol VideoCompressing: Sendable {
    func preview(_ request: ConversionRequest) async throws -> ConversionPreview
    func replan(_ preview: ConversionPreview, for request: ConversionRequest) throws -> ConversionPreview
    func compress(
        _ request: ConversionRequest,
        preview: ConversionPreview?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult
}

extension VideoCompressor: VideoCompressing {}

/// An immutable decoded image that can cross from the generator's thread to the main actor.
public struct Thumbnail: @unchecked Sendable {
    public let image: CGImage

    public init(_ image: CGImage) {
        self.image = image
    }
}

public protocol ThumbnailProviding: Sendable {
    func thumbnail(for url: URL, maxPixelSize: Int) async -> Thumbnail?
}

/// A frame from 10% into the video, upright (rotation applied), or `nil` if the file can't be decoded.
public struct VideoThumbnailProvider: ThumbnailProviding {
    public init() {}

    public func thumbnail(for url: URL, maxPixelSize: Int) async -> Thumbnail? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: duration.isFinite ? duration * 0.1 : 0, preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: time) else { return nil }
        return Thumbnail(image)
    }
}

/// Remembers the user's settings between launches.
public protocol SettingsStoring: Sendable {
    func load() -> CompressionSettings?
    func save(_ settings: CompressionSettings)
}

public struct UserDefaultsSettingsStore: SettingsStoring {
    private let key: String

    public init(key: String = "compressionSettings") {
        self.key = key
    }

    public func load() -> CompressionSettings? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CompressionSettings.self, from: data)
    }

    public func save(_ settings: CompressionSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
