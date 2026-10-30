import AppKit
import SqueezeCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window: drop zone or file list, settings inspector, totals at the bottom.
public struct RootView: View {
    @Bindable var viewModel: CompressionViewModel
    @State private var showsSettings = true
    @State private var isDropTargeted = false

    public init(viewModel: CompressionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        content
            .frame(minWidth: 560, minHeight: 420)
            .dropDestination(for: URL.self) { urls, _ in
                viewModel.add(urls)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay { if isDropTargeted && !viewModel.items.isEmpty { DropHighlight() } }
            .safeAreaInset(edge: .top, spacing: 0) { noticeBanner }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !viewModel.items.isEmpty { SummaryBar(viewModel: viewModel) }
            }
            .inspector(isPresented: $showsSettings) {
                SettingsPanel(settings: $viewModel.settings)
                    .inspectorColumnWidth(min: 280, ideal: 300, max: 360)
            }
            .toolbar { toolbar }
            .navigationTitle("Squeeze")
    }

    @ViewBuilder private var content: some View {
        if viewModel.items.isEmpty {
            DropZone(isTargeted: isDropTargeted, choose: chooseFiles)
        } else {
            List {
                ForEach(viewModel.items) { item in
                    ItemRow(item: item, viewModel: viewModel)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice = viewModel.notice {
            HStack {
                Image(systemName: "info.circle")
                Text(notice)
                Spacer()
                Button("Fechar", systemImage: "xmark", action: viewModel.dismissNotice)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.15))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Adicionar vídeos", systemImage: "plus", action: chooseFiles)
                .keyboardShortcut("o")
                .help("Adicionar vídeos (⌘O)")

            if viewModel.isConverting {
                Button("Cancelar tudo", systemImage: "stop.fill", action: viewModel.cancelAll)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Cancelar a conversão (⌘.)")
            } else {
                Button("Converter", systemImage: "play.fill", action: viewModel.convertAll)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!viewModel.canConvert)
                    .help("Converter todos (⌘↩)")
            }

            Button("Ajustes", systemImage: "sidebar.right") { showsSettings.toggle() }
                .help("Mostrar ou ocultar os ajustes")
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Escolha vídeos ou pastas com vídeos"
        panel.prompt = "Adicionar"
        if panel.runModal() == .OK {
            viewModel.add(panel.urls)
        }
    }
}

/// Shown while the list is empty.
struct DropZone: View {
    let isTargeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: isTargeted)
            VStack(spacing: 6) {
                Text("Solte vídeos aqui")
                    .font(.title2.weight(.semibold))
                Text("Gravações de tela e vídeos do iPhone (.mov) viram .mp4 bem menores.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Escolher arquivos…", action: choose)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
                )
                .padding(20)
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.06))
            .padding(6)
            .allowsHitTesting(false)
    }
}
