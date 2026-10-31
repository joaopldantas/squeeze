import AppKit
import SqueezeUI
import SwiftUI
import UserNotifications

@main
struct SqueezeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single window: files opened from Finder join its list instead of spawning new windows.
        Window("Squeeze", id: "main") {
            RootView(viewModel: appDelegate.viewModel)
                .background(OpenWindowBridge(
                    register: { appDelegate.openMainWindow = $0 },
                    closesNow: { appDelegate.takeLaunchesHidden() }
                ))
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Hands SwiftUI's `openWindow` action to AppKit code (the menu bar panel, Dock reopen).
///
/// The action only exists once the window has appeared, so in menu bar-only mode the window still opens
/// at launch, hands the action over and closes right away.
private struct OpenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let register: (@escaping @MainActor () -> Void) -> Void
    let closesNow: () -> Bool

    var body: some View {
        Color.clear.onAppear {
            register { openWindow(id: "main") }
            if closesNow() {
                dismissWindow(id: "main")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = CompressionViewModel()
    let preferences = AppPreferences()
    var openMainWindow: @MainActor () -> Void = {}
    /// In menu bar-only mode Squeeze starts with no window, unless it was launched to open files.
    private lazy var launchesHidden = !preferences.showsInDock
    private var statusItem: StatusItemController?
    private var dropShelf: DropShelfController?
    private var recordingsWatcher: FolderWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.applyActivationPolicy()
        statusItem = StatusItemController(viewModel: viewModel, preferences: preferences) { [weak self] in
            self?.showMainWindow()
        }
        dropShelf = DropShelfController(viewModel: viewModel) { [weak self] in self?.statusItem?.iconFrame }
        UNUserNotificationCenter.current().delegate = self
        viewModel.onBatchStarted = { [weak self] in self?.requestNotificationPermission() }
        viewModel.onBatchFinished = { [weak self] report in self?.notify(report) }
        // "Comprimir com Squeeze" in Finder's Services menu (see NSServices in project.yml).
        NSApp.servicesProvider = self
        preferences.onScreenRecordingsChange = { [weak self] in self?.updateRecordingsWatcher() }
        updateRecordingsWatcher()
    }

    /// Converts each screen recording right after macOS saves it, in the folder set in the Screenshot app.
    private func updateRecordingsWatcher() {
        guard preferences.compressesScreenRecordings else {
            recordingsWatcher = nil
            return
        }
        let folder = ScreenRecordings.folder
        recordingsWatcher = FolderWatcher(folder: folder, accept: ScreenRecordings.isRecording) { [weak self] urls in
            self?.viewModel.addAndConvert(urls)
        }
        if recordingsWatcher == nil {
            preferences.compressesScreenRecordings = false
            showFolderAccessAlert(for: folder)
        }
    }

    private func showFolderAccessAlert(for folder: URL) {
        let alert = NSAlert()
        alert.messageText = "Não foi possível acompanhar “\(folder.lastPathComponent)”"
        alert.informativeText = "Permita o acesso do Squeeze a essa pasta em Ajustes do Sistema › Privacidade "
            + "e Segurança › Arquivos e Pastas, e ligue a opção de novo."
        NSApp.activate()
        alert.runModal()
    }

    /// Finder "Open With", files dropped on the Dock icon and `open -a Squeeze file.mov` all land here.
    func application(_ application: NSApplication, open urls: [URL]) {
        viewModel.add(urls)
        // Opened files wait in the window for the user to convert them, so it has to be visible.
        launchesHidden = false
        if !preferences.showsInDock {
            showMainWindow()
        }
    }

    /// Whether the window that just appeared should close: true once, at a menu bar-only launch.
    func takeLaunchesHidden() -> Bool {
        defer { launchesHidden = false }
        return launchesHidden
    }

    /// The menu bar icon keeps working with the window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    /// `openWindow` focuses the window if it exists and recreates it if it was closed.
    private func showMainWindow() {
        NSApp.activate()
        openMainWindow()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard viewModel.isConverting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Há conversões em andamento"
        alert.informativeText = "Se sair agora, elas serão canceladas. Nenhum arquivo incompleto fica no disco."
        alert.addButton(withTitle: "Continuar convertendo")
        alert.addButton(withTitle: "Cancelar e sair")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        viewModel.cancelAll()
        return .terminateNow
    }

    // MARK: Finder service

    /// Receives the videos selected in Finder and converts them right away with the current settings.
    @objc func compressFiles(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "Nenhum vídeo selecionado."
            return
        }
        viewModel.addAndConvert(urls)
        NSApp.activate()
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    private func notify(_ report: BatchReport) {
        guard let text = BatchNotification(report) else { return }
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show the banner even while Squeeze is in front: the batch may have run while the user looked elsewhere.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { NSApp.activate() }
    }
}
