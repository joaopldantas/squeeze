import Foundation
import SqueezeCore
import Testing
@testable import SqueezeUI

@MainActor
@Suite("Mover originais para o Lixo")
struct TrashOriginalsTests {
    let compressor = FakeCompressor()
    let trash = FakeTrash()

    private func convert(_ names: String..., trashing: Bool = true) async throws -> CompressionViewModel {
        var settings = CompressionSettings()
        settings.movesOriginalsToTrash = trashing
        let viewModel = CompressionViewModel(
            compressor: compressor, thumbnails: NoThumbnails(), store: MemorySettingsStore(settings), trash: trash
        )
        viewModel.add(names.map { URL(fileURLWithPath: "/tmp/videos/\($0)") })
        #expect(await eventually { viewModel.items.allSatisfy { $0.phase != .analyzing } })
        viewModel.convertAll()
        #expect(await eventually { !viewModel.isConverting && viewModel.items.allSatisfy { !$0.isBusy } })
        return viewModel
    }

    @Test("desligado por padrão")
    func offByDefault() {
        #expect(!CompressionSettings().movesOriginalsToTrash)
    }

    @Test("ligado, o original vai para o Lixo depois de uma conversão menor")
    func trashesAfterSuccess() async throws {
        let viewModel = try await convert("a.mov")

        #expect(trash.trashed == [URL(fileURLWithPath: "/tmp/videos/a.mov")])
        #expect(viewModel.items[0].originalTrashed)
    }

    @Test("desligado, nada sai do lugar")
    func keepsOriginalWhenOff() async throws {
        let viewModel = try await convert("a.mov", trashing: false)

        #expect(trash.trashed.isEmpty)
        #expect(!viewModel.items[0].originalTrashed)
    }

    @Test("se a saída cresceu, mantém o original")
    func keepsOriginalWhenOutputGrew() async throws {
        compressor.grow("a.mov")
        let viewModel = try await convert("a.mov")

        #expect(trash.trashed.isEmpty)
        #expect(viewModel.items[0].result != nil)
    }

    @Test("falha ou cancelamento nunca tocam no original")
    func keepsOriginalOnFailure() async throws {
        compressor.fail("a.mov", with: .diskFull)
        _ = try await convert("a.mov", "b.mov")

        #expect(trash.trashed == [URL(fileURLWithPath: "/tmp/videos/b.mov")])
    }

    @Test("se o Lixo recusar, avisa e o arquivo continua concluído")
    func trashFailure() async throws {
        trash.failEverything()
        let viewModel = try await convert("a.mov")

        #expect(viewModel.items[0].result != nil)
        #expect(!viewModel.items[0].originalTrashed)
        #expect(viewModel.notice == "Não foi possível mover “a.mov” para o Lixo.")
    }

    @Test("a opção é salva com os outros ajustes")
    func persists() throws {
        var settings = CompressionSettings()
        settings.movesOriginalsToTrash = true
        let decoded = try JSONDecoder().decode(CompressionSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.movesOriginalsToTrash)
    }
}
