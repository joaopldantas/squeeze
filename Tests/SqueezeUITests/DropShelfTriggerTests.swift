import CoreGraphics
import Testing
@testable import SqueezeUI

@Suite("Mini área de soltar")
struct DropShelfTriggerTests {
    let trigger = DropShelfTrigger(activationDistance: 140)

    // Tela de 1000 pt: o topo fica em y = 1000 e a área ativa vai até y = 860.
    @Test("abre só com vídeo sendo arrastado perto do topo", arguments: [
        (CGFloat(1000), true, true),
        (CGFloat(870), true, true),
        (CGFloat(860), true, true),
        (CGFloat(859), true, false),
        (CGFloat(400), true, false),
        (CGFloat(1000), false, false)
    ])
    func opens(cursorY: CGFloat, draggingVideos: Bool, expected: Bool) {
        #expect(trigger.shouldOpen(cursorY: cursorY, screenTop: 1000, draggingVideos: draggingVideos) == expected)
    }

    @Test("monitores empilhados: usa o topo da tela do cursor")
    func secondScreen() {
        // Monitor de cima vai de y = 1000 a y = 2000.
        #expect(trigger.shouldOpen(cursorY: 1950, screenTop: 2000, draggingVideos: true))
        #expect(!trigger.shouldOpen(cursorY: 1950, screenTop: 3000, draggingVideos: true))
    }
}
