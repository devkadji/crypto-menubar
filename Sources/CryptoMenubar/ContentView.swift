import SwiftUI
import Charts
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: TokenStore
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Reserve space for the borderless window's traffic-light buttons
            // (positioned at top-left of the window over our content).
            Color.clear.frame(height: 22)
            HeaderView(showSettings: $showSettings)
            Divider()

            if store.apiKey.isEmpty {
                APIKeyPrompt(showSettings: $showSettings)
            } else {
                AddTokenView()
                    .padding(.vertical, 6)
                Divider()
                ScrollView {
                    TokenListView()
                }
                // The window is user-resizable (drag any edge), so the ScrollView
                // just fills the available vertical space.
                .frame(maxHeight: .infinity)
            }

            if let err = store.lastError {
                Divider()
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
        }
    }
}

// MARK: - Header (refresh / settings / quit)

struct HeaderView: View {
    @Binding var showSettings: Bool
    @EnvironmentObject var store: TokenStore

    var body: some View {
        HStack {
            Text("Crypto Menubar").font(.headline)
            Spacer()
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")

            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - First-run API key prompt

struct APIKeyPrompt: View {
    @Binding var showSettings: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set your CoinMarketCap API key to get started.")
                .font(.subheadline)
            Text("Get a free key at coinmarketcap.com/api.")
                .font(.caption).foregroundColor(.secondary)
            Button("Open Settings…") { showSettings = true }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Add-token search

struct AddTokenView: View {
    @EnvironmentObject var store: TokenStore
    @State private var query = ""
    @State private var searching = false
    @State private var results: [Token] = []
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Add token by ticker (e.g. ETH, SOL)", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { runSearch() }
                if searching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)

            ForEach(results.prefix(5)) { token in
                Button {
                    store.add(token)
                    results = []
                    query = ""
                } label: {
                    HStack {
                        Text(token.symbol).bold()
                        Text(token.name).foregroundColor(.secondary)
                        Spacer()
                        Image(systemName: "plus.circle")
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }

            if let err = errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal, 12)
            }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        errorMessage = nil
        results = []
        searching = true
        Task {
            do {
                let r = try await store.cmc.search(symbol: q)
                await MainActor.run {
                    results = r
                    if r.isEmpty { errorMessage = "No matches for '\(q)'." }
                    searching = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    searching = false
                }
            }
        }
    }
}

// MARK: - Token list (each row hover-able)

struct TokenListView: View {
    @EnvironmentObject var store: TokenStore
    @State private var alertTokenId: Int? = nil    // which token's alert sheet is open

    var body: some View {
        VStack(spacing: 0) {
            ForEach(store.tokens) { token in
                let isExpanded = store.expandedTokenIds.contains(token.id)
                VStack(spacing: 0) {
                    TokenRow(
                        token: token,
                        quote: store.quotes[token.id],
                        isExpanded: isExpanded,
                        onAlertTap: { alertTokenId = token.id }
                    )
                    if isExpanded {
                        ChartSection(token: token)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.04))
                    }
                }
                .contextMenu {
                    Button(isExpanded ? "Collapse chart" : "Expand chart") {
                        store.toggleExpanded(token.id)
                    }
                    Button("Price alerts…") { alertTokenId = token.id }
                    Button("Remove from list", role: .destructive) {
                        store.remove(token)
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { alertTokenId.flatMap { id in store.tokens.first { $0.id == id } } },
            set: { _ in alertTokenId = nil }
        )) { token in
            AlertConfigSheet(token: token)
                .environmentObject(store)
        }
    }
}

struct TokenRow: View {
    let token: Token
    let quote: Quote?
    let isExpanded: Bool
    let onAlertTap: () -> Void
    @EnvironmentObject var store: TokenStore

    private var alertActive: Bool {
        store.alerts[token.id]?.isActive ?? false
    }

    var body: some View {
        HStack(spacing: 8) {
            // Chevron toggle — click to expand/collapse the chart for this token.
            Button {
                store.toggleExpanded(token.id)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 12, alignment: .center)
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? "Collapse chart" : "Expand chart")

            TokenIcon(cmcId: token.id, symbol: token.symbol)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(token.symbol).bold()
                Text(token.name).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let q = quote {
                    Text(formatPrice(q.price))
                    Text(String(format: "%@%.2f%%", q.percentChange24h >= 0 ? "+" : "", q.percentChange24h))
                        .font(.caption)
                        .foregroundColor(q.percentChange24h >= 0 ? .green : .red)
                } else {
                    Text("—").foregroundColor(.secondary)
                }
            }

            // Bell — opens the price-alert sheet for this token.
            Button(action: onAlertTap) {
                Image(systemName: alertActive ? "bell.fill" : "bell")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(alertActive ? .accentColor : .secondary)
                    .frame(width: 16, alignment: .center)
            }
            .buttonStyle(.borderless)
            .help(alertActive ? "Edit price alerts" : "Set price alerts")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Chart section (pops up when hovering a token row)

struct ChartSection: View {
    let token: Token
    @State private var timeframe: Timeframe = .d30
    @State private var history: [PricePoint] = []
    @State private var source: ChartSource? = nil
    @State private var loading = false
    @State private var errorMessage: String? = nil
    @State private var loadTask: Task<Void, Never>? = nil
    @State private var hoverPoint: PricePoint? = nil
    @State private var xZoom: CGFloat = 1.0           // 1.0 = full range; pinch out to zoom in
    @State private var zoomAtGestureStart: CGFloat = 1.0
    @State private var scrollLeadingEdge: Date = .distantPast
    @State private var isChartHovered = false         // cursor currently over this chart
    @State private var scrollMonitor: Any? = nil      // NSEvent monitor for Option+scroll zoom
    @State private var autoRefreshTask: Task<Void, Never>? = nil
    @State private var lastFetchedAt: Date? = nil     // when history was last pulled
    @EnvironmentObject var store: TokenStore

    private static let maxZoom: CGFloat = 30.0       // cap so we don't show <2 points

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(token.name) (\(token.symbol))")
                    .font(.subheadline).bold()
                Spacer()
                Picker("", selection: $timeframe) {
                    ForEach(Timeframe.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                // 7 options need more room than the old 4. Push the title to its
                // own line above (handled by the surrounding HStack collapsing).
                .frame(minWidth: 280)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 12)

            ZStack {
                if loading {
                    ProgressView().controlSize(.small)
                } else if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                } else if !history.isEmpty {
                    chartView
                        .frame(height: 140)
                        .padding(.horizontal, 12)
                } else {
                    Text("No data").font(.caption).foregroundColor(.secondary)
                }
            }
            .frame(height: 150)

            // Source + freshness caption — shows which provider served this
            // chart and when it was last polled.
            if let source = source, let last = history.last {
                sourceCaption(source: source, last: last.timestamp, fetchedAt: lastFetchedAt)
            }
        }
        .onAppear {
            loadHistory()
            installScrollZoomMonitor()
            startAutoRefresh()
        }
        .onDisappear {
            if let m = scrollMonitor { NSEvent.removeMonitor(m) }
            scrollMonitor = nil
            autoRefreshTask?.cancel()
            autoRefreshTask = nil
        }
        .onChange(of: token.id) { _, _ in
            hoverPoint = nil
            resetZoom()
            loadHistory()
        }
        .onChange(of: timeframe) { _, _ in
            hoverPoint = nil
            resetZoom()
            loadHistory()
        }
    }

    // Self-contained refresh loop — re-fetches this chart's history every
    // `refreshIntervalSeconds`, independent of the store's quote-refresh cycle.
    // Runs only while the chart is expanded (started in onAppear, cancelled in
    // onDisappear).
    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                let interval = store.refreshIntervalSeconds
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await silentReload()
            }
        }
    }

    // Re-fetch without the loading spinner or a zoom reset — the chart just
    // swaps in fresh data. On failure the existing chart stays untouched.
    @MainActor
    private func silentReload() async {
        let tf = timeframe
        guard let result = try? await store.history(for: token, timeframe: tf) else { return }
        guard tf == timeframe else { return }   // user switched away mid-fetch
        history = result.points
        source = result.source
        lastFetchedAt = Date()
        reanchorRightEdge()
    }

    // Mouse users have no pinch gesture — let Option+scroll-wheel zoom instead.
    // A local NSEvent monitor observes scroll events without sitting in the
    // hit-test path (so it doesn't block the hover tooltip). It only acts when
    // Option is held and the cursor is over THIS chart.
    private func installScrollZoomMonitor() {
        guard scrollMonitor == nil else { return }
        let hovered = $isChartHovered
        let zoom = $xZoom
        let zoomStart = $zoomAtGestureStart
        let scroll = $scrollLeadingEdge
        let hist = $history
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Mouse wheel only (trackpad has pinch); Option held; over this chart.
            guard event.modifierFlags.contains(.option),
                  !event.hasPreciseScrollingDeltas,
                  hovered.wrappedValue else {
                return event
            }
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return nil }
            // Scroll up → zoom in. Clamp per-event delta so one notch is gentle.
            let clamped = min(max(delta, -3), 3)
            let factor = 1.0 + clamped * 0.08
            let newZoom = max(1.0, min(Self.maxZoom, zoom.wrappedValue * factor))
            zoom.wrappedValue = newZoom
            zoomStart.wrappedValue = newZoom
            // Re-anchor the visible window's right edge to the latest point.
            let h = hist.wrappedValue
            if let first = h.first?.timestamp, let last = h.last?.timestamp, last > first {
                let visible = last.timeIntervalSince(first) / Double(newZoom)
                scroll.wrappedValue = last.addingTimeInterval(-visible)
            }
            return nil   // consume — don't let the list scroll
        }
    }

    // Length of the visible X window in seconds. zoom=1 shows the full series;
    // zoom=2 shows half; etc. (Used by .chartXVisibleDomain — Swift Charts'
    // first-class API for fixed-window panning/zooming. The whole series is
    // always fed to the chart; only the visible WINDOW changes, so marks never
    // re-render or fade out during zoom changes.)
    private var visibleDuration: TimeInterval {
        guard let first = history.first?.timestamp,
              let last = history.last?.timestamp,
              last > first else { return 86400 }
        return last.timeIntervalSince(first) / Double(xZoom)
    }

    // Points inside the current visible window. Computed once per body pass
    // and used only for the Y-axis fit + hover-snap (NOT for the chart's data
    // — the chart sees all of history).
    private var visiblePoints: [PricePoint] {
        guard !history.isEmpty,
              let last = history.last?.timestamp else { return history }
        let cutoff = last.addingTimeInterval(-visibleDuration)
        return history.filter { $0.timestamp >= cutoff }
    }

    // Fit the Y-axis to the data inside the current X window, with 8% padding.
    // Recomputes as the user zooms so the chart always uses its full vertical
    // extent.
    private var yDomain: ClosedRange<Double> {
        let prices = visiblePoints.map(\.price)
        guard let lo = prices.min(), let hi = prices.max() else { return 0...1 }
        if hi == lo {
            let pad = max(abs(hi) * 0.01, 0.0001)
            return (lo - pad)...(hi + pad)
        }
        let pad = (hi - lo) * 0.08
        return (lo - pad)...(hi + pad)
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0)
            .onChanged { value in
                let proposed = zoomAtGestureStart * value.magnification
                let new = max(1.0, min(Self.maxZoom, proposed))
                withTransaction(Transaction(animation: nil)) {
                    xZoom = new
                    reanchorRightEdge()
                }
            }
            .onEnded { _ in
                zoomAtGestureStart = xZoom
            }
    }

    private func resetZoom() {
        xZoom = 1.0
        zoomAtGestureStart = 1.0
        reanchorRightEdge()
    }

    // Move the scroll window so its TRAILING (right) edge stays pinned to the
    // most-recent data point. Called whenever zoom or data changes.
    private func reanchorRightEdge() {
        guard let last = history.last?.timestamp else { return }
        scrollLeadingEdge = last.addingTimeInterval(-visibleDuration)
    }

    @ViewBuilder
    private var chartView: some View {
        let domain = yDomain
        // Feed Chart ALL history; the visible window is controlled below via
        // chartXVisibleDomain + chartScrollPosition (Swift Charts' first-class
        // windowing API). This avoids per-frame data mutation during zoom,
        // which was leaving brief rendering gaps in the curve.
        Chart {
            ForEach(history) { p in
                // Anchor the area's bottom to the visible domain's lower bound,
                // not to y=0. Without this the fill extends down to 0 (off-screen
                // since we've restricted the Y axis) and bleeds into rows below.
                AreaMark(
                    x: .value("Date", p.timestamp),
                    yStart: .value("Bottom", domain.lowerBound),
                    yEnd: .value("Price", p.price)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Date", p.timestamp),
                    y: .value("Price", p.price)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.monotone)
            }

            // Hover crosshair: vertical rule + highlighted point + price/date annotation.
            if let hp = hoverPoint {
                RuleMark(x: .value("Date", hp.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                PointMark(
                    x: .value("Date", hp.timestamp),
                    y: .value("Price", hp.price)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(70)
                .annotation(
                    // .automatic lets Swift Charts pick top vs. bottom based on
                    // where there's room — avoids the leftmost-curve occlusion
                    // we saw when .top forced the tooltip into the data band.
                    position: .automatic,
                    alignment: .center,
                    spacing: 6,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    HoverTooltip(point: hp)
                }
            }
        }
        .chartYScale(domain: domain)
        // Visible window: only this slice of the X axis is shown at any moment.
        // The chart still has access to all of history, so marks render once
        // and aren't dropped/recreated as the window changes.
        .chartXVisibleDomain(length: visibleDuration)
        .chartScrollPosition(x: $scrollLeadingEdge)
        .chartScrollableAxes(.horizontal)
        // Belt and suspenders: even if the gesture transaction misses a frame,
        // tell Charts not to animate any state derived from the zoom value.
        .animation(nil, value: xZoom)
        .chartYAxis {
            // .automatic(desiredCount:) sometimes gives ceil+1 ticks; cap at 4
            // explicitly so labels never get crammed at the top/bottom edges.
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
        }
        // Previously had `.clipped()` here as a safety net for an AreaMark bug
        // (gradient overflowing the chart frame). That's now fixed by anchoring
        // AreaMark to `domain.lowerBound`, so clipping isn't needed — and removing
        // it stops the topmost/bottom Y-axis label from being cut off.
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            isChartHovered = true
                            guard let plotFrame = proxy.plotFrame else { return }
                            let origin = geo[plotFrame].origin
                            let xInPlot = location.x - origin.x
                            if let date: Date = proxy.value(atX: xInPlot, as: Date.self) {
                                hoverPoint = nearest(to: date)
                            }
                        case .ended:
                            isChartHovered = false
                            hoverPoint = nil
                        }
                    }
                    // Pinch lives INSIDE the overlay's hit area so it competes
                    // for the same events the overlay rect was eating.
                    .simultaneousGesture(zoomGesture)
                    .onTapGesture(count: 2) { resetZoom() }
            }
        }
    }

    @ViewBuilder
    private func sourceCaption(source: ChartSource, last: Date, fetchedAt: Date?) -> some View {
        // Dot color reflects how fresh the most-recent data point is:
        // green ≤2h, yellow ≤24h, red >24h.
        let age = Date().timeIntervalSince(last)
        let color: Color = age <= 2 * 3600 ? .green
            : (age <= 24 * 3600 ? .yellow : .red)
        // "↻ HH:mm" is when we last polled — advances every refresh interval,
        // so it's a visible confirmation the chart is auto-updating.
        let updated = fetchedAt.map {
            "↻ " + $0.formatted(.dateTime.hour().minute())
        } ?? ""
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("via \(source.label) · \(updated)")
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }

    private func nearest(to date: Date) -> PricePoint? {
        let candidates = visiblePoints.isEmpty ? history : visiblePoints
        guard !candidates.isEmpty else { return nil }
        return candidates.min { a, b in
            abs(a.timestamp.timeIntervalSince(date)) < abs(b.timestamp.timeIntervalSince(date))
        }
    }

    private func loadHistory() {
        loadTask?.cancel()
        loading = true
        errorMessage = nil
        let tok = token
        let tf = timeframe
        loadTask = Task {
            // 250 ms debounce: if user keeps moving the cursor across tokens
            // we cancel before this wakes up, so we don't fire a request per token.
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            do {
                let result = try await store.history(for: tok, timeframe: tf)
                if Task.isCancelled { return }
                await MainActor.run {
                    history = result.points
                    source = result.source
                    lastFetchedAt = Date()
                    loading = false
                    // Initial scroll-position anchor — without this the chart
                    // would render with scrollLeadingEdge still at .distantPast.
                    reanchorRightEdge()
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    history = []
                    source = nil
                    loading = false
                }
            }
        }
    }
}

