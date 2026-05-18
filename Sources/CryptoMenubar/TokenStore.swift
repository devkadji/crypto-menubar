import Foundation
import SwiftUI

@MainActor
final class TokenStore: ObservableObject {
    @Published var tokens: [Token] {
        didSet { persistTokens() }
    }
    @Published var quotes: [Int: Quote] = [:]
    @Published var expandedTokenIds: Set<Int> {
        didSet { persistExpanded() }
    }
    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: Self.apiKeyKey)
            Task { await cmc.setAPIKey(apiKey) }
        }
    }
    @Published var coingeckoKey: String {
        didSet {
            UserDefaults.standard.set(coingeckoKey, forKey: Self.coingeckoKeyKey)
            Task { await coingecko.setDemoApiKey(coingeckoKey) }
        }
    }
    @Published var requestThrottleSeconds: Double {
        didSet {
            UserDefaults.standard.set(requestThrottleSeconds, forKey: Self.throttleKey)
            Task { await coingecko.setMinGap(requestThrottleSeconds) }
        }
    }
    @Published var alerts: [Int: PriceAlert] {
        didSet { persistAlerts() }
    }
    @Published var refreshIntervalSeconds: Double {
        didSet {
            UserDefaults.standard.set(refreshIntervalSeconds, forKey: Self.refreshIntervalKey)
            restartRefreshLoop()
        }
    }
    @Published var lastError: String? = nil

    let cmc = CMCClient()
    let binance = BinanceClient()
    let coingecko = CoinGeckoClient()
    let alertManager = AlertManager()
    private var refreshTask: Task<Void, Never>?

    private static let tokensKey = "tokens.v1"
    private static let expandedKey = "expandedTokens.v1"
    private static let apiKeyKey = "cmcAPIKey.v1"
    private static let coingeckoKeyKey = "coingeckoDemoKey.v1"
    private static let coingeckoIdCacheKey = "coingeckoIdCache.v1"
    private static let coingeckoHistoryCacheKey = "coingeckoHistoryCache.v1"
    private static let throttleKey = "requestThrottle.v1"
    private static let alertsKey = "alerts.v1"
    private static let refreshIntervalKey = "refreshInterval.v1"
    static let defaultRefreshSeconds: Double = 300   // 5 min — fits CMC free tier

    // Default watchlist: just Bitcoin.
    private static let defaultTokens: [Token] = [
        Token(id: 1, symbol: "BTC", name: "Bitcoin", slug: "bitcoin")
    ]

    init() {
        let resolvedTokens: [Token]
        if let data = UserDefaults.standard.data(forKey: Self.tokensKey),
           let saved = try? JSONDecoder().decode([Token].self, from: data),
           !saved.isEmpty {
            resolvedTokens = saved
        } else {
            resolvedTokens = Self.defaultTokens
        }
        self.tokens = resolvedTokens

        // Expanded set persists across launches. On first run, expand all defaults.
        if let data = UserDefaults.standard.data(forKey: Self.expandedKey),
           let arr = try? JSONDecoder().decode([Int].self, from: data) {
            self.expandedTokenIds = Set(arr)
        } else {
            self.expandedTokenIds = Set(resolvedTokens.map(\.id))
        }
        self.apiKey = UserDefaults.standard.string(forKey: Self.apiKeyKey) ?? ""
        self.coingeckoKey = UserDefaults.standard.string(forKey: Self.coingeckoKeyKey) ?? ""
        // 0 (off) is the default — UserDefaults.double returns 0 for missing keys.
        self.requestThrottleSeconds = UserDefaults.standard.double(forKey: Self.throttleKey)

        // Load alerts (per-token high/low thresholds + armed state).
        if let data = UserDefaults.standard.data(forKey: Self.alertsKey),
           let decoded = try? JSONDecoder().decode([Int: PriceAlert].self, from: data) {
            self.alerts = decoded
        } else {
            self.alerts = [:]
        }

        // Refresh interval (5 min default; UserDefaults.double returns 0 when unset).
        let storedInterval = UserDefaults.standard.double(forKey: Self.refreshIntervalKey)
        self.refreshIntervalSeconds = storedInterval > 0 ? storedInterval : Self.defaultRefreshSeconds

        let savedIdCache: [String: String] = {
            if let data = UserDefaults.standard.data(forKey: Self.coingeckoIdCacheKey),
               let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                return decoded
            }
            // Seed with the very-popular case to skip the first round-trip.
            return ["bitcoin": "bitcoin"]
        }()

        let savedHistoryCache: [String: CoinGeckoClient.CacheEntry] = {
            if let data = UserDefaults.standard.data(forKey: Self.coingeckoHistoryCacheKey),
               let decoded = try? JSONDecoder().decode([String: CoinGeckoClient.CacheEntry].self, from: data) {
                return decoded
            }
            return [:]
        }()

        Task { [self] in
            await cmc.setAPIKey(self.apiKey)
            await coingecko.setDemoApiKey(self.coingeckoKey)
            await coingecko.setMinGap(self.requestThrottleSeconds)
            await coingecko.loadCaches(idCache: savedIdCache, historyCache: savedHistoryCache)
            await refresh()
        }
        startRefreshLoop()
    }

    /// Returns historical prices + the source they came from. Tries Binance
    /// first (no rate limit, fast). Falls back to CoinGecko for tokens Binance
    /// doesn't list, OR for tokens Binance returns stale data for (e.g. XMR
    /// delisted from Binance in 2024 but /klines still returns 2024 candles).
    /// CMC keeps doing search + current quotes — it's better at those.
    func history(for token: Token, timeframe: Timeframe) async throws -> HistoryResult {
        // Primary: Binance.
        do {
            let pts = try await binance.history(symbol: token.symbol, timeframe: timeframe)
            return HistoryResult(points: pts, source: .binance)
        } catch {
            // Any Binance error (symbol missing, stale data, network blip) → fall through.
        }

        // Fallback: CoinGecko (rate-limited; throttle configurable in Settings).
        let pts = try await coingecko.history(
            slug: token.slug,
            symbol: token.symbol,
            timeframe: timeframe
        )
        // Persist both CoinGecko caches after each call (cheap — tens of KB).
        let ids = await coingecko.snapshotIdCache()
        let hist = await coingecko.snapshotHistoryCache()
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: Self.coingeckoIdCacheKey)
        }
        if let data = try? JSONEncoder().encode(hist) {
            UserDefaults.standard.set(data, forKey: Self.coingeckoHistoryCacheKey)
        }
        return HistoryResult(points: pts, source: .coingecko)
    }

    var primaryDisplay: String {
        guard let first = tokens.first else { return "—" }
        if let q = quotes[first.id] {
            return "\(first.symbol) \(formatPrice(q.price))"
        }
        return first.symbol
    }

    private func persistTokens() {
        if let data = try? JSONEncoder().encode(tokens) {
            UserDefaults.standard.set(data, forKey: Self.tokensKey)
        }
    }

    private func persistExpanded() {
        if let data = try? JSONEncoder().encode(Array(expandedTokenIds)) {
            UserDefaults.standard.set(data, forKey: Self.expandedKey)
        }
    }

    private func persistAlerts() {
        if let data = try? JSONEncoder().encode(alerts) {
            UserDefaults.standard.set(data, forKey: Self.alertsKey)
        }
    }

    /// Set or clear the alert for a token. Passing nil (or an inactive alert) removes it.
    func setAlert(_ alert: PriceAlert?, for tokenId: Int) {
        if let alert, alert.isActive {
            alerts[tokenId] = alert
        } else {
            alerts.removeValue(forKey: tokenId)
        }
    }

    func add(_ token: Token) {
        guard !tokens.contains(where: { $0.id == token.id }) else { return }
        tokens.append(token)
        expandedTokenIds.insert(token.id)   // newly added tokens start expanded
        Task { await refresh() }
    }

    func remove(_ token: Token) {
        tokens.removeAll { $0.id == token.id }
        quotes.removeValue(forKey: token.id)
        expandedTokenIds.remove(token.id)
    }

    func toggleExpanded(_ tokenId: Int) {
        if expandedTokenIds.contains(tokenId) {
            expandedTokenIds.remove(tokenId)
        } else {
            expandedTokenIds.insert(tokenId)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        tokens.move(fromOffsets: source, toOffset: destination)
    }

    func refresh() async {
        guard !tokens.isEmpty, !apiKey.isEmpty else { return }
        do {
            let result = try await cmc.quotes(for: tokens.map(\.id))
            quotes = result
            lastError = nil
            checkAlerts()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Fire notifications for any token whose price has just crossed a threshold.
    /// Each threshold fires once per crossing, then re-arms only after the price
    /// returns to the other side — no spamming while price stays above/below.
    private func checkAlerts() {
        for (tokenId, alert) in alerts {
            guard let quote = quotes[tokenId],
                  let token = tokens.first(where: { $0.id == tokenId }) else { continue }
            let price = quote.price
            var updated = alert

            if let high = alert.high {
                if price >= high {
                    if alert.highArmed {
                        alertManager.notify(token: token, currentPrice: price, direction: .high, threshold: high)
                        updated.highArmed = false
                    }
                } else {
                    updated.highArmed = true
                }
            }
            if let low = alert.low {
                if price <= low {
                    if alert.lowArmed {
                        alertManager.notify(token: token, currentPrice: price, direction: .low, threshold: low)
                        updated.lowArmed = false
                    }
                } else {
                    updated.lowArmed = true
                }
            }

            if updated != alert {
                alerts[tokenId] = updated
            }
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        let interval = refreshIntervalSeconds
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.refresh()
            }
        }
    }

    private func restartRefreshLoop() {
        startRefreshLoop()
    }
}

func formatPrice(_ price: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    // Force en_US grouping ("76,405") so the menubar reads cleanly regardless of
    // the system locale (German would otherwise yield "76.405 US$").
    f.locale = Locale(identifier: "en_US")
    // Tiered precision: decimals stop adding info once the integer part is big.
    let digits: Int
    switch abs(price) {
    case 100...:        digits = 0   // BTC, ETH, SOL — "$76,405", not "$76,405.44"
    case 1..<100:       digits = 2   // mid-range tokens — "$23.45"
    case 0.01..<1:      digits = 4   // sub-dollar tokens — "$0.1234"
    default:            digits = 6   // micro-caps — "$0.000045"
    }
    f.maximumFractionDigits = digits
    f.minimumFractionDigits = digits
    let n = f.string(from: NSNumber(value: price)) ?? "\(price)"
    return "$\(n)"
}
