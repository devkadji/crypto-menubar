import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

// SwiftUI PreferenceKey used to bubble the *actual rendered height* of the
// chrome (header + search + dividers + top padding) and of the token list
// (inside the ScrollView) up to ContentView. From there it's pushed to the
// store, where StatusBarController observes and resizes the window.
//
// This is much more reliable than estimating heights with constants — the
// constants drift every time SwiftUI's default padding/spacing changes.
struct ChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension Notification.Name {
    /// Posted by the header's portfolio button; StatusBarController opens the window.
    static let openPortfolioWindow = Notification.Name("io.github.devkadji.cryptomenubar.openPortfolio")
}

struct ContentView: View {
    @EnvironmentObject var store: TokenStore
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Chrome (everything above the scrollable token list) — its size is
            // measured by a GeometryReader background so we know exactly how
            // much vertical space it consumes.
            VStack(spacing: 0) {
                // Reserve space for the borderless window's traffic-light buttons.
                Color.clear.frame(height: 22)
                HeaderView(showSettings: $showSettings)
                Divider()
                if !store.apiKey.isEmpty {
                    AddTokenView().padding(.vertical, 6)
                    Divider()
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ChromeHeightKey.self,
                        value: geo.size.height
                    )
                }
            )

            if store.apiKey.isEmpty {
                APIKeyPrompt(showSettings: $showSettings)
            } else {
                ScrollView {
                    TokenListView()
                        // .fixedSize(vertical: true) forces SwiftUI to lay out
                        // the list at its IDEAL (natural) height instead of
                        // collapsing it to the ScrollView's visible bounds —
                        // which is what the background GeometryReader needs
                        // to read in order to report the true content height.
                        .fixedSize(horizontal: false, vertical: true)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ListHeightKey.self,
                                    value: geo.size.height
                                )
                            }
                        )
                }
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
        // Belt and suspenders with hosting.safeAreaRegions = [] — never let the
        // titlebar inset shift the layout (see StatusBarController.makeWindow).
        .ignoresSafeArea()
        .onPreferenceChange(ChromeHeightKey.self) { h in
            store.measuredChromeHeight = h
        }
        .onPreferenceChange(ListHeightKey.self) { h in
            store.measuredListHeight = h
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
            SortMenu(selection: $store.sortOrder,
                     options: [.manual, .name, .symbol, .price, .change])

            Button {
                NotificationCenter.default.post(name: .openPortfolioWindow, object: nil)
            } label: {
                Image(systemName: "chart.pie")
            }
            .buttonStyle(.borderless)
            .help("Portfolio tracker")

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
    var placeholder: String = "Add token by ticker (e.g. ETH, SOL)"
    /// Where a picked token goes. Defaults to the watchlist; the Portfolio
    /// window passes its own handler.
    var onSelect: ((Token) -> Void)? = nil
    @State private var query = ""
    @State private var searching = false
    @State private var results: [Token] = []
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { runSearch() }
                if searching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)

            ForEach(results.prefix(5)) { token in
                Button {
                    if let onSelect { onSelect(token) } else { store.add(token) }
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
    @State private var draggingId: Int? = nil      // row being drag-reordered

    var body: some View {
        VStack(spacing: 0) {
            ForEach(store.displayedTokens) { token in
                let isExpanded = store.expandedTokenIds.contains(token.id)
                VStack(spacing: 0) {
                    TokenRow(
                        token: token,
                        quote: store.quotes[token.id],
                        isExpanded: isExpanded,
                        onAlertTap: { alertTokenId = token.id }
                    )
                    // Drag the row (not the chart — it has its own pan gesture)
                    // to rearrange; dropping onto any part of another token's
                    // block, chart included, moves it there.
                    .reorderable(id: token.id, draggingId: $draggingId) { dragged, onto in
                        store.moveToken(id: dragged, before: onto)
                    }
                    if isExpanded {
                        ChartSection(token: token)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.04))
                            .onDrop(of: [.text], delegate: ReorderDropDelegate(
                                rowId: token.id, draggingId: $draggingId,
                                move: { store.moveToken(id: $0, before: $1) }))
                    }
                }
                .contextMenu {
                    Button(isExpanded ? "Collapse chart" : "Expand chart") {
                        store.toggleExpanded(token.id)
                    }
                    Button("Price alerts…") { alertTokenId = token.id }
                    Divider()
                    Button("Move to top") { moveToEdge(token, top: true) }
                    Button("Move to bottom") { moveToEdge(token, top: false) }
                    Divider()
                    Button("Remove from list", role: .destructive) {
                        store.remove(token)
                    }
                }
            }
        }
        // Dropping outside any row: just end the drag.
        .onDrop(of: [.text], isTargeted: nil) { _ in draggingId = nil; return true }
        .sheet(item: Binding(
            get: { alertTokenId.flatMap { id in store.tokens.first { $0.id == id } } },
            set: { _ in alertTokenId = nil }
        )) { token in
            AlertConfigSheet(token: token)
                .environmentObject(store)
        }
    }

    private func moveToEdge(_ token: Token, top: Bool) {
        let shown = store.displayedTokens
        guard let edge = top ? shown.first : shown.last, edge.id != token.id else { return }
        store.moveToken(id: token.id, before: edge.id)
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
                    // "% over which window?" — labelled with the chart timeframe
                    // (persisted per token) and sourced from the chart itself
                    // when it's expanded, CMC's matching field when collapsed.
                    ChangeBadge(
                        timeframe: store.chartTimeframe(for: token.id),
                        change: store.priceChange(for: token.id)
                    )
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

// MARK: - Chart section (expanded under a token row)

struct ChartSection: View {
    let token: Token
    @State private var history: [PricePoint] = []
    @State private var source: ChartSource? = nil
    @State private var loading = false
    @State private var errorMessage: String? = nil
    @State private var loadTask: Task<Void, Never>? = nil
    @State private var autoRefreshTask: Task<Void, Never>? = nil
    @State private var lastFetchedAt: Date? = nil     // when history was last pulled
    @EnvironmentObject var store: TokenStore

    // Timeframe lives in the store (persisted per token) so the row's %
    // badge can follow it even while the chart is collapsed.
    private var timeframe: Timeframe { store.chartTimeframe(for: token.id) }
    private var timeframeBinding: Binding<Timeframe> {
        Binding(
            get: { store.chartTimeframe(for: token.id) },
            set: { store.setChartTimeframe($0, for: token.id) }
        )
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(token.name) (\(token.symbol))")
                    .font(.subheadline).bold()
                Spacer()
                Picker("", selection: timeframeBinding) {
                    ForEach(Timeframe.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 280)
                .labelsHidden()
                .controlSize(.small)
                .help("Chart timeframe — also sets the window for the % change shown in the row")
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
                    InteractiveLineChart(points: history)
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
                SourceCaption(text: "via \(source.label)", last: last.timestamp, fetchedAt: lastFetchedAt)
            }
        }
        .onAppear {
            loadHistory()
            startAutoRefresh()
        }
        .onDisappear {
            autoRefreshTask?.cancel()
            autoRefreshTask = nil
            loadTask?.cancel()
            // Collapsed → the row badge falls back to CMC's figure.
            store.chartStats.removeValue(forKey: token.id)
        }
        .onChange(of: token.id) { _, _ in
            loadHistory()
        }
        .onChange(of: timeframe) { _, _ in
            loadHistory()
        }
    }

    // Self-contained refresh loop — re-fetches this chart's history every
    // `refreshIntervalSeconds`, independent of the store's quote-refresh cycle.
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
        apply(result, timeframe: tf)
    }

    @MainActor
    private func apply(_ result: HistoryResult, timeframe tf: Timeframe) {
        history = result.points
        source = result.source
        lastFetchedAt = Date()
        if let f = result.points.first, let l = result.points.last {
            store.chartStats[token.id] = ChartStats(
                timeframe: tf, firstPrice: f.price, lastPrice: l.price, source: result.source
            )
        } else {
            store.chartStats.removeValue(forKey: token.id)
        }
    }

    private func loadHistory() {
        loadTask?.cancel()
        loading = true
        errorMessage = nil
        let tok = token
        let tf = timeframe
        loadTask = Task {
            // 250 ms debounce: rapid timeframe clicks cancel before this wakes
            // up, so we don't fire a request per click.
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            do {
                let result = try await store.history(for: tok, timeframe: tf)
                if Task.isCancelled { return }
                await MainActor.run {
                    apply(result, timeframe: tf)
                    loading = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    history = []
                    source = nil
                    loading = false
                    store.chartStats.removeValue(forKey: token.id)
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
