import AppKit
import SqueezeCore
import SwiftUI

/// The inspector: preset, advanced options and output folder. Every change re-plans the list live.
struct SettingsPanel: View {
    @Binding var settings: CompressionSettings
    @State private var showsAdvanced = false

    var body: some View {
        Form {
            Section("Preset") {
                Picker("Preset", selection: $settings.presetKind) {
                    ForEach(CompressionSettings.PresetKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                Text(settings.presetKind.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.presetKind == .targetSize {
                    LabeledContent("Tamanho final") {
                        HStack(spacing: 4) {
                            TextField(
                                "MB", value: $settings.targetMegabytes,
                                format: .number.precision(.fractionLength(0...1))
                            )
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                            Stepper("MB", value: $settings.targetMegabytes, in: 1...10_000, step: 5)
                                .labelsHidden()
                            Text("MB")
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("Avançado", isExpanded: $showsAdvanced) {
                    AdvancedOptions(settings: $settings)
                }
            }

            Section("Saída") {
                OutputOptions(settings: $settings)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedOptions: View {
    @Binding var settings: CompressionSettings

    private static let resolutions: [(String, Int?)] = [
        ("Original", nil), ("4K (2160p)", 3840), ("1440p", 2560), ("1080p", 1920), ("720p", 1280), ("480p", 854)
    ]
    private static let audioBitrates = [96, 128, 192, 256]

    var body: some View {
        Group {
            Picker("Codec", selection: $settings.codec) {
                Text("Do preset").tag(VideoCodec?.none)
                Text("HEVC (menor)").tag(VideoCodec?.some(.hevc))
                Text("H.264 (compatível)").tag(VideoCodec?.some(.h264))
            }
            Picker("Resolução máxima", selection: $settings.maxLongEdge) {
                ForEach(Self.resolutions, id: \.1) { title, edge in
                    Text(title).tag(edge)
                }
            }
            Picker("Quadros por segundo", selection: $settings.frameRate) {
                Text("Do preset").tag(FrameRatePolicy?.none)
                Text("Manter original").tag(FrameRatePolicy?.some(.keep))
                Text("Até 60").tag(FrameRatePolicy?.some(.limit(60)))
                Text("Até 30").tag(FrameRatePolicy?.some(.limit(30)))
            }
            Toggle("Bitrate de vídeo manual", isOn: manualBitrate)
            if let bitrate = settings.videoBitrateKbps {
                LabeledContent("Bitrate") {
                    HStack(spacing: 4) {
                        TextField("kbps", value: Binding(
                            get: { bitrate },
                            set: { settings.videoBitrateKbps = max(100, $0) }
                        ), format: .number)
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)
                        Text("kbps")
                    }
                }
            }
        }
        .disabled(!settings.allowsVideoOptions)

        Picker("Áudio", selection: $settings.audio) {
            Text("Do preset").tag(AudioPolicy?.none)
            ForEach(Self.audioBitrates, id: \.self) { kbps in
                Text("AAC \(kbps) kbps").tag(AudioPolicy?.some(.aac(bitrate: kbps * 1_000)))
            }
            Text("Remover áudio").tag(AudioPolicy?.some(.remove))
        }

        if settings.hasAdvancedOverrides {
            Button("Restaurar padrões do preset") {
                settings.codec = nil
                settings.maxLongEdge = nil
                settings.frameRate = nil
                settings.videoBitrateKbps = nil
                settings.audio = nil
            }
        }
    }

    private var manualBitrate: Binding<Bool> {
        Binding(
            get: { settings.videoBitrateKbps != nil },
            set: { settings.videoBitrateKbps = $0 ? 4_000 : nil }
        )
    }
}

private struct OutputOptions: View {
    @Binding var settings: CompressionSettings

    var body: some View {
        Picker("Salvar em", selection: usesFixedFolder) {
            Text("Ao lado do original").tag(false)
            Text("Pasta fixa").tag(true)
        }
        .pickerStyle(.radioGroup)

        if let folder = settings.outputFolder {
            LabeledContent("Pasta") {
                HStack {
                    Text(folder.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.path)
                    Button("Alterar…", action: chooseFolder)
                }
            }
        }
        Text("Nome: video_compressed.mp4. Arquivos existentes nunca são sobrescritos.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var usesFixedFolder: Binding<Bool> {
        Binding(
            get: { settings.outputFolder != nil },
            set: { fixed in
                if fixed {
                    chooseFolder()
                } else {
                    settings.outputFolder = nil
                }
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Usar esta pasta"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputFolder = url
        }
    }
}

/// Totals and the main action, pinned to the bottom of the window.
struct SummaryBar: View {
    let viewModel: CompressionViewModel
    private let format = Formatting()

    var body: some View {
        let summary = viewModel.summary
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if summary.pendingCount > 0 {
                    Text("\(summary.pendingCount) para converter: \(sizes(summary.pending)) estimados")
                }
                if summary.completedCount > 0 {
                    Text("\(summary.completedCount) concluído(s): \(sizes(summary.completed))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Spacer()
            if summary.completedCount > 0 && !viewModel.isConverting {
                Button("Limpar concluídos", action: viewModel.clearCompleted)
            }
            if viewModel.isConverting {
                Button("Cancelar tudo", action: viewModel.cancelAll)
            } else {
                Button("Converter", action: viewModel.convertAll)
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canConvert)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func sizes(_ comparison: SizeComparison) -> String {
        let before = format.bytes(comparison.originalBytes)
        let after = format.bytes(comparison.outputBytes)
        return "\(before) → \(after) (\(format.change(comparison)))"
    }
}
