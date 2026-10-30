import Foundation
import Testing
@testable import SqueezeCore

@Suite("Cálculo de bitrate")
struct BitrateCalculatorTests {
    @Test("tamanho alvo desconta áudio e overhead do container")
    func targetSizeSubtractsAudioAndOverhead() throws {
        let bitrate = try BitrateCalculator.videoBitrate(targetBytes: 10_000_000, duration: 60, audioBitrate: 96_000)
        // 10 MB × 8 × 0.98 / 60 s − 96 kbps
        #expect(bitrate == 1_210_666)
    }

    @Test("arquivo gerado com o bitrate calculado cabe no tamanho alvo", arguments: [5.0, 25, 100])
    func targetSizeRoundTrip(megabytes: Double) throws {
        let source = MediaInfo.sample(duration: 90)
        let plan = try EncodingPlanner().plan(for: .targetSize(megabytes: megabytes), source: source)
        let estimate = SizeEstimator.estimatedBytes(for: plan, source: source)
        let target = ByteUnits.bytes(megabytes: megabytes)
        #expect(estimate <= target)
        #expect(Double(estimate) > Double(target) * 0.97, "não deve sobrar espaço demais")
    }

    @Test("tamanho alvo impossível informa o mínimo")
    func targetTooSmallReportsMinimum() {
        let minimum = BitrateCalculator.minimumTargetBytes(duration: 600, audioBitrate: 96_000)
        #expect(throws: SqueezeError.targetSizeTooSmall(minimumBytes: minimum)) {
            try BitrateCalculator.videoBitrate(targetBytes: 1_000_000, duration: 600, audioBitrate: 96_000)
        }
        #expect(throws: Never.self) {
            try BitrateCalculator.videoBitrate(targetBytes: minimum, duration: 600, audioBitrate: 96_000)
        }
    }

    @Test("duração inválida", arguments: [0, -1, Double.nan, Double.infinity])
    func invalidDuration(duration: Double) {
        #expect(throws: SqueezeError.invalidDuration) {
            try BitrateCalculator.videoBitrate(targetBytes: 10_000_000, duration: duration, audioBitrate: 0)
        }
    }

    @Test("1080p30 HEVC com movimento normal usa a referência")
    func referencePoint() {
        let bitrate = adaptive(PixelSize(width: 1920, height: 1080), fps: 30)
        #expect(bitrate == 4_000_000)
    }

    @Test("4K60 precisa de ~4× a referência, não 8×")
    func scalesSubLinearly() {
        let bitrate = adaptive(PixelSize(width: 3840, height: 2160), fps: 60)
        #expect(abs(Double(bitrate) / 4_000_000 - 4) < 0.01)
    }

    @Test("acima de 60 fps (câmera lenta) o bitrate para de crescer", arguments: [120.0, 240])
    func highFrameRateIsCapped(fps: Double) {
        let size = PixelSize(width: 1920, height: 1080)
        #expect(adaptive(size, fps: fps) == adaptive(size, fps: 60))
    }

    @Test("H.264 precisa de mais bits que HEVC")
    func h264NeedsMoreBits() {
        let size = PixelSize(width: 1280, height: 720)
        let hevc = adaptive(size, fps: 30, codec: .hevc)
        let h264 = adaptive(size, fps: 30, codec: .h264)
        #expect(abs(Double(h264) / Double(hevc) - 1.4) < 0.001)
    }

    @Test("pouco movimento reduz o bitrate, muito movimento aumenta")
    func motionAdjustsBitrate() {
        let size = PixelSize(width: 2880, height: 1800)
        let low = adaptive(size, fps: 60, motion: .low)
        let normal = adaptive(size, fps: 60, motion: .normal)
        let high = adaptive(size, fps: 60, motion: .high)
        #expect(low < normal)
        #expect(normal < high)
    }

    @Test("nunca abaixo do mínimo")
    func neverBelowMinimum() {
        let bitrate = adaptive(PixelSize(width: 160, height: 90), fps: 5, motion: .low)
        #expect(bitrate == BitrateCalculator.minimumVideoBitrate)
    }

    private func adaptive(
        _ size: PixelSize,
        fps: Double,
        codec: VideoCodec = .hevc,
        motion: MotionLevel = .normal
    ) -> Int {
        BitrateCalculator.adaptiveBitrate(
            referenceBitrate: 4_000_000, size: size, frameRate: fps, codec: codec, motion: motion
        )
    }
}
