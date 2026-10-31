import AppKit
import SqueezeCore
import SwiftUI

/// App-level switches shown in the panel. They live in the app target, which owns the system integrations
/// (Dock, login items, the recordings folder).
public struct MenuBarOptions {
    public var showsInDock: Binding<Bool>
    public var opensAtLogin: Binding<Bool>
    public var compressesScreenRecordings: Binding<Bool>

    public init(showsInDock: Binding<Bool>, opensAtLogin: Binding<Bool>, compressesScreenRecordings: Binding<Bool>) {
        self.showsInDock = showsInDock
        self.opensAtLogin = opensAtLogin
        self.compressesScreenRecordings = compressesScreenRecordings
    }
}

/// The popover under the menu bar icon: status, quick preset choice and the latest files.
public struct MenuBarPanel: View {
    @Bindable var viewModel: CompressionViewModel
    let options: MenuBarOptions
    let openWindow: () -> Void
    private let format = Formatting()

    public init(viewModel: CompressionViewModel, options: MenuBarOptions, openWindow: @escaping () -> Void) {
        self.viewModel = viewModel
        self.options = options
        self.openWindow = openWindow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("Preset", selection: $viewModel.settings.presetKind) {
                ForEach(CompressionSettings.PresetKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .help(viewModel.settings.presetKind.summary)

            MiniDropZone(caption: "Com o preset \(viewModel.settings.presetKind.title)") { urls in
                viewModel.addAndConvert(urls)
            }
            .frame(height: 96)

            if options.compressesScreenRecordings.wrappedValue {
                Label("Gravações de tela novas são comprimidas sozinhas", systemImage: "record.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let recent = viewModel.recentItems()
            if !recent.isEmpty {
                VStack(spacing: 8) {
                    ForEach(recent) { item in
                        CompactItemRow(item: item, format: format)
                    }
                }
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Squeeze").font(.headline)
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let progress = viewModel.activeProgress {
                ProgressView(value: progress)
            }
        }
    }

    private var status: String {
        let active = viewModel.items.filter { $0.isBusy || $0.phase == .analyzing }.count
        if let progress = viewModel.activeProgress, active > 0 {
            let percent = progress.formatted(.percent.precision(.fractionLength(0)))
            return active == 1 ? "Comprimindo 1 vídeo · \(percent)" : "Comprimindo \(active) vídeos · \(percent)"
        }
        let summary = viewModel.summary
        guard summary.completedCount > 0 else { return "Pronto" }
        return "\(format.bytes(summary.completed.savedBytes)) economizados"
    }

    private var footer: some View {
        HStack {
            Button("Abrir janela", action: openWindow)
            Spacer()
            optionsMenu
            Button("Sair", systemImage: "power") { NSApp.terminate(nil) }
                .labelStyle(.iconOnly)
                .help("Sair do Squeeze")
        }
        .controlSize(.small)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Comprimir gravações de tela automaticamente", isOn: options.compressesScreenRecordings)
            Toggle("Mover originais para o Lixo", isOn: $viewModel.settings.movesOriginalsToTrash)
            Divider()
            Toggle("Mostrar ícone no Dock", isOn: options.showsInDock)
            Toggle("Abrir ao iniciar sessão", isOn: options.opensAtLogin)
        } label: {
            Label("Opções", systemImage: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Opções")
    }
}

/// One line per file: thumbnail, name and the most useful fact for its current state.
struct CompactItemRow: View {
    let item: QueueItem
    let format: Formatting

    var body: some View {
        HStack(spacing: 8) {
            ThumbnailView(thumbnail: item.thumbnail, isLoading: item.phase == .analyzing, width: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            Spacer(minLength: 4)
            if let result = item.result {
                Button("Mostrar no Finder", systemImage: "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Mostrar no Finder")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch item.phase {
        case .analyzing:
            caption("Analisando…")
        case .queued:
            caption("Na fila")
        case .converting(let progress):
            ProgressView(value: progress).controlSize(.mini)
        case .completed(let result):
            caption("\(format.bytes(result.comparison.outputBytes)) (\(format.change(result.comparison)))")
                .foregroundStyle(result.comparison.outputIsLarger ? .orange : .green)
        case .failed(let error):
            caption(error.localizedDescription).foregroundStyle(.red)
        case .cancelled:
            caption("Cancelada")
        case .ready:
            if let error = item.planError {
                caption(error.localizedDescription).foregroundStyle(.orange)
            } else if let preview = item.preview {
                caption("~\(format.bytes(preview.estimate.outputBytes)) (\(format.change(preview.estimate)))")
            }
        }
    }

    private func caption(_ text: String) -> Text {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
