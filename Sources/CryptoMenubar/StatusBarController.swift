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
    private var portfolioWindow: NSWindow?
    private weak var contentController: NSViewController?
    private var cancellables = Set<AnyCancellable>()

    // Width-only persistence. (Height is always computed from current content —
    // see fitWindowHeightToContent — so we deliberately don't use AppKit's
    // setFrameAutosaveName, which would also save/restore height and race with
    // our fit logic.)
    private static let widthKey = "CryptoMenubarMainWindow.width.v1"

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openPortfolioRequested),
            name: .openPortfolioWindow,
            object: nil
        )
    }

    // MARK: - Portfolio window

    @objc private func openPortfolioRequested() {
        Task { @MainActor [weak self] in self?.showPortfolioWindow() }
    }

    private func showPortfolioWindow() {
        // The popover-style main window would float above the portfolio and
        // get in the way — dismiss it, like picking a menu item.
        window?.close()
        let win = portfolioWindow ?? makePortfolioWindow()
        portfolioWindow = win
        store.portfolio.windowOpened()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePortfolioWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Portfolio"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 520, height: 520)
        win.collectionBehavior = [.fullScreenAuxiliary]
        let hosting = NSHostingController(
            rootView: PortfolioView()
                .environmentObject(store)
                .environmentObject(store.portfolio)
        )
        win.contentViewController = hosting
        win.delegate = self
        // AppKit remembers size + position between launches; first launch centers.
        if !win.setFrameUsingName("CryptoMenubarPortfolioWindow") {
            win.center()
        }
        win.setFrameAutosaveName("CryptoMenubarPortfolioWindow")
        return win
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

        // When SwiftUI reports new measured heights (chrome + token list),
        // refit the window. We observe both — chrome changes on API key
        // entered, list changes on expand/collapse/add/remove.
        store.$measuredChromeHeight
            .combineLatest(store.$measuredListHeight)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.fitWindowHeightToContent()
            }
            .store(in: &cancellables)
    }

    private func fitWindowHeightToContent() {
        guard let window = window else { return }
        // Use measured heights when available (SwiftUI has rendered at least
        // once). Fall back to constant estimates pre-render (very first frame).
        let measuredChrome = store.measuredChromeHeight
        let measuredList = store.measuredListHeight
        let intended: CGFloat
        if measuredChrome > 0 && measuredList > 0 {
            intended = measuredChrome + measuredList
        } else {
            intended = computeIntendedHeight()
        }
        // Cap growth at "from current top edge of window down to bottom of
        // visible screen area (above Dock)". Past that, the ScrollView handles
        // overflow.
        let currentTop = window.frame.origin.y + window.frame.height
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let bottomLimit = (screen?.visibleFrame.minY ?? 0) + 8
        let maxAvailable = max(240, currentTop - bottomLimit)
        let targetH = min(intended, maxAvailable)

        let delta = targetH - window.frame.height
        guard abs(delta) > 1 else { return }   // already the right height
        var frame = window.frame
        frame.size.height = targetH
        // Keep the TOP edge anchored — NSWindow origin is the bottom-left corner.
        frame.origin.y = currentTop - targetH
        window.setFrame(frame, display: true, animate: false)
    }

    /// Adds up the heights of the popover's chrome + each token row + each
    /// expanded-chart section. Constants are estimated from the actual
    /// SwiftUI layout and slightly conservative; small drift just shows up as
    /// a couple of pixels of padding at the bottom, never as clipping.
    private func computeIntendedHeight() -> CGFloat {
        // Fixed chrome (always present). Empirically measured against the
        // rendered layout — a few pt of overestimate is fine (the worst case
        // is a thin sliver of extra padding); underestimate causes scrolling.
        let topReserve: CGFloat = 22       // traffic-light strip
        let headerBar: CGFloat = 56        // "Crypto Menubar" + refresh/settings/quit row
        let searchBar: CGFloat = 56        // search field + vertical padding (.padding(.vertical, 6))
        let dividers: CGFloat = 2
        let bottomPad: CGFloat = 4

        // Per-content
        let perRow: CGFloat = 70           // icon (28) + symbol+name vstack, .padding(.vertical, 6)
        let perChartSection: CGFloat = 250 // timeframe picker + 150pt chart + caption + paddings

        let n = CGFloat(store.tokens.count)
        let exp = CGFloat(store.expandedTokenIds.count)

        return topReserve + headerBar + dividers + searchBar
            + n * perRow
            + exp * perChartSection
            + bottomPad
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
        // Snap height to content. Run on the NEXT runloop tick so AppKit has
        // finished restoring the autosaved frame and applying our origin change
        // — calling synchronously here was occasionally seeing stale state.
        // windowDidBecomeKey below covers the same case as a second safety net.
        DispatchQueue.main.async { [weak self] in
            self?.fitWindowHeightToContent()
        }
    }

    private func makeWindow() -> NSWindow {
        // Width is restored from UserDefaults (set on every live-resize end).
        // Height starts at a placeholder; the first fitWindowHeightToContent()
        // call (deferred from showWindow + windowDidBecomeKey) sizes it to fit
        // the actual content.
        let storedW = UserDefaults.standard.double(forKey: Self.widthKey)
        let initialW: CGFloat = storedW >= 320 ? storedW : 420
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialW, height: 400),
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
        // Don't move the window when the user drags inside a chart — that
        // would compete with the chart's own pan gesture. The titlebar strip
        // (top ~22pt, where the close button lives) is still a drag zone
        // automatically thanks to the .titled styleMask.
        win.isMovableByWindowBackground = false
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 320, height: 240)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.level = .floating
        let hosting = NSHostingController(rootView: ContentView().environmentObject(store))
        // Don't let SwiftUI dictate the window size: with the default sizing
        // options, assigning the controller below resizes the window to the
        // content's ideal width — silently throwing away the stored width.
        hosting.sizingOptions = []
        win.contentViewController = hosting
        // Re-apply the stored width after the controller is attached (belt and
        // suspenders — the assignment above can still nudge the frame).
        win.setContentSize(NSSize(width: initialW, height: 400))
        self.contentController = hosting
        win.delegate = self
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

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        let target = notification.object as? NSWindow
        Task { @MainActor [weak self] in
            guard let self, let target, target === self.window else { return }
            // Second safety net for fit-on-show: this fires reliably every time the
            // window appears, even if the async dispatch above somehow missed.
            self.fitWindowHeightToContent()
        }
    }

    nonisolated func windowDidEndLiveResize(_ notification: Notification) {
        let target = notification.object as? NSWindow
        Task { @MainActor [weak self] in
            guard let self, let target, target === self.window else { return }
            // Width changes get persisted; height gets snapped back to content
            // (the user can't manually make the window taller than content needs —
            // any extra height would be void space, which is what we're avoiding).
            UserDefaults.standard.set(Double(target.frame.width), forKey: Self.widthKey)
            self.fitWindowHeightToContent()
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        let target = notification.object as? NSWindow
        Task { @MainActor [weak self] in
            guard let self, let target else { return }
            if target === self.portfolioWindow {
                self.store.portfolio.windowClosed()   // stop the chart auto-refresh loop
            } else if target === self.window {
                // Persist width on close too, not only on live-resize end.
                UserDefaults.standard.set(Double(target.frame.width), forKey: Self.widthKey)
            }
        }
    }

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
