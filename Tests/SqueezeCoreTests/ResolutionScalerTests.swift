import Testing
@testable import SqueezeCore

@Suite("Redimensionamento mantendo proporção")
struct ResolutionScalerTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let source: PixelSize
        let maxLongEdge: Int?
        let expected: PixelSize
        var testDescription: String { "\(source) até \(maxLongEdge.map(String.init) ?? "∞") → \(expected)" }
    }

    @Test(arguments: [
        Case(source: .init(width: 1920, height: 1080), maxLongEdge: 1280, expected: .init(width: 1280, height: 720)),
        Case(source: .init(width: 1080, height: 1920), maxLongEdge: 1280, expected: .init(width: 720, height: 1280)),
        Case(source: .init(width: 3840, height: 2160), maxLongEdge: 1920, expected: .init(width: 1920, height: 1080)),
        Case(source: .init(width: 2880, height: 1800), maxLongEdge: 1920, expected: .init(width: 1920, height: 1200)),
        Case(source: .init(width: 1170, height: 2532), maxLongEdge: 1280, expected: .init(width: 592, height: 1280)),
        Case(source: .init(width: 3840, height: 2160), maxLongEdge: nil, expected: .init(width: 3840, height: 2160))
    ])
    func fit(_ testCase: Case) {
        #expect(ResolutionScaler.fit(testCase.source, maxLongEdge: testCase.maxLongEdge) == testCase.expected)
    }

    @Test("nunca aumenta a resolução")
    func neverUpscales() {
        let size = PixelSize(width: 1280, height: 720)
        #expect(ResolutionScaler.fit(size, maxLongEdge: 3840) == size)
    }

    @Test("dimensões ímpares viram pares", arguments: [nil, 4000] as [Int?])
    func evenDimensions(maxLongEdge: Int?) {
        let result = ResolutionScaler.fit(PixelSize(width: 1279, height: 719), maxLongEdge: maxLongEdge)
        #expect(result == PixelSize(width: 1278, height: 718))
    }

    @Test("proporção preservada em qualquer limite", arguments: Array(stride(from: 320, through: 3840, by: 160)))
    func preservesAspectRatio(maxLongEdge: Int) {
        let source = PixelSize(width: 2532, height: 1170)
        let result = ResolutionScaler.fit(source, maxLongEdge: maxLongEdge)
        let sourceRatio = Double(source.width) / Double(source.height)
        let resultRatio = Double(result.width) / Double(result.height)
        #expect(result.width.isMultiple(of: 2) && result.height.isMultiple(of: 2))
        #expect(result.longEdge <= max(maxLongEdge, 2))
        #expect(abs(resultRatio - sourceRatio) / sourceRatio < 0.01)
    }
}
