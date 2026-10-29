import Foundation
import Testing
@testable import SqueezeCore

@Suite("Nome de saída sem colisão")
struct OutputNamerTests {
    let source = URL(fileURLWithPath: "/Users/me/Movies/Gravação de Tela.mov")
    let directory = URL(fileURLWithPath: "/Users/me/Movies")

    @Test("sem colisão usa nome_compressed.mp4")
    func noCollision() {
        let url = OutputNamer.availableURL(for: source, in: directory) { _ in false }
        #expect(url.lastPathComponent == "Gravação de Tela_compressed.mp4")
        #expect(url.deletingLastPathComponent().path == directory.path)
    }

    @Test("pula nomes existentes")
    func skipsExisting() {
        let taken: Set<String> = ["Gravação de Tela_compressed.mp4", "Gravação de Tela_compressed_2.mp4"]
        let url = OutputNamer.availableURL(for: source, in: directory) { taken.contains($0.lastPathComponent) }
        #expect(url.lastPathComponent == "Gravação de Tela_compressed_3.mp4")
    }

    @Test("preserva pontos no nome e troca só a extensão")
    func keepsDotsInStem() {
        let source = URL(fileURLWithPath: "/tmp/viagem.2024.final.MOV")
        let url = OutputNamer.availableURL(for: source, in: directory) { _ in false }
        #expect(url.lastPathComponent == "viagem.2024.final_compressed.mp4")
    }

    @Test("o original nunca é candidato, mesmo se já for .mp4")
    func neverTargetsTheSource() {
        let source = URL(fileURLWithPath: "/tmp/clip.mp4")
        let candidates = Array(OutputNamer.candidates(for: source, in: source.deletingLastPathComponent()).prefix(50))
        #expect(!candidates.contains(source))
        #expect(Set(candidates).count == candidates.count)
    }

    @Test("pasta de saída: ao lado do original ou fixa")
    func outputLocation() {
        let fixed = URL(fileURLWithPath: "/Volumes/Backup/Comprimidos")
        #expect(OutputLocation.besideOriginal.directory(for: source).path == directory.path)
        #expect(OutputLocation.folder(fixed).directory(for: source) == fixed)
    }
}
