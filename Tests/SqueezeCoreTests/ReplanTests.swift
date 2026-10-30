import Foundation
import Testing
@testable import SqueezeCore

@Suite("Replanejar sem reler o arquivo")
struct ReplanTests {
    let compressor = VideoCompressor()
    let info = MediaInfo.sample(width: 2880, height: 1800, frameRate: 60, duration: 120)

    private func preview(_ preset: Preset, motion: MotionLevel) throws -> ConversionPreview {
        let request = ConversionRequest(source: info.url, preset: preset)
        let plan = try EncodingPlanner().plan(for: preset, source: info, motion: motion)
        let estimate = SizeComparison(
            originalBytes: info.fileSize,
            outputBytes: SizeEstimator.estimatedBytes(for: plan, source: info)
        )
        return ConversionPreview(request: request, info: info, motion: motion, plan: plan, estimate: estimate)
    }

    @Test("trocar o preset recalcula plano e estimativa com o movimento já medido")
    func switchesPreset() throws {
        let original = try preview(.original, motion: .low)
        let request = ConversionRequest(source: info.url, preset: .balanced)
        let replanned = try compressor.replan(original, for: request)

        #expect(replanned.request == request)
        #expect(replanned.motion == .low)
        #expect(replanned.plan == (try EncodingPlanner().plan(for: .balanced, source: info, motion: .low)))
        #expect(replanned.estimate.outputBytes < original.estimate.outputBytes)
    }

    @Test("erros de planejamento saem tipados")
    func typedErrors() throws {
        let base = try preview(.balanced, motion: .normal)
        let request = ConversionRequest(source: info.url, preset: .targetSize(megabytes: 0.01))
        #expect {
            try compressor.replan(base, for: request)
        } throws: { error in
            guard case .targetSizeTooSmall = error as? SqueezeError else { return false }
            return true
        }
    }
}
