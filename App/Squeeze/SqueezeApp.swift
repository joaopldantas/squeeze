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
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = CompressionViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        viewModel.onBatchStarted = { [weak self] in self?.requestNotificationPermission() }
        viewModel.onBatchFinished = { [weak self] report in self?.notify(report) }
        // "Comprimir com Squeeze" in Finder's Services menu (see NSServices in project.yml).
        NSApp.servicesProvider = self
    }

    /// Finder "Open With", files dropped on the Dock icon and `open -a Squeeze file.mov` all land here.
    func application(_ application: NSApplication, open urls: [URL]) {
        viewModel.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
