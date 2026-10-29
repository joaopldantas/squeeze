import Foundation
import Testing
@testable import SqueezeCore

@Suite("Mapeamento dos presets")
struct EncodingPlannerTests {
    let planner = EncodingPlanner()

    private func video(
        _ preset: Preset,
        _ source: MediaInfo = .sample(),
        motion: MotionLevel = .normal,
        overrides: EncodingOverrides = .none
    ) throws -> VideoEncodingSettings {
        let plan = try planner.plan(for: preset, source: source, motion: motion, overrides: overrides)
        return try #require(plan.videoSettings)
    }

    // MARK: Presets

    @Test("equilibrado: HEVC, resolução original, AAC 128k")
    func balanced() throws {
        let plan = try planner.plan(for: .balanced, source: .sample())
        let settings = try #require(plan.videoSettings)
        #expect(settings.codec == .hevc)
        #expect(settings.size == PixelSize(width: 1920, height: 1080))
        #expect(settings.frameRateLimit == nil)
        #expect(settings.bitrate == 4_000_000)
        #expect(plan.audioSettings?.bitrate == 128_000)
        #expect(plan.warnings.isEmpty)
    }

    @Test("ordem de bitrate: alta qualidade > equilibrado > tamanho mínimo")
    func presetOrdering() throws {
        let source = MediaInfo.sample(width: 3840, height: 2160, videoBitrate: 100_000_000)
        let high = try video(.highQuality, source).bitrate
        let balanced = try video(.balanced, source).bitrate
        let smallest = try video(.smallest, source).bitrate
        #expect(high > balanced)
        #expect(balanced > smallest)
    }

    @Test("tamanho mínimo limita a 1080p e 30 fps")
    func smallestLimitsResolutionAndFrameRate() throws {
        let settings = try video(.smallest, .sample(width: 3840, height: 2160, frameRate: 60))
        #expect(settings.size == PixelSize(width: 1920, height: 1080))
        #expect(settings.frameRateLimit == 30)
    }

    @Test("web: H.264 na resolução escolhida, inclusive em retrato", arguments: [
        (WebResolution.p720, PixelSize(width: 1920, height: 1080), PixelSize(width: 1280, height: 720)),
        (WebResolution.p720, PixelSize(width: 1080, height: 1920), PixelSize(width: 720, height: 1280)),
        (WebResolution.p1080, PixelSize(width: 3840, height: 2160), PixelSize(width: 1920, height: 1080))
    ])
    func web(resolution: WebResolution, source: PixelSize, expected: PixelSize) throws {
        let settings = try video(.web(resolution), .sample(width: source.width, height: source.height, frameRate: 60))
        #expect(settings.codec == .h264)
        #expect(settings.size == expected)
        #expect(settings.frameRateLimit == 30)
    }

    @Test("manter original: passthrough de vídeo e áudio")
    func original() throws {
        let plan = try planner.plan(for: .original, source: .sample(codec: "hvc1"))
        #expect(plan.video == .passthrough)
        #expect(plan.audio == .passthrough)
        #expect(plan.warnings.isEmpty)
    }

