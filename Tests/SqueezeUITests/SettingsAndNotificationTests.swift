import Foundation
import SqueezeCore
import Testing
@testable import SqueezeUI

@Suite("Ajustes salvos")
struct CompressionSettingsTests {
    @Test("ajustes de uma versão antiga, sem as chaves novas, ainda carregam")
    func decodesOlderSettings() throws {
        let json = Data(#"{"presetKind":"web720","targetMegabytes":12}"#.utf8)
        let settings = try JSONDecoder().decode(CompressionSettings.self, from: json)

        #expect(settings.presetKind == .web720)
        #expect(settings.targetMegabytes == 12)
        #expect(settings.maxConcurrentJobs == 1)
        #expect(settings.outputFolder == nil)
    }

    @Test("ida e volta em JSON preserva tudo")
    func roundTrip() throws {
        var settings = CompressionSettings()
        settings.presetKind = .targetSize
        settings.targetMegabytes = 8
        settings.codec = .h264
        settings.frameRate = .limit(30)
        settings.audio = .remove
        settings.outputFolder = URL(fileURLWithPath: "/tmp/saida")
        settings.maxConcurrentJobs = 2

        let decoded = try JSONDecoder().decode(CompressionSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test("jobs simultâneos ficam entre 1 e 2", arguments: [(0, 1), (1, 1), (2, 2), (8, 2)])
    func clampsConcurrency(value: Int, expected: Int) throws {
        var settings = CompressionSettings()
        settings.maxConcurrentJobs = value
        #expect(settings.maxConcurrentJobs == expected)

        let json = Data(#"{"maxConcurrentJobs":\#(value)}"#.utf8)
        #expect(try JSONDecoder().decode(CompressionSettings.self, from: json).maxConcurrentJobs == expected)
    }

    @Test("preset original não aceita opções de vídeo")
    func passthroughDisablesVideoOptions() {
        var settings = CompressionSettings()
        #expect(settings.allowsVideoOptions)
        settings.presetKind = .original
        #expect(!settings.allowsVideoOptions)
    }
}

@Suite("Notificação de fim de lote")
struct BatchNotificationTests {
    private func report(completed: Int, failed: Int = 0, cancelled: Int = 0) -> BatchReport {
        var report = BatchReport()
        report.completed = completed
        report.failed = failed
        report.cancelled = cancelled
        report.sizes = SizeComparison(originalBytes: 360_000_000, outputBytes: 60_000_000)
        return report
    }

    @Test("resume quantos vídeos e quanto economizou")
    func success() {
        let notification = BatchNotification(report(completed: 3))
        #expect(notification == BatchNotification(title: "3 vídeos comprimidos", body: "360,0 MB → 60,0 MB (−83%)"))
        #expect(BatchNotification(report(completed: 1))?.title == "1 vídeo comprimido")
    }

    @Test("menciona falhas")
    func withFailures() {
        #expect(BatchNotification(report(completed: 2, failed: 1))?.body == "360,0 MB → 60,0 MB (−83%) · 1 com erro")
        let onlyFailures = BatchNotification(report(completed: 0, failed: 2))
        #expect(onlyFailures == BatchNotification(title: "Nenhum vídeo comprimido", body: "2 com erro"))
    }

    @Test("lote cancelado pelo usuário não notifica")
    func cancelledOnly() {
        #expect(BatchNotification(report(completed: 0, cancelled: 3)) == nil)
    }
}
