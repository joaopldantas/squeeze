import Foundation
import SqueezeCore

/// What the settings panel edits. Kept flat and `Codable` so it maps 1:1 to controls and persists as JSON.
public struct CompressionSettings: Hashable, Sendable, Codable {
    public enum PresetKind: String, CaseIterable, Identifiable, Sendable, Codable {
        case highQuality
        case balanced
        case smallest
        case web720
        case web1080
        case targetSize
        case original

        public var id: Self { self }
    }

    public var presetKind: PresetKind = .balanced
    /// Only used when `presetKind == .targetSize`.
    public var targetMegabytes: Double = 25
    public var codec: VideoCodec?
    public var maxLongEdge: Int?
    public var frameRate: FrameRatePolicy?
    public var videoBitrateKbps: Int?
    public var audio: AudioPolicy?
    /// `nil` writes next to each original.
    public var outputFolder: URL?
    /// How many files convert at once. Two keeps the media engine busy while the other job reads or writes;
    /// more than that only competes for the same hardware encoder.
    public var maxConcurrentJobs = 1 {
        didSet { maxConcurrentJobs = Self.clampedJobs(maxConcurrentJobs) }
    }

    public static let concurrencyRange = 1...2

    static func clampedJobs(_ jobs: Int) -> Int {
        min(max(jobs, concurrencyRange.lowerBound), concurrencyRange.upperBound)
    }

    public init() {}

    public var preset: Preset {
        switch presetKind {
        case .highQuality: .highQuality
        case .balanced: .balanced
        case .smallest: .smallest
        case .web720: .web(.p720)
        case .web1080: .web(.p1080)
        case .targetSize: .targetSize(megabytes: targetMegabytes)
        case .original: .original
        }
    }

    public var overrides: EncodingOverrides {
        EncodingOverrides(
            codec: codec,
            maxLongEdge: maxLongEdge,
            frameRate: frameRate,
            videoBitrate: videoBitrateKbps.map { $0 * 1_000 },
            audio: audio
        )
    }

    public var outputLocation: OutputLocation {
        outputFolder.map(OutputLocation.folder) ?? .besideOriginal
    }

    /// Passthrough copies the streams, so only "remove audio" still applies.
    public var allowsVideoOptions: Bool { presetKind != .original }

    public var hasAdvancedOverrides: Bool { overrides != .none }

    public func request(for source: URL, preset override: Preset? = nil) -> ConversionRequest {
        ConversionRequest(source: source, preset: override ?? preset, overrides: overrides, output: outputLocation)
    }
}

extension CompressionSettings {
    private enum CodingKeys: String, CodingKey {
        case presetKind, targetMegabytes, codec, maxLongEdge, frameRate, videoBitrateKbps, audio, outputFolder
        case maxConcurrentJobs
    }

    /// Every key is optional, so settings saved by an older version (missing newer keys) still load
    /// instead of silently resetting everything to defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CompressionSettings()
        presetKind = try container.decodeIfPresent(PresetKind.self, forKey: .presetKind) ?? defaults.presetKind
        targetMegabytes = try container.decodeIfPresent(Double.self, forKey: .targetMegabytes)
            ?? defaults.targetMegabytes
        codec = try container.decodeIfPresent(VideoCodec.self, forKey: .codec)
        maxLongEdge = try container.decodeIfPresent(Int.self, forKey: .maxLongEdge)
        frameRate = try container.decodeIfPresent(FrameRatePolicy.self, forKey: .frameRate)
        videoBitrateKbps = try container.decodeIfPresent(Int.self, forKey: .videoBitrateKbps)
        audio = try container.decodeIfPresent(AudioPolicy.self, forKey: .audio)
        outputFolder = try container.decodeIfPresent(URL.self, forKey: .outputFolder)
        let jobs = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentJobs)
        // `didSet` doesn't run during init, so clamp here too.
        maxConcurrentJobs = Self.clampedJobs(jobs ?? defaults.maxConcurrentJobs)
    }
}

extension CompressionSettings.PresetKind {
    public var title: String {
        switch self {
        case .highQuality: "Alta qualidade"
        case .balanced: "Equilibrado"
        case .smallest: "Tamanho mínimo"
        case .web720: "Web/WhatsApp 720p"
        case .web1080: "Web/WhatsApp 1080p"
        case .targetSize: "Tamanho alvo"
        case .original: "Manter qualidade original"
        }
    }

    public var summary: String {
        switch self {
        case .highQuality: "HEVC com bitrate generoso. Para guardar."
        case .balanced: "HEVC adaptado ao conteúdo. Bom para quase tudo."
        case .smallest: "HEVC até 1080p e 30 fps. O menor arquivo possível."
        case .web720, .web1080: "H.264, toca em qualquer lugar."
        case .targetSize: "Calcula o bitrate para caber no tamanho escolhido."
        case .original: "Só troca .mov por .mp4, sem reencodar e sem perda."
        }
    }
}
