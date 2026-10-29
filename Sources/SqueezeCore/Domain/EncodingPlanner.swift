import Foundation

/// Turns a preset + source description into concrete encoder settings. Pure and deterministic.
public struct EncodingPlanner: Sendable {
    /// Re-encoding above this share of the source bitrate tends to produce a file that isn't smaller.
    static let sourceBitrateCeiling = 0.8
    /// For target-size mode: the output must get at least this share of the bitrate its resolution
    /// would normally need, otherwise we step down a resolution — fewer, sharper pixels beat many blocky ones.
    static let targetSizeQualityFloor = 0.5
    static let targetSizeLongEdges = [3840, 2560, 1920, 1280, 960, 640]
    static let passthroughAudioFallbackBitrate = 192_000

    public init() {}

    public func plan(
        for preset: Preset,
        source: MediaInfo,
        motion: MotionLevel = .normal,
        overrides: EncodingOverrides = .none
    ) throws -> EncodingPlan {
        guard let profile = PresetProfile.profile(for: preset) else {
            return try passthroughPlan(source: source, overrides: overrides)
        }

        let codec = overrides.codec ?? profile.codec
        let audio = Self.audioPlan(overrides.audio ?? profile.audio, source: source.audio)
        let frameRateLimit = Self.frameRateLimit(overrides.frameRate ?? profile.frameRate, source: source.video)
        let outputFrameRate = frameRateLimit.map(Double.init) ?? source.video.frameRate
        let maxLongEdge = overrides.maxLongEdge ?? profile.maxLongEdge
        var size = ResolutionScaler.fit(source.video.naturalSize, maxLongEdge: maxLongEdge)

        let bitrate: Int
        if let manual = overrides.videoBitrate {
            bitrate = max(BitrateCalculator.minimumVideoBitrate, manual)
        } else if case .targetSize(let megabytes) = preset {
            bitrate = try BitrateCalculator.videoBitrate(
                targetBytes: ByteUnits.bytes(megabytes: megabytes),
                duration: source.duration,
                audioBitrate: audio.bitrate(source: source.audio)
            )
            if overrides.maxLongEdge == nil {
                size = Self.sizeForTargetBitrate(
                    bitrate, source: source.video, frameRate: outputFrameRate, codec: codec, profile: profile
                )
            }
        } else {
            let adaptive = BitrateCalculator.adaptiveBitrate(
                referenceBitrate: profile.referenceBitrate,
                size: size,
                frameRate: outputFrameRate,
                codec: codec,
                motion: profile.adaptsToMotion ? motion : .normal
            )
            bitrate = Self.capped(adaptive, source: source.video, size: size, frameRate: outputFrameRate)
        }

        let (dynamicRange, warnings) = Self.dynamicRange(for: codec, source: source.video)
        let isTargetSize = if case .targetSize = preset { overrides.videoBitrate == nil } else { false }
        let video = VideoEncodingSettings(
            codec: codec, size: size, frameRateLimit: frameRateLimit, bitrate: bitrate,
            dynamicRange: dynamicRange, isBitrateCeiling: isTargetSize
        )
        return EncodingPlan(video: .encode(video), audio: audio, warnings: warnings)
    }

    private func passthroughPlan(source: MediaInfo, overrides: EncodingOverrides) throws -> EncodingPlan {
        guard source.video.canBeRemuxedToMP4 else {
            throw SqueezeError.passthroughUnsupported(codec: source.video.codec)
        }
        guard let audio = source.audio, overrides.audio != .remove else {
            return EncodingPlan(video: .passthrough, audio: .none, warnings: [])
        }
        if audio.canBeRemuxedToMP4 {
            return EncodingPlan(video: .passthrough, audio: .passthrough, warnings: [])
        }
        let settings = Self.aacSettings(bitrate: Self.passthroughAudioFallbackBitrate, source: audio)
        return EncodingPlan(video: .passthrough, audio: .encode(settings), warnings: [.audioReencodedForMP4])
    }

    // MARK: - Rules

    static func frameRateLimit(_ policy: FrameRatePolicy, source: VideoTrackInfo) -> Int? {
        guard let limit = policy.limit else { return nil }
        // Half a frame of slack so 30.0 vs 29.97 doesn't trigger pointless frame dropping.
        return source.frameRate > Double(limit) + 0.5 ? limit : nil
    }

