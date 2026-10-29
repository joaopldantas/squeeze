import Testing
@testable import SqueezeCore

@Suite("Estimativa de tamanho")
struct SizeEstimatorTests {
    @Test("soma vídeo e áudio pela duração, com overhead do container")
    func reencode() throws {
        let source = MediaInfo.sample(duration: 10)
        let plan = try EncodingPlanner().plan(for: .balanced, source: source)
        // (4 Mbps + 128 kbps) × 10 s / 8 × 1.02
        #expect(SizeEstimator.estimatedBytes(for: plan, source: source) == 5_263_200)
    }

    @Test("passthrough estima pelo bitrate das faixas de origem")
    func passthrough() throws {
        let source = MediaInfo.sample(videoBitrate: 10_000_000, duration: 8)
        let plan = try EncodingPlanner().plan(for: .original, source: source)
        let estimate = SizeEstimator.estimatedBytes(for: plan, source: source)
        #expect(estimate == Int64((10_256_000.0 * 8 / 8 * 1.02).rounded()))
        #expect(abs(Double(estimate) / Double(source.fileSize) - 1) < 0.03)
    }

    @Test("sem áudio, só o vídeo conta")
    func withoutAudio() throws {
        let source = MediaInfo.sample(duration: 10, audio: nil)
        let plan = try EncodingPlanner().plan(for: .balanced, source: source)
        #expect(SizeEstimator.estimatedBytes(for: plan, source: source) == 5_100_000)
    }

    @Test("% de redução")
    func comparison() {
        let smaller = SizeComparison(originalBytes: 400, outputBytes: 100)
        #expect(smaller.savedBytes == 300)
        #expect(smaller.savedFraction == 0.75)
        #expect(!smaller.outputIsLarger)

        let larger = SizeComparison(originalBytes: 100, outputBytes: 120)
        #expect(larger.savedFraction < 0)
        #expect(larger.outputIsLarger)

        #expect(SizeComparison(originalBytes: 0, outputBytes: 10).savedFraction == 0)
    }
}
