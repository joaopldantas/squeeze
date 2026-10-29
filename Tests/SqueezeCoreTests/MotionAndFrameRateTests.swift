import Testing
@testable import SqueezeCore

@Suite("Detecção de movimento")
struct MotionLevelTests {
    @Test(arguments: [
        ([], MotionLevel.normal),
        ([0.0, 0.01, 0.02], .low),
        ([0.1, 0.15, 0.2], .normal),
        ([0.4, 0.5, 0.9], .high),
        // Um corte de cena não transforma uma gravação de tela parada em vídeo agitado.
        ([0.0, 0.0, 0.01, 0.95], .low)
    ])
    func classify(fractions: [Double], expected: MotionLevel) {
        #expect(MotionLevel.classify(changedFractions: fractions) == expected)
    }

    @Test("fração de pixels alterados respeita o limiar de ruído")
    func changedFraction() {
        let frame: [UInt8] = [10, 20, 30, 40]
        #expect(MotionLevel.changedFraction(frame, frame) == 0)
        #expect(MotionLevel.changedFraction(frame, [10, 20, 30, 52], threshold: 12) == 0)
        #expect(MotionLevel.changedFraction(frame, [10, 20, 30, 53], threshold: 12) == 0.25)
        #expect(MotionLevel.changedFraction(frame, [255, 255, 255, 255]) == 1)
        #expect(MotionLevel.changedFraction(frame, [1, 2]) == 0, "tamanhos diferentes não são comparáveis")
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