    @Test("manter original com ProRes não é possível em MP4")
    func originalRejectsProRes() {
        #expect(throws: SqueezeError.passthroughUnsupported(codec: "apcn")) {
            try planner.plan(for: .original, source: .sample(codec: "apcn"))
        }
    }

    @Test("manter original com áudio PCM converte só o áudio")
    func originalReencodesIncompatibleAudio() throws {
        let plan = try planner.plan(for: .original, source: .sample(audio: .stereoPCM))
        #expect(plan.video == .passthrough)
        #expect(plan.audioSettings?.bitrate == 192_000)
        #expect(plan.warnings == [.audioReencodedForMP4])
    }

    @Test("manter original respeita a remoção do áudio")
    func originalCanDropAudio() throws {
        let plan = try planner.plan(for: .original, source: .sample(), overrides: .init(audio: .remove))
        #expect(plan.audio == EncodingPlan.Audio.none)
    }

    @Test("preset mais agressivo sugerido quando o arquivo cresce")
    func moreAggressive() {
        #expect(Preset.original.moreAggressive == .balanced)
        #expect(Preset.highQuality.moreAggressive == .balanced)
        #expect(Preset.balanced.moreAggressive == .smallest)
        #expect(Preset.web(.p1080).moreAggressive == .web(.p720))
        #expect(Preset.smallest.moreAggressive == nil)
    }

    // MARK: Adaptação ao conteúdo

    @Test("gravação de tela (pouco movimento) recebe bitrate menor")
    func lowMotionLowersBitrate() throws {
        let source = MediaInfo.sample(width: 2880, height: 1800, frameRate: 60)
        let normal = try video(.balanced, source, motion: .normal).bitrate
        let screen = try video(.balanced, source, motion: .low).bitrate
        #expect(Double(screen) == (Double(normal) * 0.55).rounded(.down))
    }

    @Test("só o tamanho alvo trata o bitrate como teto")
    func bitrateCeiling() throws {
        #expect(try video(.targetSize(megabytes: 20)).isBitrateCeiling)
        #expect(try !video(.balanced).isBitrateCeiling)
        #expect(try !video(.targetSize(megabytes: 20), overrides: .init(videoBitrate: 3_000_000)).isBitrateCeiling)
    }

    @Test("tamanho alvo ignora o movimento: o tamanho prometido manda")
    func targetSizeIgnoresMotion() throws {
        let normal = try video(.targetSize(megabytes: 20), motion: .normal).bitrate
        let low = try video(.targetSize(megabytes: 20), motion: .low).bitrate
        #expect(normal == low)
    }

    @Test("nunca passa de 80% do bitrate de origem, para não crescer o arquivo")
    func cappedBySourceBitrate() throws {
        let settings = try video(.highQuality, .sample(videoBitrate: 2_000_000))
        #expect(settings.bitrate == 1_600_000)
    }

    @Test("teto do bitrate de origem acompanha a redução de resolução")
    func capScalesWithResolution() throws {
        let settings = try video(.web(.p720), .sample(videoBitrate: 3_000_000))
        // 3 Mbps × 0.8 × (1280×720)/(1920×1080)
        #expect(settings.bitrate == 1_066_666)
    }

    @Test("tamanho alvo pequeno reduz a resolução em vez de borrar")
    func targetSizeDownscales() throws {
        let source = MediaInfo.sample(width: 3840, height: 2160, duration: 120)
        let tiny = try video(.targetSize(megabytes: 15), source)
        let generous = try video(.targetSize(megabytes: 500), source)
        #expect(tiny.size.longEdge < 3840)
        #expect(generous.size == source.video.naturalSize)
    }

    @Test("30 fps ou 29,97 com limite 30 não descarta quadros", arguments: [30, 29.97, 24])
    func frameRateLimitOnlyWhenNeeded(fps: Double) throws {
        let settings = try video(.smallest, .sample(frameRate: fps))
        #expect(settings.frameRateLimit == nil)
    }

    @Test("vídeo sem áudio não ganha faixa de áudio")
    func noAudioSource() throws {
        let plan = try planner.plan(for: .balanced, source: .sample(audio: nil))
        #expect(plan.audio == EncodingPlan.Audio.none)
    }

    // MARK: Opções avançadas

    @Test("opções avançadas sobrepõem o preset")
    func overrides() throws {
        let overrides = EncodingOverrides(
            codec: .h264, maxLongEdge: 1280, frameRate: .limit(30), videoBitrate: 2_500_000, audio: .remove
        )
        let plan = try planner.plan(for: .balanced, source: .sample(frameRate: 60), overrides: overrides)
        let settings = try #require(plan.videoSettings)
        #expect(settings.codec == .h264)
        #expect(settings.size == PixelSize(width: 1280, height: 720))
        #expect(settings.frameRateLimit == 30)
        #expect(settings.bitrate == 2_500_000)
        #expect(plan.audio == EncodingPlan.Audio.none)
    }

    @Test("bitrate de áudio é limitado à faixa válida do AAC e ao original")
    func audioBitrateClamping() throws {
        let mono = AudioTrackInfo(format: "aac ", bitrate: 64_000, sampleRate: 44_100, channelCount: 1)
        let plan = try planner.plan(for: .highQuality, source: .sample(audio: mono))
        #expect(plan.audioSettings == AACSettings(bitrate: 64_000, sampleRate: 44_100, channelCount: 1))

        let surround = AudioTrackInfo(format: "lpcm", bitrate: 4_608_000, sampleRate: 96_000, channelCount: 6)
        let downmixed = try planner.plan(
            for: .balanced, source: .sample(audio: surround), overrides: .init(audio: .aac(bitrate: 999_000))
        )
        #expect(downmixed.audioSettings == AACSettings(bitrate: 320_000, sampleRate: 48_000, channelCount: 2))
    }

    // MARK: HDR

    @Test("HEVC preserva HLG e HDR10", arguments: [DynamicRange.hlg, .hdr10])
    func hevcKeepsHDR(range: DynamicRange) throws {
        let plan = try planner.plan(for: .balanced, source: .sample(dynamicRange: range))
        #expect(plan.videoSettings?.dynamicRange == range)
        #expect(plan.warnings.isEmpty)
    }

    @Test("H.264 converte HDR para SDR e avisa")
    func h264ToneMaps() throws {
        let plan = try planner.plan(for: .web(.p1080), source: .sample(dynamicRange: .hlg))
        #expect(plan.videoSettings?.dynamicRange == .sdr)
        #expect(plan.warnings == [.hdrConvertedToSDR])
    }

    @Test("Dolby Vision mantém a camada base e avisa", arguments: [
        ("ITU_R_2100_HLG", DynamicRange.hlg),
        ("SMPTE_ST_2084_PQ", DynamicRange.hdr10)
    ])
    func dolbyVision(transfer: String, base: DynamicRange) throws {
        let source = MediaInfo.sample(dynamicRange: .dolbyVision, transferFunction: transfer)
        let plan = try planner.plan(for: .balanced, source: source)
        #expect(plan.videoSettings?.dynamicRange == base)
        #expect(plan.warnings == [.dolbyVisionMetadataDropped(keptAs: base)])
    }

    @Test("passthrough mantém Dolby Vision sem aviso")
    func passthroughKeepsDolbyVision() throws {
        let source = MediaInfo.sample(codec: "dvh1", dynamicRange: .dolbyVision)
        let plan = try planner.plan(for: .original, source: source)
        #expect(plan.isPassthrough)
        #expect(plan.warnings.isEmpty)
    }
}
