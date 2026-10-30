import Testing
@testable import SqueezeCore

@Suite("Fim do arquivo danificado")
struct DamagedTailTests {
    @Test("tolera até 2 s ou 2% perdidos no fim", arguments: [
        (0.07, 60.0, true),
        (2.0, 10.0, true),
        (2.1, 10.0, false),
        (2.4, 120.0, true),
        (3.0, 120.0, false),
        (30.0, 60.0, false)
    ])
    func tolerance(missing: Double, duration: Double, tolerated: Bool) {
        #expect(AssetRewriter.isDamagedTail(missing: missing, duration: duration) == tolerated)
    }

    @Test("duração ou falta inválidas nunca são toleradas")
    func invalidInputs() {
        #expect(!AssetRewriter.isDamagedTail(missing: 0.1, duration: 0))
        #expect(!AssetRewriter.isDamagedTail(missing: .nan, duration: 10))
    }
}
