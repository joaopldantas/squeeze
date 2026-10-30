import AppKit
import Observation
import SqueezeUI
import SwiftUI

/// The menu bar icon: drop videos on it to compress them with the current preset; click it for the panel.
///
/// `MenuBarExtra` can't receive drops, so this is an `NSStatusItem`. The status bar window is registered
/// for file drags and forwards the dragging callbacks to its delegate (this controller).
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let viewModel: CompressionViewModel
    private var isDropTargeted = false {
        didSet { updateIcon() }
    }

    init(viewModel: CompressionViewModel, preferences: AppPreferences, openWindow: @escaping () -> Void) {
        self.viewModel = viewModel
        super.init()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarPanel(
            viewModel: viewModel,
            showsInDock: Binding(get: { preferences.showsInDock }, set: { preferences.showsInDock = $0 }),
            openWindow: { [weak self] in
                self?.popover.performClose(nil)
                openWindow()
            }
        ))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Squeeze")
            button.toolTip = "Squeeze: solte vídeos aqui para comprimir"
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }
        updateIcon()
        observeProgress()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: Icon

    private func updateIcon() {
        statusItem.button?.image = StatusIcon.image(progress: viewModel.activeProgress, isDropTargeted: isDropTargeted)
    }

    /// Re-renders the icon whenever the overall progress changes. `withObservationTracking` fires once,
    /// so the handler re-registers itself.
    private func observeProgress() {
        withObservationTracking {
            _ = viewModel.activeProgress
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.observeProgress()
            }
        }
    }

    // MARK: Dropping files

    private func fileURLs(in info: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard CompressionViewModel.accepts(fileURLs(in: sender)) else { return [] }
        isDropTargeted = true
        return .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDropTargeted = false
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTargeted = false
        let urls = fileURLs(in: sender)
        guard CompressionViewModel.accepts(urls) else { return false }
        viewModel.addAndConvert(urls)
        return true
    }
}

/// Template images for the status item, so they follow the menu bar's light/dark appearance.
enum StatusIcon {
    private static let size = NSSize(width: 18, height: 18)

    static func image(progress: Double?, isDropTargeted: Bool) -> NSImage? {
        if isDropTargeted {
            return symbol("arrow.down.circle.fill")
        }
        guard let progress else {
            return symbol("arrow.down.right.and.arrow.up.left")
        }
        return ring(progress: progress)
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Squeeze")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        image?.isTemplate = true
        return image
    }

    /// A ring that fills clockwise from the top, like the system's own download progress.
    private static func ring(progress: Double) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2 - 2
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.5
            NSColor.black.withAlphaComponent(0.25).setStroke()
            track.stroke()

            let fraction = min(max(progress, 0.03), 1)
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center, radius: radius,
                startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true
            )
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Comprimindo, \(Int(progress * 100))%"
        return image
    }
}

/// App-level preferences that aren't compression settings.
@MainActor
@Observable
final class AppPreferences {
    private static let showsInDockKey = "showsInDock"

    /// Hiding the Dock icon turns Squeeze into a menu bar utility; the window stays one click away.
    var showsInDock: Bool {
        didSet {
            UserDefaults.standard.set(showsInDock, forKey: Self.showsInDockKey)
            applyActivationPolicy()
        }
    }

    init() {
        showsInDock = UserDefaults.standard.object(forKey: Self.showsInDockKey) as? Bool ?? true
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showsInDock ? .regular : .accessory)
        if showsInDock {
            NSApp.activate()
        }
    }
}
