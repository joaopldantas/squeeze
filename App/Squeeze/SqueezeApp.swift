import AppKit
import SqueezeUI
import SwiftUI

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
}
