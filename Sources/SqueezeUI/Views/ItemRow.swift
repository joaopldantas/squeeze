import AppKit
import SqueezeCore
import SwiftUI

struct ItemRow: View {
    let item: QueueItem
    let viewModel: CompressionViewModel
    private let format = Formatting()

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(thumbnail: item.thumbnail, isLoading: item.phase == .analyzing)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let info = item.info {
                    Text(details(info))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                status
                warnings
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 6)
        .contextMenu { contextMenu }
    }

    // MARK: Status line

    @ViewBuilder private var status: some View {
        switch item.phase {
        case .analyzing:
            Text("Analisando…").font(.callout).foregroundStyle(.secondary)
        case .ready, .queued, .cancelled:
            HStack(spacing: 8) {
                estimate
                if item.phase == .queued { Tag("Na fila", color: .secondary) }
                if item.phase == .cancelled { Tag("Cancelada", color: .secondary) }
            }
        case .converting(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Convertendo")
        case .completed(let result):
            HStack(spacing: 8) {
                Text(sizes(result.comparison)).font(.callout)
                Tag(format.change(result.comparison), color: result.comparison.outputIsLarger ? .orange : .green)
                Text("em \(format.elapsed(result.elapsed))").font(.caption).foregroundStyle(.secondary)
                if item.originalTrashed {
                    Label("Original no Lixo", systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let error):
            Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .help(error.failureReason ?? error.localizedDescription)
        }
    }

    @ViewBuilder private var estimate: some View {
        if let planError = item.planError {
            Label(planError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if let preview = item.preview {
            Text("\(format.bytes(preview.estimate.originalBytes)) → ~\(format.bytes(preview.estimate.outputBytes))")
                .font(.callout)
            Tag(format.change(preview.estimate), color: .accentColor)
                .help("Estimativa: \(format.plan(preview.plan, source: preview.info))")
        }
    }

    // MARK: Warnings

    @ViewBuilder private var warnings: some View {
        let messages = (item.result?.warnings ?? item.preview?.plan.warnings ?? []).map(\.message)
        ForEach(messages, id: \.self) { message in
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
        if let result = item.result, result.outputGrewUnexpectedly {
            HStack(spacing: 8) {
                Label("Ficou maior que o original.", systemImage: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if let suggestion = result.suggestedPreset {
                    Button("Tentar \(suggestion.displayName)") { viewModel.retry(item, with: suggestion) }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            if item.isBusy {
                IconButton("Cancelar", systemImage: "xmark.circle.fill") { viewModel.cancel(item) }
            } else if let result = item.result {
                IconButton("Mostrar no Finder", systemImage: "magnifyingglass.circle.fill") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }
            } else if item.canConvert {
                IconButton("Converter este", systemImage: "play.circle.fill") { viewModel.convert(item) }
            }
            if !item.isBusy {
                IconButton("Remover da lista", systemImage: "minus.circle") { viewModel.remove(item) }
            }
        }
        .font(.title3)
    }

    @ViewBuilder private var contextMenu: some View {
        if let result = item.result {
            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.outputURL]) }
        }
        if !item.originalTrashed {
            Button("Mostrar original no Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        if item.canConvert {
            Button("Converter") { viewModel.convert(item) }
        }
        Divider()
        if item.isBusy {
            Button("Cancelar") { viewModel.cancel(item) }
        } else {
            Button("Remover da lista", role: .destructive) { viewModel.remove(item) }
        }
    }

    // MARK: Text

    private func details(_ info: MediaInfo) -> String {
        [
            info.video.displaySize.description,
            format.duration(info.duration),
            format.frameRate(info.video.frameRate),
            format.codec(info.video.codec),
            info.video.dynamicRange.isHDR ? "HDR" : nil
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func sizes(_ comparison: SizeComparison) -> String {
        "\(format.bytes(comparison.originalBytes)) → \(format.bytes(comparison.outputBytes))"
    }
}

struct ThumbnailView: View {
    let thumbnail: Thumbnail?
    let isLoading: Bool
    /// 16:9 box; the height follows the width.
    var width: CGFloat = 112

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: width / 18).fill(.quaternary)
            if let thumbnail {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: width / 18))
        .accessibilityHidden(true)
    }
}

struct Tag: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct IconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(title)
    }
}
