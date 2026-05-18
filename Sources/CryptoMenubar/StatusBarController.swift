import AppKit
import Combine
import SwiftUI

// Replaces SwiftUI's MenuBarExtra so we can:
//   - Open a real NSWindow on click (instead of a popover with a fixed cap)
//   - Let the user drag any edge / corner to resize the window
//   - Persist window size between launches
//
// The status-bar button still shows "BTC $XX,XXX" — its title is kept in sync
// with the store via a Combine subscription.

@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    let store: TokenStore
    private let statusItem: NSStatusItem
    private var window: NSWindow?
    private weak var contentController: NSViewController?
    private var cancellables = Set<AnyCancellable>()

    private static let frameAutosaveName = "CryptoMenubarMainWindow"

    init(store: TokenStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupStatusItem()
        observeStore()
        // Close the popover-like window whenever the user switches to another app.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "bitcoinsign.circle.fill",
                               accessibilityDescription: "Crypto Menubar")
        button.imagePosition = .imageLeft
        button.title = " —"
        button.action = #selector(toggleWindow)
        button.target = self
    }

    private func observeStore() {
        // Refresh the menubar title whenever tokens or quotes change.
        store.$tokens
            .combineLatest(store.$quotes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.refreshTitle()
            }
            .store(in: &cancellables)
        refreshTitle()

        // When a chart is expanded/collapsed (or a token added/removed), refit
        // the window height to the new natural content size. Width stays put.
        store.$expandedTokenIds
            .combineLatest(store.$tokens)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                // Wait a runloop tick so SwiftUI has rebuilt the layout, then read fittingSize.
                DispatchQueue.main.async { self?.fitWindowHeightToContent() }
            }
            .store(in: &cancellables)
    }

    private func fitWindowHeightToContent() {
        guard let window = window,
              window.isVisible,
              let view = contentController?.view else { return }
        // SwiftUI's intrinsic content height for the current state.
        let fitting = view.fittingSize
        guard fitting.height > 0 else { return }

        // Cap growth at "from current top edge of window down to bottom of
        // visible screen area (above Dock)". Past that, the ScrollView handles
        // overflow.
        let currentTop = window.frame.origin.y + window.frame.height
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let bottomLimit = (screen?.visibleFrame.minY ?? 0) + 8
        let maxAvailable = max(240, currentTop - bottomLimit)

        let targetH = min(fitting.height, maxAvailable)
        var frame = window.frame
        let delta = targetH - frame.height
        guard abs(delta) > 1 else { return }  // already the right height
        frame.size.height = targetH
        // Keep the TOP edge anchored — NSWindow origin is the bottom-left corner.
        frame.origin.y = currentTop - targetH
        window.setFrame(frame, display: true, animate: false)
    }

    private func refreshTitle() {
        statusItem.button?.title = " \(store.primaryDisplay)"
    }

    @objc private func toggleWindow() {
        if let w = window, w.isVisible {
            w.close()
        } else {
            showWindow()
        }
    }

    private func showWindow() {
        let win = window ?? makeWindow()
        window = win
        positionUnderStatusItem(win)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        // Initial size if no autosaved frame exists yet (first launch).
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Borderless / popover-like look: transparent titlebar, no title text,
        // content extends behind the titlebar area. Close button stays visible
        // at top-left; ContentView reserves space for it via top padding.
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 320, height: 240)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.level = .floating
        let hosting = NSHostingController(rootView: ContentView().environmentObject(store))
        win.contentViewController = hosting
        self.contentController = hosting
        win.delegate = self
        // AppKit's built-in frame persistence: saves frame to UserDefaults under
        // "NSWindow Frame CryptoMenubarMainWindow" automatically on every change.
        // Restores it here. Our positionUnderStatusItem() overrides the X/Y so
        // the window always re-anchors under the menubar icon — only the SIZE
        // persists between launches.
        win.setFrameAutosaveName(Self.frameAutosaveName)
        return win
    }

    private func positionUnderStatusItem(_ win: NSWindow) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        // Center the window horizontally under the status-bar icon.
        var x = buttonFrame.midX - win.frame.width / 2
        let y = buttonFrame.minY - win.frame.height - 4
        // Keep the whole window on-screen horizontally.
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            x = max(vis.minX + 8, min(x, vis.maxX - win.frame.width - 8))
        }
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - NSWindowDelegate

    @objc private func appDidResignActive() {
        Task { @MainActor [weak self] in
            // Only close if we're actually showing the window and there's no
            // attached sheet (Settings / alert config); killing the sheet would
            // wipe the user's input mid-edit.
            guard let window = self?.window,
                  window.isVisible,
                  window.attachedSheet == nil else { return }
            window.close()
        }
    }
}
