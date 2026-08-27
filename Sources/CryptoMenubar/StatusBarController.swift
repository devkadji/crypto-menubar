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
    // Height the user last dragged the window to, when SHORTER than its
    // content. Acts as a persistent cap: content changes still auto-fit, but
    // never beyond this. Dragging the window to (or past) its full content
    // height clears the cap and hands control back to auto-fit.
    private static let maxHeightKey = "CryptoMenubarMainWindow.maxHeight.v1"
    private static let portfolioMaxHeightKey = "CryptoMenubarPortfolioWindow.maxHeight.v1"
    private var userMaxHeight: CGFloat? {
        get { Self.readCap(Self.maxHeightKey) }
        set { UserDefaults.standard.set(Double(newValue ?? 0), forKey: Self.maxHeightKey) }
    }
    private var portfolioUserMaxHeight: CGFloat? {
        get { Self.readCap(Self.portfolioMaxHeightKey) }
        set { UserDefaults.standard.set(Double(newValue ?? 0), forKey: Self.portfolioMaxHeightKey) }
    }
    private static func readCap(_ key: String) -> CGFloat? {
        let v = UserDefaults.standard.double(forKey: key)
        return v >= 240 ? v : nil
    }

    init(store: TokenStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupStatusItem()
        observeStore()
        observePortfolio()
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
        DispatchQueue.main.async { [weak self] in self?.fitPortfolioWindowToContent() }
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
        win.minSize = NSSize(width: 520, height: 360)
        win.collectionBehavior = [.fullScreenAuxiliary]
        let hosting = NSHostingController(
            rootView: PortfolioView()
                .environmentObject(store)
                .environmentObject(store.portfolio)
        )
        // Height is fitted to content by us (see fitPortfolioWindowToContent);
        // don't let SwiftUI impose its own size on the window.
        hosting.sizingOptions = []
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

    // MARK: - Portfolio window fit (same rules as the main window)

    private func observePortfolio() {
        store.portfolio.$measuredChromeHeight
            .combineLatest(store.portfolio.$measuredListHeight)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.fitPortfolioWindowToContent()
            }
            .store(in: &cancellables)
    }

    /// Content height the portfolio needs (nil until SwiftUI has measured).
    private var portfolioContentHeight: CGFloat? {
        let c = store.portfolio.measuredChromeHeight
        let l = store.portfolio.measuredListHeight
        return (c > 0 && l > 0) ? c + l : nil
    }

    /// Frame height the portfolio window needs: content + real titlebar.
    private func portfolioNeededFrameHeight(_ win: NSWindow) -> CGFloat? {
        guard let content = portfolioContentHeight else { return nil }
        let titlebar = win.frame.height - win.contentRect(forFrameRect: win.frame).height
        return content + titlebar
    }

    private func fitPortfolioWindowToContent() {
        guard let win = portfolioWindow, let needed = portfolioNeededFrameHeight(win) else { return }
        var targetH = min(needed, maxAvailableHeight(win))
        if let cap = portfolioUserMaxHeight { targetH = min(targetH, cap) }
        targetH = max(targetH, win.minSize.height)

        let currentTop = win.frame.maxY
        guard abs(targetH - win.frame.height) > 1 else { return }
        var frame = win.frame
        frame.size.height = targetH
        frame.origin.y = currentTop - targetH
        win.setFrame(frame, display: true, animate: false)
    }

    /// Natural content height (measured by SwiftUI once rendered, estimated
    /// from constants before the first frame).
    private var contentHeight: CGFloat {
        let chrome = store.measuredChromeHeight
        let list = store.measuredListHeight
        return (chrome > 0 && list > 0) ? chrome + list : computeIntendedHeight()
    }

    /// Screen the window's TOP edge is on. `window.screen` picks the screen
    /// with the largest overlap, which can be the wrong one on multi-display
    /// setups when the window is tall — then the bottom cap comes from a
    /// taller screen and the window runs off the real screen's bottom edge.
    private func screenForFit(_ window: NSWindow) -> NSScreen? {
        let topCenter = NSPoint(x: window.frame.midX, y: window.frame.maxY - 1)
        return NSScreen.screens.first { $0.frame.contains(topCenter) }
            ?? window.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Largest height the window may have without leaving the screen: from
    /// its current top edge down to the bottom of the visible area (above
    /// the Dock).
    private func maxAvailableHeight(_ window: NSWindow) -> CGFloat {
        let currentTop = window.frame.maxY
        let bottomLimit = (screenForFit(window)?.visibleFrame.minY ?? 0) + 8
        return max(window.minSize.height, currentTop - bottomLimit)
    }

    private func fitWindowHeightToContent() {
        guard let window = window else { return }
        var targetH = min(contentHeight, maxAvailableHeight(window))
        if let cap = userMaxHeight { targetH = min(targetH, cap) }
        targetH = max(targetH, window.minSize.height)

        let currentTop = window.frame.maxY
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
        // The window is .titled + .fullSizeContentView, so AppKit reports the
        // (invisible) titlebar as a safe-area inset and SwiftUI would push all
        // content ~28pt down — but our measured content height doesn't
        // include that inset, so the window ends up too short and the last
        // row is cropped behind a scrollbar. We lay out from the very top
        // instead; ContentView reserves its own 22pt strip for the close button.
        hosting.safeAreaRegions = []
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
            guard let self, let target else { return }
            // Second safety net for fit-on-show: this fires reliably every time a
            // window appears, even if the async dispatch above somehow missed.
            if target === self.window {
                self.fitWindowHeightToContent()
            } else if target === self.portfolioWindow {
                self.fitPortfolioWindowToContent()
            }
        }
    }

    nonisolated func windowDidEndLiveResize(_ notification: Notification) {
        let target = notification.object as? NSWindow
        Task { @MainActor [weak self] in
            guard let self, let target else { return }
            // The user's height is respected — never snapped back. If it's
            // shorter than the content it becomes the persistent cap (the
            // list scrolls). If it's at least the content height, the cap is
            // cleared and the window trims any void space below the content.
            let h = target.frame.height
            if target === self.window {
                UserDefaults.standard.set(Double(target.frame.width), forKey: Self.widthKey)
                if h >= self.contentHeight - 1 {
                    self.userMaxHeight = nil
                    self.fitWindowHeightToContent()
                } else {
                    self.userMaxHeight = h
                }
            } else if target === self.portfolioWindow {
                guard let needed = self.portfolioNeededFrameHeight(target) else { return }
                if h >= needed - 1 {
                    self.portfolioUserMaxHeight = nil
                    self.fitPortfolioWindowToContent()
                } else {
                    self.portfolioUserMaxHeight = h
                }
            }
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
