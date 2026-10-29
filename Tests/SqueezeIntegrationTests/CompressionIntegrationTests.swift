@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SqueezeCore

/// End-to-end conversions of small movies generated on the fly.
/// Serialized so hardware encoder sessions and CI VMs aren't oversubscribed.
@Suite("Conversão de ponta a ponta", .tags(.integration), .serialized, .timeLimit(.minutes(1)))
struct CompressionIntegrationTests {
    let directory: TemporaryDirectory
    let compressor = VideoCompressor()

    init() throws {
        directory = try TemporaryDirectory()
    }

    struct Conversion {
        let source: URL
        let result: ConversionResult
        let probe: OutputProbe
    }

    private func compress(
        _ spec: FixtureSpec,
        preset: Preset = .balanced,
        overrides: EncodingOverrides = .none
    ) async throws -> Conversion {
        let source = try await FixtureFactory.make(spec, in: directory.url)
        let request = ConversionRequest(source: source, preset: preset, overrides: overrides)
        let result = try await compressor.compress(request)
        return Conversion(source: source, result: result, probe: try await OutputProbe.probe(result.outputURL))
    }

    // MARK: Cenários pedidos

    @Test("paisagem: MP4, HEVC, menor que a entrada, com áudio AAC")
    func landscape() async throws {
        let conversion = try await compress(.landscape)
        let source = conversion.source
        let result = conversion.result
        let probe = conversion.probe

        #expect(result.outputURL.lastPathComponent == "landscape_compressed.mp4")
        #expect(result.outputURL.deletingLastPathComponent() == source.deletingLastPathComponent())
        #expect(probe.isMP4, "brand: \(probe.majorBrand)")
        #expect(probe.info.video.codec == "hvc1")
        #expect(probe.info.video.displaySize == PixelSize(width: 640, height: 360))
        #expect(probe.info.audio?.format == "aac ")
        #expect(abs(probe.info.duration - 2) < 0.1)
        #expect(result.comparison.outputBytes < result.comparison.originalBytes)
        #expect(result.comparison.outputBytes == probe.info.fileSize)
        #expect(result.suggestedPreset == nil)
    }

    @Test("retrato: mantém a rotação como metadado, sem girar pixels")
    func portrait() async throws {
        let conversion = try await compress(.portrait)
        let source = conversion.source
        let result = conversion.result
        let probe = conversion.probe
        let sourceTrack = try #require(try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first)

        #expect(probe.transform == (try await sourceTrack.load(.preferredTransform)))
        #expect(probe.info.video.naturalSize == PixelSize(width: 640, height: 360))
        #expect(probe.info.video.displaySize == PixelSize(width: 360, height: 640))
        #expect(probe.info.video.codec == "hvc1")
        #expect(result.comparison.outputBytes < result.comparison.originalBytes)
    }

    @Test("sem áudio: saída também sem faixa de áudio")
    func withoutAudio() async throws {
        var spec = FixtureSpec.landscape
        spec.includesAudio = false
        let conversion = try await compress(spec)
        let result = conversion.result
        let probe = conversion.probe

        #expect(probe.info.audio == nil)
        #expect(probe.isMP4)
        #expect(result.comparison.outputBytes < result.comparison.originalBytes)
    }

    @Test("vídeo de 1 segundo")
    func oneSecond() async throws {
        var spec = FixtureSpec.landscape
        spec.duration = 1
        let conversion = try await compress(spec)
        let result = conversion.result
        let probe = conversion.probe

        #expect(abs(probe.info.duration - 1) < 0.1)
        #expect(probe.info.video.codec == "hvc1")
        #expect(result.comparison.outputBytes < result.comparison.originalBytes)
    }

    @Test("passthrough: só troca o container, sem reencodar")
    func passthrough() async throws {
        let conversion = try await compress(.landscape, preset: .original)
        let result = conversion.result
        let probe = conversion.probe

        #expect(result.plan.isPassthrough)
        #expect(probe.isMP4)
        #expect(probe.info.video.codec == "avc1", "o codec de origem é preservado")
        #expect(probe.info.audio?.format == "aac ")
        // Same samples in a new container: the size barely changes.
        #expect(abs(result.comparison.savedFraction) < 0.05)
    }

    // MARK: Presets e opções

    @Test("web 720p: H.264 e 60 → 30 fps")
    func webPreset() async throws {
        var spec = FixtureSpec.landscape
        spec.width = 1280
        spec.height = 720
        spec.frameRate = 60
        spec.duration = 1
        let conversion = try await compress(spec, preset: .web(.p720))
        let probe = conversion.probe

        #expect(probe.info.video.codec == "avc1")
        #expect(probe.info.video.displaySize == PixelSize(width: 1280, height: 720))
        #expect(abs(probe.info.video.frameRate - 30) < 1)
    }

    @Test("redimensiona mantendo proporção")
    func downscale() async throws {
        let conversion = try await compress(.portrait, overrides: .init(maxLongEdge: 320))
        let probe = conversion.probe
        #expect(probe.info.video.naturalSize == PixelSize(width: 320, height: 180))
        #expect(probe.info.video.displaySize == PixelSize(width: 180, height: 320))
    }

    @Test("remove o áudio quando pedido")
    func removeAudio() async throws {
        let conversion = try await compress(.landscape, overrides: .init(audio: .remove))
        let probe = conversion.probe
        #expect(probe.info.audio == nil)
    }

