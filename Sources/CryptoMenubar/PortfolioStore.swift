import Foundation
import SwiftUI

// Portfolio tracker state: which tokens you hold + how much, the total-value
// time series for the selected timeframe, and encrypted persistence.
//
// Holdings are loaded lazily the first time the Portfolio window opens (not
// at launch) so the Keychain prompt only ever appears when you actually use
// the feature.

struct Holding: Identifiable, Codable, Equatable {
    var token: Token
    var amount: Double
    var id: Int { token.id }
}

@MainActor
final class PortfolioStore: ObservableObject {
    enum LoadState: Equatable {
        case notLoaded
        case loaded
        case failed(String)
    }

    @Published private(set) var holdings: [Holding] = []
    @Published private(set) var loadState: LoadState = .notLoaded
    @Published var persistError: String? = nil

    @Published var timeframe: Timeframe {
        didSet {
            UserDefaults.standard.set(timeframe.rawValue, forKey: Self.timeframeKey)
            if timeframe != oldValue {
                // The top picker sets EVERY chart — drop per-holding overrides.
                holdingTimeframes = [:]
                overrideHistories = [:]
                overrideSeries = [:]
                overrideSources = [:]
                overrideFailed = []
                overrideLoading = []
                reloadSeries()
            }
        }
    }
    // Per-holding timeframe overrides (persisted). A holding without an
    // entry follows the top picker.
    @Published var holdingTimeframes: [Int: Timeframe] {
        didSet {
            if let data = try? JSONEncoder().encode(holdingTimeframes) {
                UserDefaults.standard.set(data, forKey: Self.holdingTimeframesKey)
            }
        }
    }
    // amount × price series for holdings whose own timeframe differs from
    // the global one (fetched separately — they can't share the total's grid).
    @Published private(set) var overrideSeries: [Int: [PricePoint]] = [:]
    @Published private(set) var overrideSources: [Int: ChartSource] = [:]
    @Published private(set) var overrideFailed: Set<Int> = []
    @Published private(set) var overrideLoading: Set<Int> = []
    private var overrideHistories: [Int: (timeframe: Timeframe, points: [PricePoint])] = [:]
    @Published var expandedIds: Set<Int> {
        didSet {
            if let data = try? JSONEncoder().encode(Array(expandedIds)) {
                UserDefaults.standard.set(data, forKey: Self.expandedKey)
            }
        }
    }
    @Published var hideValues: Bool {
        didSet { UserDefaults.standard.set(hideValues, forKey: Self.hideValuesKey) }
    }

    // Derived series for the current timeframe. `totalSeries` is Σ amount×price
    // on a shared time grid; `tokenSeries[id]` is amount×price for one token on
    // that same grid (so the collapsible per-token charts line up with the total).
    @Published private(set) var totalSeries: [PricePoint] = []
    @Published private(set) var tokenSeries: [Int: [PricePoint]] = [:]
    @Published private(set) var seriesSources: [Int: ChartSource] = [:]
    @Published private(set) var excludedIds: [Int] = []      // history fetch failed
    @Published private(set) var seriesLoading = false
    @Published private(set) var seriesTimeframe: Timeframe? = nil   // what the series were built for
    @Published private(set) var lastSeriesFetch: Date? = nil

    private weak var store: TokenStore?
    private var rawHistories: [Int: [PricePoint]] = [:]      // per-token price history (current timeframe)
    private var inFlightFetches = 0                           // concurrent history fetches (spinner while > 0)
    private var autoRefreshTask: Task<Void, Never>?

    private static let timeframeKey = "portfolioTimeframe.v1"
    private static let expandedKey = "portfolioExpanded.v1"
    private static let hideValuesKey = "portfolioHideValues.v1"
    private static let holdingTimeframesKey = "portfolioHoldingTimeframes.v1"

