import ArgumentParser
import Foundation
import Testing
@testable import SqueezeCLI
@testable import SqueezeCore

@Suite("Argumentos da CLI")
struct SqueezeCommandTests {
    private func parse(_ arguments: [String]) throws -> SqueezeCommand {
        try SqueezeCommand.parse(arguments)
    }

    @Test("padrão: equilibrado, ao lado do original, sem opções avançadas")
    func defaults() throws {
        let command = try parse(["video.mov"])
        let request = try #require(command.requests().first)

        #expect(request.preset == .balanced)
        #expect(request.overrides == .none)
        #expect(request.output == .besideOriginal)
        #expect(request.source.lastPathComponent == "video.mov")
    }

    @Test("nomes de preset", arguments: [
        ("high", Preset.highQuality), ("balanced", .balanced), ("smallest", .smallest),
        ("web720", .web(.p720)), ("web1080", .web(.p1080)), ("original", .original)
    ])
    func presets(name: String, expected: Preset) throws {
        #expect(try parse(["a.mov", "--preset", name]).resolvedPreset == expected)
    }

    @Test("--target-size vira preset de tamanho alvo")
    func targetSize() throws {
        #expect(try parse(["a.mov", "--target-size", "25"]).resolvedPreset == .targetSize(megabytes: 25))
    }

    @Test("opções avançadas viram overrides, convertendo kbps")
    func overrides() throws {
        let command = try parse([
            "a.mov", "--codec", "h264", "--max-size", "1280", "--fps", "30",
            "--bitrate", "2500", "--audio-bitrate", "96"
        ])
        #expect(command.overrides == EncodingOverrides(
            codec: .h264, maxLongEdge: 1280, frameRate: .limit(30),
            videoBitrate: 2_500_000, audio: .aac(bitrate: 96_000)
        ))
    }

    @Test("--fps keep preserva a taxa original")
    func keepFrameRate() throws {
        #expect(try parse(["a.mov", "--fps", "keep"]).overrides.frameRate == .keep)
    }

    @Test("--no-audio remove o áudio")
    func noAudio() throws {
        #expect(try parse(["a.mov", "--no-audio"]).overrides.audio == .remove)
    }

    @Test("pasta de saída expande ~")
    func outputFolder() throws {
        let command = try parse(["a.mov", "-o", "~/Desktop/Saida"])
        let expected = URL(fileURLWithPath: NSString(string: "~/Desktop/Saida").expandingTildeInPath, isDirectory: true)
        #expect(command.outputLocation == .folder(expected))
    }

    @Test("vários arquivos viram vários pedidos com as mesmas opções")
    func multipleFiles() throws {
        let requests = try parse(["a.mov", "b.mov", "-p", "smallest"]).requests()
        #expect(requests.map(\.source.lastPathComponent) == ["a.mov", "b.mov"])
        #expect(Set(requests.map(\.preset)) == [.smallest])
    }

    @Test("combinações inválidas são recusadas", arguments: [
        ["a.mov", "--target-size", "0"],
        ["a.mov", "--no-audio", "--audio-bitrate", "96"],
        ["a.mov", "--max-size", "8"],
        ["a.mov", "--bitrate", "0"],
        ["a.mov", "--preset", "original", "--codec", "h264"],
        ["a.mov", "--preset", "original", "--target-size", "10"],
        ["a.mov", "--preset", "ultra"],
        []
    ])
    func invalid(arguments: [String]) {
        #expect(throws: (any Error).self) {
            try parse(arguments)
        }
    }

    @Test("sugestão de preset usa o nome da CLI")
    func presetSpelling() {
        #expect(PresetChoice(.smallest) == .smallest)
        #expect(PresetChoice(.web(.p720)) == .web720)
        #expect(PresetChoice(.targetSize(megabytes: 5)) == nil)
    }
}