// MARK: - Token icon

// CMC hosts every token's logo at a predictable URL keyed by its id:
//   https://s2.coinmarketcap.com/static/img/coins/64x64/{id}.png
// AsyncImage takes care of fetching + URL cache. Falls back to a circle
// with the first letter of the symbol if the icon is missing or offline.
struct TokenIcon: View {
    let cmcId: Int
    let symbol: String

    private var url: URL? {
        URL(string: "https://s2.coinmarketcap.com/static/img/coins/64x64/\(cmcId).png")
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            case .failure, .empty:
                fallback
            @unknown default:
                fallback
            }
        }
    }

    private var fallback: some View {
        Circle()
            .fill(Color.gray.opacity(0.2))
            .overlay(
                Text(String(symbol.prefix(1)))
                    .font(.caption2.bold())
                    .foregroundColor(.secondary)
            )
    }
}

// MARK: - Hover tooltip (date + price near cursor)

struct HoverTooltip: View {
    let point: PricePoint

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(point.timestamp.formatted(
                .dateTime.month(.abbreviated).day().hour().minute()
            ))
            .font(.caption2)
            .foregroundColor(.secondary)
            Text(formatPrice(point.price))
                .font(.caption.bold())
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Price-alert sheet

struct AlertConfigSheet: View {
    let token: Token
    @EnvironmentObject var store: TokenStore
    @Environment(\.dismiss) var dismiss
    @State private var highStr: String = ""
    @State private var lowStr: String = ""
    @State private var permissionDenied: Bool = false

