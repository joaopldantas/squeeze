import Foundation
import Testing
@testable import SqueezeUI

@Suite("Detecção de arquivos novos na pasta")
struct NewFileDetectorTests {
    private let old = URL(fileURLWithPath: "/tmp/mesa/antiga.mov")
    private let new = URL(fileURLWithPath: "/tmp/mesa/nova.mov")

    @Test("o que já estava na pasta nunca é reportado")
    func ignoresExisting() {
        var detector = NewFileDetector(existing: [old])
        #expect(detector.update([old: 10]).isEmpty)
        #expect(detector.update([old: 10]).isEmpty)
        #expect(!detector.isWaiting)
    }

    @Test("arquivo novo só sai quando o tamanho para de mudar")
    func waitsUntilStable() {
        var detector = NewFileDetector(existing: [old])
        #expect(detector.update([old: 10, new: 100]).isEmpty)
        #expect(detector.isWaiting)
        #expect(detector.update([old: 10, new: 500]).isEmpty, "ainda crescendo")
        #expect(detector.update([old: 10, new: 500]) == [new])
        #expect(!detector.isWaiting)
        #expect(detector.update([old: 10, new: 500]).isEmpty, "reportado uma vez só")
    }

    @Test("arquivo vazio não conta como completo")
    func emptyIsNotComplete() {
        var detector = NewFileDetector(existing: [])
        #expect(detector.update([new: 0]).isEmpty)
        #expect(detector.update([new: 0]).isEmpty)
        #expect(detector.isWaiting)
    }

    @Test("arquivo que some deixa de ser esperado; se voltar, é novo de novo")
    func forgetsRemovedFiles() {
        var detector = NewFileDetector(existing: [old])
        _ = detector.update([old: 10, new: 100])
        #expect(detector.update([old: 10]).isEmpty)
        #expect(!detector.isWaiting)

        _ = detector.update([old: 10, new: 5])
        #expect(detector.update([old: 10, new: 5]) == [new], "recriado com o mesmo nome")
    }
}

@MainActor
@Suite("Vigia da pasta")
struct FolderWatcherTests {
    @Test("entrega o vídeo novo quando termina de ser gravado, e só os aceitos")
    func deliversNewVideos() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: folder.appendingPathComponent("antiga.mov"))

        var delivered: [String] = []
        let watcher = FolderWatcher(
            folder: folder,
            settleInterval: .milliseconds(50),
            accept: { !$0.lastPathComponent.hasPrefix("recusar") },
            found: { delivered += $0.map(\.lastPathComponent) }
        )
        #expect(watcher != nil)

        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("gravacao.mov"))
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("recusar.mov"))
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("notas.txt"))

        #expect(await eventually { delivered == ["gravacao.mov"] })
        _ = watcher
    }

    @Test("pasta que não existe não vira vigia")
    func missingFolder() {
        let watcher = FolderWatcher(folder: URL(fileURLWithPath: "/nao/existe")) { _ in }
        #expect(watcher == nil)
    }
}

@Suite("Gravações de tela")
struct ScreenRecordingsTests {
    @Test("reconhece a gravação pela marca que o macOS põe no arquivo")
    func detectsTag() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!ScreenRecordings.isRecording(file))

        let value = Data("bplist00\u{9}".utf8)
        let status = value.withUnsafeBytes { bytes in
            setxattr(file.path, "com.apple.metadata:kMDItemIsScreenRecording", bytes.baseAddress, bytes.count, 0, 0)
        }
        #expect(status == 0)
        #expect(ScreenRecordings.isRecording(file))
    }
}
