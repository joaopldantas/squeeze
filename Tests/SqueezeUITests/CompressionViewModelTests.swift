import Foundation
import SqueezeCore
import Testing
@testable import SqueezeUI

@MainActor
@Suite("ViewModel da janela principal")
struct CompressionViewModelTests {
    let compressor = FakeCompressor()
    let store = MemorySettingsStore()

    private func makeViewModel() -> CompressionViewModel {
        CompressionViewModel(compressor: compressor, thumbnails: NoThumbnails(), store: store)
    }

    private func urls(_ names: String...) -> [URL] {
        names.map { URL(fileURLWithPath: "/tmp/videos/\($0)") }
    }

    private func analyzed(_ viewModel: CompressionViewModel, _ names: String...) async throws {
        viewModel.add(names.map { URL(fileURLWithPath: "/tmp/videos/\($0)") })
        #expect(await eventually { viewModel.items.allSatisfy { $0.phase != .analyzing } })
    }

    // MARK: Adicionar

    @Test("aceita só vídeos, ignora duplicados e avisa o que pulou")
    func addFiltersAndDeduplicates() {
        let viewModel = makeViewModel()
        viewModel.add(urls("a.mov", "notas.txt", "b.MP4", "a.mov"))
        #expect(viewModel.notice == "1 arquivo(s) ignorado(s): não são vídeos.")

        viewModel.add(urls("a.mov"))
        #expect(viewModel.items.map(\.name) == ["a.mov", "b.MP4"])
        #expect(viewModel.notice == nil, "o aviso vale só para a última ação")
    }

    @Test("pasta solta adiciona os vídeos de dentro")
    func addFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["b.mov", "a.m4v", "leia.txt", ".oculto.mov"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }

        let viewModel = makeViewModel()
        viewModel.add([folder])
        #expect(viewModel.items.map(\.name) == ["a.m4v", "b.mov"])
    }

    @Test("analisa e mostra a estimativa para os ajustes atuais")
    func analysisProducesPreview() async throws {
        let viewModel = makeViewModel()
        try await analyzed(viewModel, "a.mov")
        let item = try #require(viewModel.items.first)

        #expect(item.phase == .ready)
        #expect(item.preview?.request.preset == .balanced)
        #expect(item.canConvert)
        #expect(viewModel.summary.pendingCount == 1)
        #expect(viewModel.summary.pending.outputBytes < viewModel.summary.pending.originalBytes)
    }

    @Test("arquivo corrompido vira erro no próprio item")
    func unreadableFile() async throws {
        compressor.markUnreadable("ruim.mov")
        let viewModel = makeViewModel()
        try await analyzed(viewModel, "ruim.mov", "bom.mov")

        #expect(viewModel.items[0].phase == .failed(.unreadableFile(reason: "fake")))
        #expect(!viewModel.items[0].canConvert)
        #expect(viewModel.items[1].phase == .ready)
    }

    // MARK: Ajustes

    @Test("trocar o preset recalcula a estimativa na hora e salva os ajustes")
    func settingsReplanAndPersist() async throws {
        let viewModel = makeViewModel()
        try await analyzed(viewModel, "a.mov")
        let balanced = try #require(viewModel.items.first?.preview?.estimate.outputBytes)

        viewModel.settings.presetKind = .smallest
        let smallest = try #require(viewModel.items.first?.preview?.estimate.outputBytes)

        #expect(smallest < balanced)
        #expect(viewModel.items.first?.preview?.request.preset == .smallest)
        #expect(store.saved?.presetKind == .smallest)
    }

    @Test("tamanho alvo impossível bloqueia só aquele arquivo, até mudar o ajuste")
    func planErrorBlocksConversion() async throws {
        let viewModel = makeViewModel()
        try await analyzed(viewModel, "a.mov")
        let item = try #require(viewModel.items.first)

        viewModel.settings.presetKind = .targetSize
        viewModel.settings.targetMegabytes = 0.1
        guard case .targetSizeTooSmall = item.planError else {
            Issue.record("esperava targetSizeTooSmall, veio \(String(describing: item.planError))")
            return
        }
        #expect(!item.canConvert)
        #expect(!viewModel.canConvert)

        viewModel.settings.targetMegabytes = 50
        #expect(item.planError == nil)
        #expect(item.canConvert)
    }

    @Test("ajustes salvos são carregados ao abrir")
    func loadsSavedSettings() {
        var saved = CompressionSettings()
        saved.presetKind = .web720
        saved.outputFolder = URL(fileURLWithPath: "/tmp/saida")
        let viewModel = CompressionViewModel(
            compressor: compressor, thumbnails: NoThumbnails(), store: MemorySettingsStore(saved)
        )
        #expect(viewModel.settings == saved)
    }

    // MARK: Converter

    @Test("converte em ordem, soma o economizado e avisa o fim do lote uma vez")
    func convertAll() async throws {
        let viewModel = makeViewModel()
        var batches: [QueueSummary] = []
        viewModel.onBatchFinished = { batches.append($0) }
        try await analyzed(viewModel, "a.mov", "b.mov")

        viewModel.convertAll()
        #expect(await eventually { batches.count == 1 })

        #expect(compressor.compressed.map(\.name) == ["a.mov", "b.mov"])
        #expect(viewModel.items.allSatisfy { $0.result != nil })
        #expect(viewModel.summary.completedCount == 2)
        #expect(viewModel.summary.pendingCount == 0)
        #expect(batches.first?.completed.savedBytes ?? 0 > 0)
        #expect(!viewModel.isConverting)
    }

    @Test("cancelar o item em andamento não para o resto do lote")
    func cancelRunningItem() async throws {
        compressor.block("lento.mov")
        let viewModel = makeViewModel()
        try await analyzed(viewModel, "lento.mov", "b.mov")
        let slow = viewModel.items[0]

        viewModel.convertAll()
        #expect(await eventually { slow.phase == .converting(progress: 0.5) })
        viewModel.cancel(slow)

        #expect(await eventually { !viewModel.isConverting })
        #expect(slow.phase == .cancelled)
        #expect(viewModel.items[1].result != nil)
        #expect(slow.canConvert, "um item cancelado pode ser convertido de novo")
    }

    @Test("cancelar um item na fila tira ele do lote")
    func cancelQueuedItem() async throws {
        compressor.block("lento.mov")
        let viewModel = makeViewModel()
        try await analyzed(viewModel, "lento.mov", "esperando.mov")
        let (slow, waiting) = (viewModel.items[0], viewModel.items[1])

        viewModel.convertAll()
        #expect(await eventually { slow.phase == .converting(progress: 0.5) })
        #expect(waiting.phase == .queued)
        viewModel.cancel(waiting)
        viewModel.cancel(slow)

        #expect(await eventually { !viewModel.isConverting })
        #expect(waiting.phase == .ready)
        #expect(compressor.compressed.map(\.name) == ["lento.mov"])
    }

    @Test("falha num arquivo não interrompe os outros")
    func failureDoesNotStopBatch() async throws {
        compressor.fail("a.mov", with: .diskFull)
        let viewModel = makeViewModel()
        try await analyzed(viewModel, "a.mov", "b.mov")

        viewModel.convertAll()
        #expect(await eventually { !viewModel.isConverting && viewModel.items[1].result != nil })
        #expect(viewModel.items[0].phase == .failed(.diskFull))
        #expect(viewModel.items[0].error == .diskFull)
    }

    @Test("quando a saída cresce, tentar de novo usa o preset sugerido só naquele arquivo")
    func retryWithSuggestedPreset() async throws {
        compressor.grow("a.mov")
        let viewModel = makeViewModel()
        try await analyzed(viewModel, "a.mov")
        let item = viewModel.items[0]

        viewModel.convertAll()
        #expect(await eventually { item.result != nil })
        let suggestion = try #require(item.result?.suggestedPreset)
        #expect(suggestion == .smallest)

        viewModel.retry(item, with: suggestion)
        #expect(await eventually { compressor.compressed.count == 2 && !viewModel.isConverting })
        #expect(compressor.compressed.last?.preset == .smallest)
        #expect(viewModel.settings.presetKind == .balanced, "o ajuste global não muda")
    }

    @Test("remover um item em conversão cancela o job")
    func removeWhileConverting() async throws {
        compressor.block("a.mov")
        let viewModel = makeViewModel()
        try await analyzed(viewModel, "a.mov")
        let item = viewModel.items[0]

        viewModel.convertAll()
        #expect(await eventually { item.phase == .converting(progress: 0.5) })
        viewModel.remove(item)

        #expect(viewModel.items.isEmpty)
        #expect(await eventually { !viewModel.isConverting })
        #expect(item.phase == .cancelled)
    }

    @Test("limpar concluídos mantém os pendentes")
    func clearCompleted() async throws {
        compressor.fail("b.mov", with: .diskFull)
        let viewModel = makeViewModel()
        try await analyzed(viewModel, "a.mov", "b.mov")
        viewModel.convertAll()
        #expect(await eventually { !viewModel.isConverting })

        viewModel.clearCompleted()
        #expect(viewModel.items.map(\.name) == ["b.mov"])
    }
}