    private var currentPrice: Double? { store.quotes[token.id]?.price }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                TokenIcon(cmcId: token.id, symbol: token.symbol)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading) {
                    Text("Price alerts — \(token.symbol)").font(.title3).bold()
                    if let p = currentPrice {
                        Text("Current: \(formatPrice(p))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Alert when price goes ↑ ABOVE").font(.caption.bold())
                TextField("e.g. 80000 (leave empty to disable)", text: $highStr)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Alert when price goes ↓ BELOW").font(.caption.bold())
                TextField("e.g. 70000 (leave empty to disable)", text: $lowStr)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Each alert fires once when the threshold is crossed, then re-arms after the price moves back through it. Checks run at the price-refresh interval set in Settings.")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if permissionDenied {
                Text("⚠️ macOS notifications are denied for this app. Enable them in System Settings → Notifications → Crypto Menubar.")
                    .font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Clear all", role: .destructive) {
                    store.setAlert(nil, for: token.id)
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            let existing = store.alerts[token.id]
            highStr = existing?.high.map { String($0) } ?? ""
            lowStr = existing?.low.map { String($0) } ?? ""
        }
    }

    private func save() {
        let high = parseNumber(highStr)
        let low = parseNumber(lowStr)
        // Preserve armed state if just editing thresholds; reset if values changed.
        let existing = store.alerts[token.id]
        var alert = PriceAlert(high: high, low: low)
        if let existing {
            // Keep arm states only if the threshold hasn't changed; otherwise re-arm.
            if existing.high == high { alert.highArmed = existing.highArmed }
            if existing.low == low   { alert.lowArmed  = existing.lowArmed }
        }
        Task {
            let ok = await store.alertManager.requestPermissionIfNeeded()
            if !ok {
                await MainActor.run { permissionDenied = true }
                return
            }
            await MainActor.run {
                store.setAlert(alert, for: token.id)
                dismiss()
            }
        }
    }