    init() {
        let tfRaw = UserDefaults.standard.string(forKey: Self.timeframeKey) ?? ""
        self.timeframe = Timeframe(rawValue: tfRaw) ?? .d30
        if let data = UserDefaults.standard.data(forKey: Self.expandedKey),
           let arr = try? JSONDecoder().decode([Int].self, from: data) {
            self.expandedIds = Set(arr)
        } else {
            self.expandedIds = []
        }
        self.hideValues = UserDefaults.standard.bool(forKey: Self.hideValuesKey)
        if let data = UserDefaults.standard.data(forKey: Self.holdingTimeframesKey),
           let decoded = try? JSONDecoder().decode([Int: Timeframe].self, from: data) {
            self.holdingTimeframes = decoded
        } else {
            self.holdingTimeframes = [:]
        }
    }

    func attach(_ store: TokenStore) {
        self.store = store
    }

    /// Token ids the quote refresh must cover in addition to the watchlist.
    var quoteIds: [Int] { holdings.map(\.id) }

    // MARK: - Persistence (encrypted)

    func loadIfNeeded() {
        guard loadState != .loaded else { return }
        load()
    }

    func load() {
        do {
            guard let blob = try PortfolioFile.read() else {
                // Nothing saved yet — no Keychain access needed at all.
                holdings = []
                loadState = .loaded
                return
            }
            guard let key = try SecureStore.fetchKey() else {
                throw SecureStoreError.keyMissing
            }
            let json = try SecureStore.decrypt(blob, key: key)
            holdings = try JSONDecoder().decode([Holding].self, from: json)
            loadState = .loaded
            persistError = nil
            // Drop overrides for tokens no longer held.
            holdingTimeframes = holdingTimeframes.filter { entry in holdings.contains { $0.id == entry.key } }
            Task { await store?.refresh() }
            reloadSeries()
        } catch {
            loadState = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Last resort when the file can't be decrypted: wipe it and start over.
    func resetStorage() {
        PortfolioFile.delete()
        SecureStore.deleteKey()
        holdings = []
        rawHistories = [:]
        rebuildSeries()
        loadState = .loaded
        persistError = nil
    }

    private func persist() {
        // Never overwrite a file we couldn't read — that would destroy data.
        guard loadState == .loaded else { return }
        do {
            let key = try SecureStore.fetchOrCreateKey()
            let json = try JSONEncoder().encode(holdings)
            try PortfolioFile.write(try SecureStore.encrypt(json, key: key))
            persistError = nil
        } catch {
            persistError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - Holdings

    func add(_ token: Token) {
        guard loadState == .loaded else { return }
        guard !holdings.contains(where: { $0.id == token.id }) else { return }
        holdings.append(Holding(token: token, amount: 0))
        persist()
        Task { await store?.refresh() }
        fetchHistories(for: [token.id])
    }

    func setAmount(_ amount: Double, for id: Int) {
        guard let i = holdings.firstIndex(where: { $0.id == id }) else { return }
        let clean = max(0, amount.isFinite ? amount : 0)
        guard holdings[i].amount != clean else { return }
        holdings[i].amount = clean
        persist()
        rebuildSeries()
        rebuildOverrideSeries()
    }

    func remove(id: Int) {
        holdings.removeAll { $0.id == id }
        expandedIds.remove(id)
        holdingTimeframes.removeValue(forKey: id)
        overrideHistories.removeValue(forKey: id)
        overrideSeries.removeValue(forKey: id)
        overrideSources.removeValue(forKey: id)
        overrideFailed.remove(id)
        overrideLoading.remove(id)
        rawHistories.removeValue(forKey: id)
        seriesSources.removeValue(forKey: id)
        excludedIds.removeAll { $0 == id }
        persist()
        rebuildSeries()
    }

    func toggleExpanded(_ id: Int) {
        if expandedIds.contains(id) { expandedIds.remove(id) } else { expandedIds.insert(id) }
    }

    // MARK: - Live values (from CMC quotes)

    func value(of holding: Holding) -> Double? {
        guard let q = store?.quotes[holding.id] else { return nil }
        return holding.amount * q.price
    }

    /// Sum of all holdings that have a quote. nil until at least one quote is in.
    var totalValue: Double? {
        var sum = 0.0
        var any = false
        for h in holdings {
            if let v = value(of: h) { sum += v; any = true }
        }
        return any ? sum : nil
    }

    /// Holdings sorted by live value (largest first); unknown values last.
    var sortedHoldings: [Holding] {
        holdings.sorted { a, b in
            (value(of: a) ?? -1) > (value(of: b) ?? -1)
        }
    }

    /// Change of the total over the selected timeframe. Series-based when the
    /// chart has loaded; falls back to CMC's per-token percent fields (when
    /// every held token has one for this timeframe).
    var totalChange: (absolute: Double, percent: Double, source: PriceChange.Source)? {
        if seriesTimeframe == timeframe, excludedIds.isEmpty,
           let f = totalSeries.first, let l = totalSeries.last, f.price > 0 {
            let src = seriesSources.values.contains(.coingecko) ? ChartSource.coingecko : .binance
            return (l.price - f.price, (l.price / f.price - 1) * 100, .chart(src))
        }
        var now = 0.0, then = 0.0
        for h in holdings where h.amount > 0 {
            guard let q = store?.quotes[h.id], let pct = q.percentChange(for: timeframe) else { return nil }
            let v = h.amount * q.price
            now += v
            then += v / (1 + pct / 100)
        }
        guard then > 0 else { return nil }
        return (now - then, (now / then - 1) * 100, .cmc)
    }

    func change(for holding: Holding) -> PriceChange? {
        let tf = holdingTimeframe(for: holding.id)
        if tf != timeframe {
            let h = overrideHistories[holding.id]
            return PriceChange.resolve(timeframe: tf,
                                       series: h?.timeframe == tf ? h?.points : nil,
                                       seriesSource: overrideSources[holding.id],
                                       quote: store?.quotes[holding.id])
        }
        let series = seriesTimeframe == timeframe ? rawHistories[holding.id] : nil
        return PriceChange.resolve(timeframe: timeframe,
                                   series: series,
                                   seriesSource: seriesSources[holding.id],
                                   quote: store?.quotes[holding.id])
    }

    // MARK: - Per-holding timeframe overrides

    func holdingTimeframe(for id: Int) -> Timeframe {
        holdingTimeframes[id] ?? timeframe
    }

    func setHoldingTimeframe(_ tf: Timeframe, for id: Int) {
        guard holdingTimeframe(for: id) != tf else { return }
        if tf == timeframe {
            // Back in step with the top picker → just follow it again.
            holdingTimeframes.removeValue(forKey: id)
            overrideHistories.removeValue(forKey: id)
            overrideSeries.removeValue(forKey: id)
            overrideSources.removeValue(forKey: id)
            overrideFailed.remove(id)
            overrideLoading.remove(id)
        } else {
            holdingTimeframes[id] = tf
            fetchOverride(for: id)
        }
    }

    /// What to draw in a holding's chart: its override series when it has its
    /// own timeframe, otherwise the grid-aligned slice of the total.
    func chartSeries(for id: Int) -> [PricePoint] {
        holdingTimeframes[id] != nil ? (overrideSeries[id] ?? []) : (tokenSeries[id] ?? [])
    }
    func chartSource(for id: Int) -> ChartSource? {
        holdingTimeframes[id] != nil ? overrideSources[id] : seriesSources[id]
    }
    func chartLoading(for id: Int) -> Bool {
        holdingTimeframes[id] != nil ? overrideLoading.contains(id) : seriesLoading
    }
    func chartFailed(for id: Int) -> Bool {
        holdingTimeframes[id] != nil ? overrideFailed.contains(id) : excludedIds.contains(id)
    }

    private func fetchOverride(for id: Int, silent: Bool = false) {
        guard let store,
              let holding = holdings.first(where: { $0.id == id }),
              let tf = holdingTimeframes[id] else { return }
        if !silent { overrideLoading.insert(id) }
        Task { [weak self] in
            let result = try? await store.history(for: holding.token, timeframe: tf)
            guard let self else { return }
            self.overrideLoading.remove(id)
            // Dropped if the override changed/cleared or the holding was removed meanwhile.
            guard self.holdingTimeframes[id] == tf, self.holdings.contains(where: { $0.id == id }) else { return }
            if let result {
                self.overrideHistories[id] = (tf, result.points)
                self.overrideSources[id] = result.source
                self.overrideFailed.remove(id)
            } else {
                self.overrideHistories.removeValue(forKey: id)
                self.overrideSources.removeValue(forKey: id)
                self.overrideFailed.insert(id)
            }
            self.rebuildOverrideSeries()
        }
    }

    private func rebuildOverrideSeries() {
        var out: [Int: [PricePoint]] = [:]
        for (id, h) in overrideHistories {
            guard let holding = holdings.first(where: { $0.id == id }), holding.amount > 0 else { continue }
            out[id] = h.points.map { PricePoint(timestamp: $0.timestamp, price: $0.price * holding.amount) }
        }
        overrideSeries = out
    }

    // MARK: - History series

    /// Re-fetch every holding's history for the current timeframe.
    func reloadSeries(silent: Bool = false) {
        rawHistories = [:]
        seriesSources = [:]
        excludedIds = []
        fetchHistories(for: holdings.map(\.id), silent: silent)
        for id in holdingTimeframes.keys { fetchOverride(for: id, silent: silent) }
    }

    // Fetches run concurrently and are never cancelled — an incremental fetch
    // (token just added) must not kill a full reload that's still in flight.
    // Results are dropped if the timeframe changed or the holding was removed
    // while the request was out.
    private func fetchHistories(for ids: [Int], silent: Bool = false) {
        guard let store else { return }
        let targets = holdings.filter { ids.contains($0.id) }
        guard !targets.isEmpty else {
            seriesTimeframe = timeframe
            rebuildSeries()
            return
        }
        let tf = timeframe
        inFlightFetches += 1
        if !silent { seriesLoading = true }
        Task { [weak self] in
            var results: [Int: HistoryResult] = [:]
            var failed: [Int] = []
            await withTaskGroup(of: (Int, HistoryResult?).self) { group in
                for h in targets {
                    group.addTask {
                        (h.id, try? await store.history(for: h.token, timeframe: tf))
                    }
                }
                for await (id, r) in group {
                    if let r { results[id] = r } else { failed.append(id) }
                }
            }
            guard let self else { return }
            self.inFlightFetches = max(0, self.inFlightFetches - 1)
            if self.inFlightFetches == 0 { self.seriesLoading = false }
            guard tf == self.timeframe else { return }   // stale — a newer timeframe took over
            let stillHeld = Set(self.holdings.map(\.id))
            for (id, r) in results where stillHeld.contains(id) {
                self.rawHistories[id] = r.points
                self.seriesSources[id] = r.source
                self.excludedIds.removeAll { $0 == id }
            }
            for id in failed where stillHeld.contains(id) && !self.excludedIds.contains(id) {
                self.excludedIds.append(id)
            }
            self.seriesTimeframe = tf
            self.lastSeriesFetch = Date()
            self.rebuildSeries()
        }
    }

    private func rebuildSeries() {
        let amounts = Dictionary(uniqueKeysWithValues: holdings.map { ($0.id, $0.amount) })
        let usable = rawHistories.filter { (amounts[$0.key] ?? 0) > 0 }
        let built = PortfolioMath.alignedSeries(histories: usable, amounts: amounts)
        totalSeries = built.total
        tokenSeries = built.perToken
    }

    // MARK: - Auto refresh (only while the window is open)

    func windowOpened() {
        loadIfNeeded()
        // Re-opened after a while → the series are stale; refresh quietly.
        if loadState == .loaded, !holdings.isEmpty,
           let last = lastSeriesFetch,
           Date().timeIntervalSince(last) > (store?.refreshIntervalSeconds ?? TokenStore.defaultRefreshSeconds) {
            Task { await store?.refresh() }
            reloadSeries(silent: true)
        }
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.store?.refreshIntervalSeconds ?? TokenStore.defaultRefreshSeconds
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.store?.refresh()
                self.reloadSeries(silent: true)
            }
        }
    }

    func windowClosed() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }
}

// MARK: - Series alignment

enum PortfolioMath {
    /// Resamples every token's history onto one shared time grid and sums
    /// amount×price. The grid starts at the LATEST first-timestamp among the
    /// tokens (before that the portfolio value would be undefined — e.g. a
    /// token that listed in 2020 has no 2018 price) and ends at the latest
    /// last-timestamp. Prices are linearly interpolated between neighbouring
    /// points and clamped at the ends, which also handles CoinGecko's
    /// off-grid timestamps.
    static func alignedSeries(histories: [Int: [PricePoint]],
                              amounts: [Int: Double],
                              maxPoints: Int = 600) -> (total: [PricePoint], perToken: [Int: [PricePoint]]) {
        let usable = histories.filter { !$0.value.isEmpty }
        guard !usable.isEmpty else { return ([], [:]) }

        let start = usable.values.compactMap { $0.first?.timestamp }.max()!
        let end = usable.values.compactMap { $0.last?.timestamp }.max()!
        let densest = usable.values.map { pts in pts.filter { $0.timestamp >= start }.count }.max() ?? 2
        let n = max(2, min(maxPoints, densest))
        let span = end.timeIntervalSince(start)
        let grid: [Date]
        if span <= 0 {
            grid = [start]
        } else {
            let step = span / Double(n - 1)
            grid = (0..<n).map { start.addingTimeInterval(Double($0) * step) }
        }

        var perToken: [Int: [PricePoint]] = [:]
        var total = Array(repeating: 0.0, count: grid.count)
        for (id, pts) in usable {
            let amt = amounts[id] ?? 0
            let prices = sample(pts, at: grid)
            var series: [PricePoint] = []
            series.reserveCapacity(grid.count)
            for (i, t) in grid.enumerated() {
                let v = prices[i] * amt
                total[i] += v
                series.append(PricePoint(timestamp: t, price: v))
            }
            perToken[id] = series
        }
        let totalSeries = grid.enumerated().map { PricePoint(timestamp: $0.element, price: total[$0.offset]) }
        return (totalSeries, perToken)
    }

