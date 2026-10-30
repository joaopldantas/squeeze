import Testing
@testable import SqueezeCore

@Suite("Aviso de arquivo maior que o original")
struct ConversionResultTests {
    let reencode = EncodingPlan(video: .encode(VideoEncodingSettings(
        codec: .hevc, size: PixelSize(width: 2, height: 2), frameRateLimit: nil, bitrate: 1, dynamicRange: .sdr
    )), audio: .none, warnings: [])
    let remux = EncodingPlan(video: .passthrough, audio: .passthrough, warnings: [])

    @Test("reencode que cresce sempre avisa")
    func reencodeGrowth() {
        let grew = SizeComparison(originalBytes: 1_000, outputBytes: 1_001)
        #expect(VideoCompressor.outputGrewUnexpectedly(grew, plan: reencode))
    }

    @Test("passthrough só avisa se crescer mais que o overhead do container")
    func passthroughGrowth() {
        let overhead = SizeComparison(originalBytes: 71_893_956, outputBytes: 72_216_263)
        let real = SizeComparison(originalBytes: 1_000, outputBytes: 1_020)
        #expect(!VideoCompressor.outputGrewUnexpectedly(overhead, plan: remux))
        #expect(VideoCompressor.outputGrewUnexpectedly(real, plan: remux))
    }

    @Test("arquivo menor nunca avisa")
    func smaller() {
        let smaller = SizeComparison(originalBytes: 1_000, outputBytes: 500)
        #expect(!VideoCompressor.outputGrewUnexpectedly(smaller, plan: reencode))
    }
}