    private func parseNumber(_ s: String) -> Double? {
        let cleaned = s
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }
}

// MARK: - Settings sheet

struct SettingsView: View {
    @EnvironmentObject var store: TokenStore
    @Environment(\.dismiss) var dismiss
    @State private var key: String = ""
    @State private var cgKey: String = ""
    @State private var throttle: Double = 0
    @State private var refreshInterval: Double = TokenStore.defaultRefreshSeconds

    private static let refreshIntervalOptions: [(Double, String)] = [
        (60.0,   "1 minute — ~43K CMC calls/month (exceeds free tier)"),
        (300.0,  "5 minutes — default, ~8.6K/month (fits free tier)"),
        (900.0,  "15 minutes — ~2.9K/month"),
        (1800.0, "30 minutes — ~1.4K/month"),
    ]

    private static let throttleOptions: [(Double, String)] = [
        (0.0, "Off — fastest, may hit rate limits"),
        (0.5, "500 ms — recommended with Demo key"),
        (1.5, "1.5 s — recommended without key"),
        (3.0, "3 s — paranoid (no rate-limit errors)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.title2).bold()

            // MARK: CoinMarketCap
            VStack(alignment: .leading, spacing: 6) {
                Text("CoinMarketCap").font(.headline)
                Text("Used for token search and current prices.")
                    .font(.caption).foregroundColor(.secondary)
                SecureField("Paste CMC API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Link("Get a free key at coinmarketcap.com/api",
                     destination: URL(string: "https://coinmarketcap.com/api/")!)
                    .font(.caption)
            }

            Divider()

            // MARK: Price refresh interval (used for menubar updates + alert checks)
            VStack(alignment: .leading, spacing: 6) {
                Text("Price refresh interval").font(.headline)
                Text("How often to fetch current prices from CoinMarketCap. Also determines how quickly price alerts can fire. Lower = fresher data, more API usage.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Interval", selection: $refreshInterval) {
                    ForEach(Self.refreshIntervalOptions, id: \.0) { (value, label) in
                        Text(label).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 360, alignment: .leading)
                Text("CMC free tier: 10,000 calls/month total.")
                    .font(.caption2).foregroundColor(.secondary)
            }

            Divider()

            // MARK: Chart sources overview
            VStack(alignment: .leading, spacing: 4) {
                Text("Chart data sources").font(.headline)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        Text("Primary").font(.caption2.monospaced())
                            .frame(width: 80, alignment: .leading)
                        Text("Binance (api.binance.com/api/v3/klines) — no key, no rate limits in practice. Used for any token paired against USDT on Binance.")
                            .font(.caption2).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top) {
                        Text("Fallback").font(.caption2.monospaced())
                            .frame(width: 80, alignment: .leading)
                        Text("CoinGecko market_chart — used only when a token isn't on Binance (stablecoins, small-caps, exchange-exclusive tokens).")
                            .font(.caption2).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            // MARK: CoinGecko fallback config
            VStack(alignment: .leading, spacing: 6) {
                Text("CoinGecko (fallback only)").font(.headline)
                Text("Settings below apply when the chart falls back to CoinGecko. Most tokens never hit this path.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("Paste CoinGecko Demo key (optional)", text: $cgKey)
                    .textFieldStyle(.roundedBorder)
                Link("Get a free Demo key at coingecko.com/api/pricing",
                     destination: URL(string: "https://www.coingecko.com/en/api/pricing")!)
                    .font(.caption)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("No key").font(.caption2.monospaced())
                            .frame(width: 130, alignment: .leading)
                        Text("~10 req/min, aggressive burst limit")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Demo key (free)").font(.caption2.monospaced())
                            .frame(width: 130, alignment: .leading)
                        Text("30 req/min, 10K/month")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.top, 4)

                // Throttle picker (applies to CoinGecko only)
                Text("Throttle (CoinGecko fallback only):")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.top, 6)
                Picker("Throttle", selection: $throttle) {
                    ForEach(Self.throttleOptions, id: \.0) { (value, label) in
                        Text(label).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 360, alignment: .leading)
            }

            // MARK: Buttons
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    store.apiKey = key
                    store.coingeckoKey = cgKey
                    store.requestThrottleSeconds = throttle
                    store.refreshIntervalSeconds = refreshInterval
                    dismiss()
                    Task { await store.refresh() }
                }
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            key = store.apiKey
            cgKey = store.coingeckoKey
            throttle = store.requestThrottleSeconds
            refreshInterval = store.refreshIntervalSeconds
        }
    }
}