    /// Linear interpolation of `pts` (sorted by time) at each grid date.
    static func sample(_ pts: [PricePoint], at grid: [Date]) -> [Double] {
        guard let first = pts.first else { return grid.map { _ in 0 } }
        var out: [Double] = []
        out.reserveCapacity(grid.count)
        var j = 0
        for t in grid {
            while j + 1 < pts.count && pts[j + 1].timestamp <= t { j += 1 }
            if t <= first.timestamp {
                out.append(first.price)
            } else if j + 1 >= pts.count {
                out.append(pts[pts.count - 1].price)
            } else {
                let a = pts[j], b = pts[j + 1]
                let dt = b.timestamp.timeIntervalSince(a.timestamp)
                let f = dt > 0 ? t.timeIntervalSince(a.timestamp) / dt : 0
                out.append(a.price + f * (b.price - a.price))
            }
        }
        return out
    }
}

// MARK: - Amount formatting

/// "1,234.5678" style — trims trailing zeros, up to 8 decimals for tiny coins.
func formatAmount(_ amount: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US")
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = abs(amount) >= 1 ? 6 : 8
    return f.string(from: NSNumber(value: amount)) ?? "\(amount)"
}

/// Parses "1,234.5", " 0.25 ", "1 234.5" — returns nil for anything else.
func parseAmount(_ s: String) -> Double? {
    let cleaned = s.replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: " ", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    return Double(cleaned)
}
