@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SqueezeCore

@Suite("Tratamento de erros", .tags(.integration), .serialized, .timeLimit(.minutes(1)))
struct ErrorHandlingIntegrationTests {
    let directory: TemporaryDirectory
    let compressor = VideoCompressor()

    init() throws {
        directory = try TemporaryDirectory()
    }

    @Test("arquivo corrompido falha com erro claro e não deixa saída")
    func corruptFile() async throws {
        let source = try FixtureFactory.makeCorruptFile(in: directory.url)

        let error = await #expect(throws: SqueezeError.self) {
            try await compressor.compress(ConversionRequest(source: source))
        }
        guard case .unreadableFile = error else {
            Issue.record("esperava unreadableFile, veio \(String(describing: error))")
            return
        }
        #expect(try directory.allContents() == ["corrompido.mov"])
    }

    @Test("arquivo inexistente")
    func missingFile() async {
        let source = directory.url.appendingPathComponent("sumiu.mov")
        await #expect(throws: SqueezeError.self) {
            try await compressor.compress(ConversionRequest(source: source))
        }
    }

    @Test("cancelar no meio interrompe o job e apaga os temporários")
    func cancellation() async throws {
        var spec = FixtureSpec.landscape
        spec.duration = 6
        let source = try await FixtureFactory.make(spec, in: directory.url)
        let canceller = TaskCanceller()
        let progressSeen = ProgressRecorder()
        let compressor = compressor

        let task = Task {
            try await compressor.compress(ConversionRequest(source: source)) { fraction in
                progressSeen.record(fraction)
                if fraction > 0.2 {
                    canceller.cancel()
                }
            }
        }
        canceller.attach(task)

        await #expect(throws: SqueezeError.cancelled) {
            try await task.value
        }
        #expect(progressSeen.maximum > 0.2)
        #expect(progressSeen.maximum < 1, "o job não pode ter terminado")
        #expect(try directory.allContents() == ["landscape.mov"])
    }

    @Test("cancelar antes de começar não cria nada")
    func cancelledBeforeStart() async throws {
        let source = try await FixtureFactory.make(.landscape, in: directory.url)
        let compressor = compressor
        let task = Task {
            try await compressor.compress(ConversionRequest(source: source))
        }
        task.cancel()

        await #expect(throws: SqueezeError.cancelled) {
            try await task.value
        }
        #expect(try directory.allContents() == ["landscape.mov"])
    }

    @Test("ProRes não pode ir para MP4 em passthrough, mas pode ser reencodado")
    func proResPassthrough() async throws {
        var spec = FixtureSpec.landscape
        spec.codec = .proRes422
        spec.duration = 1
        spec.includesAudio = false
        let source = try await FixtureFactory.make(spec, in: directory.url)

        await #expect(throws: SqueezeError.passthroughUnsupported(codec: "apcn")) {
            try await compressor.compress(ConversionRequest(source: source, preset: .original))
        }
        let result = try await compressor.compress(ConversionRequest(source: source, preset: .balanced))
        #expect(result.comparison.outputBytes < result.comparison.originalBytes)
    }

    @Test("tamanho alvo impossível é recusado antes de converter")
    func impossibleTarget() async throws {
        let source = try await FixtureFactory.make(.landscape, in: directory.url)
        let error = await #expect(throws: SqueezeError.self) {
            try await compressor.preview(ConversionRequest(source: source, preset: .targetSize(megabytes: 0.01)))
        }
        guard case .targetSizeTooSmall = error else {
            Issue.record("esperava targetSizeTooSmall, veio \(String(describing: error))")
            return
        }
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.withLock { values.append(value) }
    }

    var maximum: Double {
        lock.withLock { values.max() ?? 0 }
    }
}