    @Test("preserva data de criação e localização")
    func metadata() async throws {
        var spec = FixtureSpec.landscape
        spec.creationDate = Date(timeIntervalSince1970: 1_700_000_000)
        spec.locationISO6709 = "+48.8584+002.2945+035.000/"
        let conversion = try await compress(spec)
        let probe = conversion.probe

        // The MP4 writer stores them as ISO user data (`date`, `loci`); readers see them as common keys.
        #expect(probe.creationDate == spec.creationDate)
        #expect(probe.location == spec.locationISO6709)
    }

    @Test("HDR (HLG): HEVC preserva")
    func hdrKeptWithHEVC() async throws {
        let conversion = try await compress(.hlg)
        let source = conversion.source
        let result = conversion.result
        let probe = conversion.probe
        let sourceInfo = try await MediaInspector().inspect(source)

        #expect(sourceInfo.video.dynamicRange.isHDR, "a fixture precisa ser HDR")
        #expect(probe.info.video.codec == "hvc1")
        #expect(probe.info.video.dynamicRange.isHDR)
        #expect(probe.info.video.color.transferFunction == "ITU_R_2100_HLG")
        #expect(probe.info.video.color.primaries == "ITU_R_2020")
        // VideoToolbox may regenerate Dolby Vision 8.4 for HLG; if it does, there is nothing to warn about.
        if probe.info.video.dynamicRange == .dolbyVision {
            #expect(result.warnings.isEmpty)
        }
        #expect(!result.warnings.contains(.hdrConvertedToSDR))
    }

    @Test("HDR (HLG): H.264 converte para SDR e avisa")
    func hdrToneMappedWithH264() async throws {
        let conversion = try await compress(.hlg, preset: .web(.p720))
        let result = conversion.result
        let probe = conversion.probe

        #expect(probe.info.video.codec == "avc1")
        #expect(probe.info.video.dynamicRange == .sdr)
        #expect(probe.info.video.color.transferFunction == "ITU_R_709_2")
        #expect(result.warnings == [.hdrConvertedToSDR])
    }

    @Test("gravação de tela parada é detectada como pouco movimento")
    func motionDetection() async throws {
        var still = FixtureSpec.landscape
        still.name = "tela"
        still.content = .still
        still.duration = 3
        var busy = FixtureSpec.landscape
        busy.duration = 3

        let stillPreview = try await compressor.preview(
            ConversionRequest(source: try await FixtureFactory.make(still, in: directory.url))
        )
        let busyPreview = try await compressor.preview(
            ConversionRequest(source: try await FixtureFactory.make(busy, in: directory.url))
        )
        #expect(stillPreview.motion == .low)
        #expect(busyPreview.motion == .high)
        let stillBitrate = try #require(stillPreview.plan.videoSettings).bitrate
        let busyBitrate = try #require(busyPreview.plan.videoSettings).bitrate
        #expect(stillBitrate < busyBitrate)
    }

    @Test("prévia estima o tamanho final com folga razoável")
    func previewEstimate() async throws {
        var spec = FixtureSpec.landscape
        spec.content = .panning
        let source = try await FixtureFactory.make(spec, in: directory.url)
        let request = ConversionRequest(source: source, preset: .targetSize(megabytes: 0.3))
        let preview = try await compressor.preview(request)
        let result = try await compressor.compress(request, preview: preview)

        #expect(preview.estimate.outputBytes <= 300_000)
        #expect(result.comparison.outputBytes <= 330_000, "até 10% acima do alvo: \(result.comparison.outputBytes)")
    }

    @Test("avisa e sugere preset mais agressivo quando a saída cresce")
    func outputLargerThanSource() async throws {
        var spec = FixtureSpec.landscape
        spec.bitrate = 1_000_000
        let conversion = try await compress(spec, overrides: .init(videoBitrate: 20_000_000))
        let result = conversion.result

        #expect(result.comparison.outputIsLarger)
        #expect(result.suggestedPreset == .smallest)
    }

    // MARK: Arquivos de saída

    @Test("nunca sobrescreve: segunda conversão ganha sufixo _2")
    func neverOverwrites() async throws {
        let source = try await FixtureFactory.make(.landscape, in: directory.url)
        let request = ConversionRequest(source: source)
        let first = try await compressor.compress(request)
        let firstData = try Data(contentsOf: first.outputURL)
        let second = try await compressor.compress(request)

        #expect(first.outputURL.lastPathComponent == "landscape_compressed.mp4")
        #expect(second.outputURL.lastPathComponent == "landscape_compressed_2.mp4")
        #expect(try Data(contentsOf: first.outputURL) == firstData)
        #expect(try directory.allContents() == [
            "landscape.mov", "landscape_compressed.mp4", "landscape_compressed_2.mp4"
        ])
    }

    @Test("pasta fixa de saída, criada se não existir")
    func fixedOutputFolder() async throws {
        let source = try await FixtureFactory.make(.landscape, in: directory.url)
        let folder = directory.url.appendingPathComponent("Comprimidos/2026", isDirectory: true)
        let result = try await compressor.compress(ConversionRequest(source: source, output: .folder(folder)))

        #expect(result.outputURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
    }
}
