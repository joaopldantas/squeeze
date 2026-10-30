import Testing
@testable import SqueezeCore

@Suite("Detecção de movimento")
struct MotionLevelTests {
    private static func samples(_ pairs: [(Double, Double)]) -> [FrameDifference] {
        pairs.map { FrameDifference(changed: $0.0, identical: $0.1) }
    }

    @Test(arguments: [
        ([], MotionLevel.normal),
        // Gravação de tela: quase nada muda e o resto é idêntico pixel a pixel.
        ([(0.0, 1.0), (0.01, 0.99), (0.02, 0.98)], .low),
        // Panorâmica aérea lenta (medida no wallpaper "Golden Gate"): pouco muda, mas o grão impede pixels idênticos.
        ([(0.002, 0.878), (0.0, 0.883), (0.003, 0.836)], .normal),
        ([(0.1, 0.5), (0.15, 0.4), (0.2, 0.45)], .normal),
        ([(0.4, 0.1), (0.5, 0.05), (0.9, 0.0)], .high),
        // Um corte de cena não transforma uma gravação de tela parada em vídeo agitado.
        ([(0.0, 1.0), (0.0, 1.0), (0.01, 0.99), (0.95, 0.0)], .low)
    ])
    func classify(pairs: [(Double, Double)], expected: MotionLevel) {
        #expect(MotionLevel.classify(Self.samples(pairs)) == expected)
    }

    @Test("diferença entre quadros respeita o limiar de ruído")
    func frameDifference() {
        let frame: [UInt8] = [10, 20, 30, 40]
        #expect(FrameDifference(frame, frame) == FrameDifference(changed: 0, identical: 1))
        #expect(FrameDifference(frame, [11, 20, 30, 52], threshold: 12) == FrameDifference(changed: 0, identical: 0.75))
        let moved = FrameDifference(frame, [10, 20, 30, 53], threshold: 12)
        #expect(moved == FrameDifference(changed: 0.25, identical: 0.75))
        #expect(FrameDifference(frame, [255, 255, 255, 255]) == FrameDifference(changed: 1, identical: 0))
        #expect(FrameDifference(frame, [1, 2]) == FrameDifference(changed: 0, identical: 0), "tamanhos diferentes")
    }
}

@Suite("Limite de FPS")
struct FrameRateLimiterTests {
    private func keptCount(sourceFPS: Double, limit: Int, seconds: Double = 2, jitter: Double = 0) -> Int {
        var limiter = FrameRateLimiter(maxFrameRate: limit)
        let frames = Int(sourceFPS * seconds)
        return (0..<frames).filter { index in
            let wobble = index.isMultiple(of: 2) ? jitter : -jitter
            return limiter.shouldKeep(timestamp: Double(index) / sourceFPS + wobble)
        }.count
    }

    @Test("60 → 30 mantém metade dos quadros")
    func halves() {
        #expect(keptCount(sourceFPS: 60, limit: 30) == 60)
    }

    @Test("fonte abaixo ou igual ao limite fica intacta, mesmo com jitter", arguments: [24.0, 29.97, 30])
    func keepsEverything(fps: Double) {
        #expect(keptCount(sourceFPS: fps, limit: 30, jitter: 0.001) == Int(fps * 2))
    }

    @Test("120 → 60 e 60 → 24")
    func otherRatios() {
        #expect(keptCount(sourceFPS: 120, limit: 60) == 120)
        #expect(abs(keptCount(sourceFPS: 60, limit: 24) - 48) <= 1)
    }

    @Test("depois de um buraco na fonte, não deixa passar rajada")
    func resynchronisesAfterGap() {
        var limiter = FrameRateLimiter(maxFrameRate: 30)
        let decisions = [0, 1.0, 1.0 + 1.0 / 60, 1.0 + 2.0 / 60].map { limiter.shouldKeep(timestamp: $0) }
        #expect(decisions == [true, true, false, true])
    }
}
