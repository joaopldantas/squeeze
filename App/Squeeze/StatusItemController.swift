import AppKit
import Observation
import ServiceManagement
import SqueezeUI
import SwiftUI

/// The menu bar icon: shows progress while compressing; click it for the panel.
///
/// Status items can't receive drops on current macOS, so videos are dropped on the panel's drop zone
/// or on the shelf that `DropShelfController` slides out under this icon during a drag.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let viewModel: CompressionViewModel
    private let preferences: AppPreferences

    init(viewModel: CompressionViewModel, preferences: AppPreferences, openWindow: @escaping () -> Void) {
        self.viewModel = viewModel
        self.preferences = preferences
        super.init()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarPanel(
            viewModel: viewModel,
            options: MenuBarOptions(
                showsInDock: Binding(get: { preferences.showsInDock }, set: { preferences.showsInDock = $0 }),
                opensAtLogin: Binding(get: { preferences.opensAtLogin }, set: { preferences.setOpensAtLogin($0) }),
                compressesScreenRecordings: Binding(
                    get: { preferences.compressesScreenRecordings },
                    set: { preferences.compressesScreenRecordings = $0 }
                )
            ),
            openWindow: { [weak self] in
                self?.popover.performClose(nil)
                openWindow()
            }
        ))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Squeeze")
            button.toolTip = "Squeeze: arraste vídeos até aqui para comprimir"
        }
        updateIcon()
        observeProgress()
    }

    /// The icon's frame on screen, so the drop shelf can open right under it.
    var iconFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            preferences.refreshLoginItem()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: Icon

    private func updateIcon() {
        statusItem.button?.image = StatusIcon.image(progress: viewModel.activeProgress)
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
}

/// Template images for the status item, so they follow the menu bar's light/dark appearance.
enum StatusIcon {
    private static let size = NSSize(width: 18, height: 18)

    static func image(progress: Double?) -> NSImage? {
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
    private static let compressesScreenRecordingsKey = "compressesScreenRecordings"

    /// Hiding the Dock icon turns Squeeze into a menu bar utility; the window stays one click away.
    var showsInDock: Bool {
        didSet {
            UserDefaults.standard.set(showsInDock, forKey: Self.showsInDockKey)
            applyActivationPolicy()
        }
    }

    /// Compress every new screen recording as soon as macOS saves it. The app delegate runs the watcher.
    var compressesScreenRecordings: Bool {
        didSet {
            UserDefaults.standard.set(compressesScreenRecordings, forKey: Self.compressesScreenRecordingsKey)
            onScreenRecordingsChange?()
        }
    }
    var onScreenRecordingsChange: (@MainActor () -> Void)?

    /// Mirrors the system's login item list, which the user can also edit in System Settings.
    private(set) var opensAtLogin = false

    init() {
        let defaults = UserDefaults.standard
        showsInDock = defaults.object(forKey: Self.showsInDockKey) as? Bool ?? true
        compressesScreenRecordings = defaults.bool(forKey: Self.compressesScreenRecordingsKey)
        refreshLoginItem()
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showsInDock ? .regular : .accessory)
        if showsInDock {
            NSApp.activate()
        }
    }

    func setOpensAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSSound.beep()
        }
        // The system may ask the user to allow it first; send them straight to the right page.
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refreshLoginItem()
    }

    func refreshLoginItem() {
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
