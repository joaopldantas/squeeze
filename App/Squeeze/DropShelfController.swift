import AppKit
import SqueezeUI
import SwiftUI

/// A small drop zone that slides out under the menu bar icon while videos are dragged towards it.
///
/// Status items can't receive drops on current macOS (the menu bar is drawn by another process),
/// so this floating panel takes the drop instead. It watches mouse drags system-wide (global mouse
/// monitors need no special permission) and the shared drag pasteboard to know what is being dragged.
@MainActor
final class DropShelfController {
    private static let size = NSSize(width: 280, height: 150)

    private let panel: NSPanel
    private let trigger = DropShelfTrigger()
    private let anchor: () -> NSRect?
    private var monitors: [Any] = []
    /// The drag pasteboard keeps the last drag's contents, so only a change since the mouse went down
    /// means *this* drag carries files.
    private var changeCountAtMouseDown = 0
    private var inspectedChangeCount = -1
    private var draggingVideos = false
    private var releaseTimer: Timer?

    /// - Parameter anchor: the menu bar icon's frame on screen, to place the shelf under it.
    init(viewModel: CompressionViewModel, anchor: @escaping () -> NSRect?) {
        self.anchor = anchor
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: DropShelf(viewModel: viewModel) { [weak self] in
            self?.hide(after: 0.8)
        })

        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseDown() }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseDragged() }
            }
        ].compactMap { $0 }
    }

    // MARK: Drag tracking

    private func mouseDown() {
        changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        draggingVideos = false
    }

    private func mouseDragged() {
        let pasteboard = NSPasteboard(name: .drag)
        if pasteboard.changeCount != inspectedChangeCount {
            inspectedChangeCount = pasteboard.changeCount
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
            draggingVideos = pasteboard.changeCount != changeCountAtMouseDown && CompressionViewModel.accepts(urls)
        }
        guard !panel.isVisible else { return }

        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) else { return }
        if trigger.shouldOpen(cursorY: cursor.y, screenTop: screen.frame.maxY, draggingVideos: draggingVideos) {
            show(on: screen)
        }
    }

    // MARK: Showing and hiding

    private func show(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let midX = anchor()?.midX ?? visible.maxX - Self.size.width / 2 - 12
        let originX = min(max(midX - Self.size.width / 2, visible.minX + 8), visible.maxX - Self.size.width - 8)
        let origin = NSPoint(x: originX, y: visible.maxY - Self.size.height - 6)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        watchForRelease()
    }

    /// A drag that ends anywhere else (or is cancelled) never reaches the shelf, so poll the mouse button
    /// instead of relying on a mouse-up event the dragging source may swallow.
    private func watchForRelease() {
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.releaseTimer?.invalidate()
                self.hide(after: 0.3)
            }
        }
    }

    private func hide(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { self.panel.orderOut(nil) }
            }
        }
    }
}

/// The shelf's content: the mini drop zone on a translucent card.
private struct DropShelf: View {
    let viewModel: CompressionViewModel
    let dropped: () -> Void

    var body: some View {
        MiniDropZone(caption: "Com o preset \(viewModel.settings.presetKind.title)") { urls in
            viewModel.addAndConvert(urls)
            dropped()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
