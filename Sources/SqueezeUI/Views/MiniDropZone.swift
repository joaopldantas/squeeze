import SwiftUI

/// A compact version of the window's drop zone, for the menu bar panel and the drop shelf.
public struct MiniDropZone: View {
    let caption: String
    let onDrop: ([URL]) -> Void
    @State private var isTargeted = false

    public init(caption: String, onDrop: @escaping ([URL]) -> Void) {
        self.caption = caption
        self.onDrop = onDrop
    }

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "film.stack")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: isTargeted)
            Text("Solte para comprimir")
                .font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : .clear)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard CompressionViewModel.accepts(urls) else { return false }
            onDrop(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Área para soltar vídeos e comprimir")
    }
}