    static func capped(_ bitrate: Int, source: VideoTrackInfo, size: PixelSize, frameRate: Double) -> Int {
        guard source.bitrate > 0, source.naturalSize.pixelCount > 0 else { return bitrate }
        let pixelRatio = Double(size.pixelCount) / Double(source.naturalSize.pixelCount)
        let frameRateRatio = source.frameRate > 0 ? min(1, frameRate / source.frameRate) : 1
        let ceiling = Double(source.bitrate) * sourceBitrateCeiling * min(1, pixelRatio) * frameRateRatio
        return max(BitrateCalculator.minimumVideoBitrate, min(bitrate, Int(ceiling)))
    }

    static func sizeForTargetBitrate(
        _ bitrate: Int,
        source: VideoTrackInfo,
        frameRate: Double,
        codec: VideoCodec,
        profile: PresetProfile
    ) -> PixelSize {
        let longEdges = [source.naturalSize.longEdge] + targetSizeLongEdges.filter { $0 < source.naturalSize.longEdge }
        let candidates = longEdges.map { ResolutionScaler.fit(source.naturalSize, maxLongEdge: $0) }
        let fitting = candidates.first { candidate in
            let needed = BitrateCalculator.adaptiveBitrate(
                referenceBitrate: profile.referenceBitrate, size: candidate,
                frameRate: frameRate, codec: codec, motion: .normal
            )
            return Double(bitrate) >= Double(needed) * targetSizeQualityFloor
        }
        return fitting ?? candidates.last ?? source.naturalSize
    }

    static func dynamicRange(for codec: VideoCodec, source: VideoTrackInfo) -> (DynamicRange, [ConversionWarning]) {
        switch (source.dynamicRange, codec) {
        case (.sdr, _):
            return (.sdr, [])
        case (_, .h264):
            return (.sdr, [.hdrConvertedToSDR])
        case (.dolbyVision, .hevc):
            let base = source.hdrBaseLayer
            return (base, [.dolbyVisionMetadataDropped(keptAs: base)])
        case (let range, .hevc):
            return (range, [])
        }
    }

    static func audioPlan(_ policy: AudioPolicy, source: AudioTrackInfo?) -> EncodingPlan.Audio {
        guard let source, case .aac(let bitrate) = policy else { return .none }
        return .encode(aacSettings(bitrate: bitrate, source: source))
    }

    static func aacSettings(bitrate: Int, source: AudioTrackInfo) -> AACSettings {
        let channelCount = min(max(source.channelCount, 1), 2)
        let sampleRate = [44_100.0, 48_000.0].contains(source.sampleRate) ? source.sampleRate : 48_000
        var bitrate = bitrate
        // Re-encoding lossy audio at a higher bitrate only wastes bytes.
        if source.canBeRemuxedToMP4, source.bitrate > 0 {
            bitrate = min(bitrate, source.bitrate)
        }
        let validRange = channelCount == 1 ? 32_000...160_000 : 64_000...320_000
        return AACSettings(
            bitrate: min(max(bitrate, validRange.lowerBound), validRange.upperBound),
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }
}

extension VideoTrackInfo {
    /// Dolby Vision profile 8 carries an HDR10 or HLG base layer; we can keep that when re-encoding.
    var hdrBaseLayer: DynamicRange {
        transferFunction == .pq ? .hdr10 : .hlg
    }

    var transferFunction: TransferFunction? {
        switch color.transferFunction {
        case TransferFunction.pq.rawValue: .pq
        case TransferFunction.hlg.rawValue: .hlg
        default: nil
        }
    }
}

/// HDR transfer functions, as CoreMedia names them.
enum TransferFunction: String {
    case pq = "SMPTE_ST_2084_PQ"
    case hlg = "ITU_R_2100_HLG"
}

extension EncodingPlan.Audio {
    /// Expected bitrate, given the source track (needed for passthrough).
    func bitrate(source: AudioTrackInfo?) -> Int {
        switch self {
        case .none: 0
        case .passthrough: source?.bitrate ?? 0
        case .encode(let settings): settings.bitrate
        }
    }
}
