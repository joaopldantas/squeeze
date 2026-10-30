import Foundation
import Testing
@testable import SqueezeCLI
@testable import SqueezeCore

@Suite("Formatação da saída")
struct FormattingTests {
    let format = Formatting(locale: Locale(identifier: "pt_BR"))

    @Test("bytes em unidades decimais, como o Finder", arguments: [
        (Int64(512), "512 B"), (1_500, "1,5 KB"), (73_858_356, "73,9 MB"), (2_400_000_000, "2,4 GB")
    ])
    func bytes(count: Int64, expected: String) {
        #expect(format.bytes(count) == expected)
    }

    @Test("variação de tamanho com sinal correto, mesmo abaixo de 1%", arguments: [
        (Int64(400), Int64(100), "−75%"),
        (100, 115, "+15%"),
        (71_893_956, 72_216_263, "+0,4%"),
        (1_000, 999, "−0,1%"),
        (1_000, 1_000, "0%")
    ])
    func change(original: Int64, output: Int64, expected: String) {
        #expect(format.change(SizeComparison(originalBytes: original, outputBytes: output)) == expected)
    }

    @Test("bitrate", arguments: [(4_000_000, "4,0 Mbps"), (1_305_985, "1,3 Mbps"), (128_000, "128 kbps")])
    func bitrate(value: Int, expected: String) {
        #expect(format.bitrate(value) == expected)
    }

    @Test("duração", arguments: [(42.4, "0:42"), (725.0, "12:05"), (3723.0, "1:02:03")])
    func duration(seconds: Double, expected: String) {
        #expect(format.duration(seconds) == expected)
    }

    @Test("barra de progresso")
    func progressBar() {
        #expect(format.progressBar(0.5, width: 10) == "[█████░░░░░]  50%")
        #expect(format.progressBar(1.4, width: 4) == "[████] 100%")
        #expect(format.progressBar(-1, width: 4) == "[░░░░]   0%")
    }

    @Test("plano de passthrough e de reencode")
    func plan() throws {
        let source = MediaInfo(
            url: URL(fileURLWithPath: "/tmp/a.mov"), fileSize: 1, duration: 10,
            video: VideoTrackInfo(
                codec: "hvc1", naturalSize: PixelSize(width: 1920, height: 1080), frameRate: 240, bitrate: 1
            )
        )
        let remux = EncodingPlan(video: .passthrough, audio: .none, warnings: [])
        #expect(format.plan(remux, source: source) == "vídeo copiado sem reencodar (hvc1) · sem áudio")

        let encode = EncodingPlan(
            video: .encode(VideoEncodingSettings(
                codec: .hevc, size: PixelSize(width: 1920, height: 1080), frameRateLimit: 60,
                bitrate: 4_000_000, dynamicRange: .hlg
            )),
            audio: .encode(AACSettings(bitrate: 128_000, sampleRate: 48_000, channelCount: 2)),
            warnings: []
        )
        let expected = "HEVC · 1920×1080 · 4,0 Mbps · até 60 fps · HDR · áudio AAC 128 kbps"
        #expect(format.plan(encode, source: source) == expected)
    }

    @Test("sugestão de preset usa o nome da CLI")
    func presetSpelling() {
        #expect(PresetChoice(.smallest) == .smallest)
        #expect(PresetChoice(.web(.p720)) == .web720)
        #expect(PresetChoice(.targetSize(megabytes: 5)) == nil)
    }
}
