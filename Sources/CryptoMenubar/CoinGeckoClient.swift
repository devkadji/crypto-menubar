import Foundation

// CoinGecko provides the historical chart endpoint that CMC's free tier doesn't.
// We map CMC slug → CoinGecko coin id (usually 1:1 — both call Bitcoin "bitcoin").
// If the slug doesn't resolve, we fall back to /search by symbol and cache the result.
//
// To keep within CoinGecko's free-tier rate limit (~10–15 req/min on the public API),
// we cache the resolved id + the history points themselves, with a TTL per timeframe.

enum CoinGeckoError: Error, LocalizedError {
    case http(Int, String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .http(429, _):
            return "CoinGecko rate limit. Try again in a minute."
        case .http(let code, let msg):
            return "CoinGecko API \(code): \(String(msg.prefix(150)))"
        case .notFound:
            return "Could not find this token on CoinGecko."
        }
    }
}

actor CoinGeckoClient {
    private let baseURL = URL(string: "https://api.coingecko.com/api/v3")!
    private var idCache: [String: String] = [:]            // CMC slug → CoinGecko id
    private var historyCache: [String: CacheEntry] = [:]   // "id|timeframe" → entry
    private var demoApiKey: String = ""

    // Throttle: enforce a minimum gap between successive outgoing requests.
    // 0 means no throttling. Useful for staying inside CoinGecko's free-tier
    // rate limit (~10 req/min unauthed, 30 req/min with a Demo key).
    private var minGapSeconds: Double = 0
    private var nextFireAt: Date = .distantPast

    struct PointCodable: Codable {
        let timestamp: Date
        let price: Double
    }
    struct CacheEntry: Codable {
        var points: [PointCodable]
        var fetchedAt: Date
    }

    // MARK: - Setup

    func loadCaches(idCache: [String: String], historyCache: [String: CacheEntry]) {
        self.idCache = idCache
        self.historyCache = historyCache
    }

    func setDemoApiKey(_ key: String) {
        demoApiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setMinGap(_ seconds: Double) {
        minGapSeconds = max(0, seconds)
    }

    // Reserve the next firing slot (now or in the future, whichever is later)
    // and wait until then. Concurrent callers each get a distinct slot.
    private func awaitSlot() async {
        guard minGapSeconds > 0 else { return }
        let now = Date()
        let fireAt = max(now, nextFireAt)
        nextFireAt = fireAt.addingTimeInterval(minGapSeconds)
        let wait = fireAt.timeIntervalSince(now)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    func snapshotIdCache() -> [String: String] { idCache }
    func snapshotHistoryCache() -> [String: CacheEntry] { historyCache }

    // MARK: - Public

    func history(slug: String, symbol: String, timeframe: Timeframe) async throws -> [PricePoint] {
        let cacheK = cacheKey(slug, timeframe)

        // Fresh cache hit?
        if let entry = historyCache[cacheK],
           Date().timeIntervalSince(entry.fetchedAt) < ttl(for: timeframe) {
            return entry.points.map { PricePoint(timestamp: $0.timestamp, price: $0.price) }
        }

        do {
            let id = idCache[slug] ?? slug
            do {
                let points = try await marketChart(id: id, days: timeframe.days)
                if idCache[slug] == nil { idCache[slug] = slug }
                return store(cacheK: cacheK, points: points)
            } catch CoinGeckoError.http(404, _) {
                // Slug doesn't map directly — resolve via search
                guard let resolved = try await searchForId(symbol: symbol) else {
                    throw CoinGeckoError.notFound
                }
                idCache[slug] = resolved
                let points = try await marketChart(id: resolved, days: timeframe.days)
                return store(cacheK: cacheK, points: points)
            }
        } catch CoinGeckoError.http(429, _) {
            // Rate limited — serve whatever we have, even if stale; only error if no cache at all.
            if let entry = historyCache[cacheK] {
                return entry.points.map { PricePoint(timestamp: $0.timestamp, price: $0.price) }
            }
            throw CoinGeckoError.http(429, "rate limit")
        }
    }

    // MARK: - Cache helpers

    private func cacheKey(_ slug: String, _ tf: Timeframe) -> String { "\(slug)|\(tf.rawValue)" }

    private func ttl(for tf: Timeframe) -> TimeInterval {
        // Shorter timeframes need fresher data because the last bar moves more often.
        switch tf {
        case .d7:   return 5 * 60
        case .d30:  return 15 * 60
        case .d90:  return 30 * 60
        case .d365: return 60 * 60
        }
    }

    private func store(cacheK: String, points: [PricePoint]) -> [PricePoint] {
        historyCache[cacheK] = CacheEntry(
            points: points.map { PointCodable(timestamp: $0.timestamp, price: $0.price) },
            fetchedAt: Date()
        )
        return points
    }

    // MARK: - HTTP

    private func marketChart(id: String, days: Int) async throws -> [PricePoint] {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("coins/\(id)/market_chart"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "vs_currency", value: "usd"),
            URLQueryItem(name: "days", value: String(days)),
        ]
        let req = makeRequest(url: comps.url!)
        await awaitSlot()
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw CoinGeckoError.http(0, "no http response")
        }
        if !(200..<300).contains(http.statusCode) {
            throw CoinGeckoError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Resp: Decodable { let prices: [[Double]] }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return r.prices.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return PricePoint(timestamp: Date(timeIntervalSince1970: pair[0] / 1000), price: pair[1])
        }
    }

    private func searchForId(symbol: String) async throws -> String? {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "query", value: symbol)]
        let req = makeRequest(url: comps.url!)
        await awaitSlot()
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw CoinGeckoError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        struct Resp: Decodable {
            struct Coin: Decodable { let id: String; let symbol: String }
            let coins: [Coin]
        }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        let sym = symbol.lowercased()
        return r.coins.first(where: { $0.symbol.lowercased() == sym })?.id ?? r.coins.first?.id
    }

    private func makeRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !demoApiKey.isEmpty {
            req.setValue(demoApiKey, forHTTPHeaderField: "x-cg-demo-api-key")
        }
        return req
    }
}
