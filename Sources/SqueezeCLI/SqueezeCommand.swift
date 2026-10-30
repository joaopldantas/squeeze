import ArgumentParser
import Foundation
import SqueezeCore

@main
struct SqueezeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "squeeze",
        abstract: "Comprime vídeos (.mov) para .mp4 usando o encoder de hardware do Mac.",
        discussion: """
        Exemplos:
          squeeze gravacao.mov
          squeeze *.mov --preset web720 -o ~/Desktop/WhatsApp
          squeeze viagem.mov --target-size 25
          squeeze clipe.mov --preset original      # só troca o container
        """,
        version: "0.1.0"
    )

    @Argument(help: "Vídeos a comprimir.", completion: .file(extensions: ["mov", "mp4", "m4v"]))
    var files: [String]

    @Option(name: .shortAndLong, help: "Preset de compressão.")
    var preset: PresetChoice = .balanced

    @Option(name: .customLong("target-size"), help: "Tamanho final desejado, em MB. Substitui o preset.")
    var targetSize: Double?

    @Option(help: "Codec de vídeo (o padrão vem do preset).")
    var codec: CodecChoice?

    @Option(name: .customLong("max-size"), help: "Maior lado do vídeo em pixels, mantendo a proporção.")
    var maxLongEdge: Int?

    @Option(help: "Taxa de quadros máxima.")
    var fps: FrameRateChoice?

    @Option(name: .customLong("bitrate"), help: "Bitrate de vídeo em kbps (substitui o automático).")
    var videoBitrate: Int?

    @Option(name: .customLong("audio-bitrate"), help: "Bitrate do áudio AAC em kbps.")
    var audioBitrate: Int?

    @Flag(name: .customLong("no-audio"), help: "Remove a faixa de áudio.")
    var removeAudio = false

    @Option(name: [.short, .customLong("output")], help: "Pasta de saída (padrão: ao lado do original).")
    var outputDirectory: String?

    @Flag(name: .customLong("dry-run"), help: "Só mostra a prévia e a estimativa, sem converter.")
    var dryRun = false

    func validate() throws {
        if let targetSize, targetSize <= 0 {
            throw ValidationError("--target-size precisa ser maior que zero.")
        }
        if removeAudio, audioBitrate != nil {
            throw ValidationError("--no-audio e --audio-bitrate não podem ser usados juntos.")
        }
        if let maxLongEdge, maxLongEdge < 16 {
            throw ValidationError("--max-size precisa ser pelo menos 16.")
        }
        if let videoBitrate, videoBitrate <= 0 {
            throw ValidationError("--bitrate precisa ser maior que zero.")
        }
        if preset == .original, targetSize != nil || codec != nil || videoBitrate != nil {
            throw ValidationError("--preset original não reencoda: não combina com codec, bitrate ou tamanho alvo.")
        }
    }

    var resolvedPreset: Preset {
        targetSize.map { .targetSize(megabytes: $0) } ?? preset.preset
    }

    var overrides: EncodingOverrides {
        let audio: AudioPolicy? = removeAudio ? .remove : audioBitrate.map { .aac(bitrate: $0 * 1_000) }
        return EncodingOverrides(
            codec: codec?.codec,
            maxLongEdge: maxLongEdge,
            frameRate: fps?.policy,
            videoBitrate: videoBitrate.map { $0 * 1_000 },
            audio: audio
        )
    }

    var outputLocation: OutputLocation {
        guard let outputDirectory else { return .besideOriginal }
        let path = NSString(string: outputDirectory).expandingTildeInPath
        return .folder(URL(fileURLWithPath: path, isDirectory: true))
    }

    func requests() -> [ConversionRequest] {
        files.map { path in
            ConversionRequest(
                source: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath),
                preset: resolvedPreset,
                overrides: overrides,
                output: outputLocation
            )
        }
    }

    func run() async throws {
        // Line-buffer stdout so progress shows up when piped into a file or another tool.
        setvbuf(stdout, nil, _IOLBF, 0)
        let runner = BatchRunner(reporter: Reporter(), dryRun: dryRun)
        let summary = await runner.run(requests())
        if summary.cancelled {
            throw ExitCode(130)
        }
        if summary.failed > 0 {
            throw ExitCode.failure
        }
    }
}
