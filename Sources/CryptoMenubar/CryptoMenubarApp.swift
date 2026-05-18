import SwiftUI
import AppKit

@main
struct CryptoMenubarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No SwiftUI scene needed — AppDelegate wires up the status item and window.
        // Settings scene is a placeholder so SwiftUI is happy; it never displays.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let store = TokenStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only — no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(store: store)
        // Ask for notification permission so price alerts can fire later.
        // macOS only prompts once; subsequent launches are silent.
        Task { _ = await store.alertManager.requestPermissionIfNeeded() }
    }
}
