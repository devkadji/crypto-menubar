import Foundation

enum CMCError: Error, LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case decoding(Error)
    case noResults

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Set your CoinMarketCap API key in Settings."
        case .http(401, _):
            return "Invalid CoinMarketCap API key."
        case .http(let code, _) where code == 402 || code == 403:
            return "Your CMC plan does not include this endpoint. Historical OHLCV requires Standard plan or above."
        case .http(429, _):
            return "Rate limit hit. Slow down or upgrade plan."
        case .http(let code, let msg):
            return "CMC API \(code): \(String(msg.prefix(150)))"
        case .decoding(let e):
            return "Decoding error: \(e.localizedDescription)"
        case .noResults:
            return "No matching token found."
        }
    }
}

actor CMCClient {
    private let baseURL = URL(string: "https://pro-api.coinmarketcap.com")!
    private var apiKey: String = ""

    func setAPIKey(_ key: String) {
        apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func get(_ path: String, query: [(String, String)] = []) async throws -> Data {
        guard !apiKey.isEmpty else { throw CMCError.missingAPIKey }
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var req = URLRequest(url: comps.url!)
        req.setValue(apiKey, forHTTPHeaderField: "X-CMC_PRO_API_KEY")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw CMCError.http(0, "no http response")
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CMCError.http(http.statusCode, body)
        }
        return data
    }

    // MARK: - Search by ticker symbol

    struct SearchResult: Identifiable {
        let token: Token
        let isActive: Bool
        var id: Int { token.id }
    }

    func search(symbol: String) async throws -> [SearchResult] {
        let s = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }
        let data = try await get(
            "/v1/cryptocurrency/map",
            query: [
                ("symbol", s),
                ("listing_status", "active"),
                ("sort", "cmc_rank"),
                ("limit", "20"),
            ]
        )
        struct Response: Decodable {
            struct Item: Decodable {
                let id: Int
                let symbol: String
                let name: String
                let slug: String
                let is_active: Int?
            }
            let data: [Item]
        }
        do {
            let r = try JSONDecoder().decode(Response.self, from: data)
            // Active coins first; ones CMC no longer tracks are kept but
            // flagged so the UI can label them (adding one on purpose leads
            // straight to the "Replace with …" successor flow).
            return r.data
                .map { SearchResult(token: Token(id: $0.id, symbol: $0.symbol, name: $0.name, slug: $0.slug),
                                    isActive: $0.is_active != 0) }
                .sorted { $0.isActive && !$1.isActive }
        } catch {
            throw CMCError.decoding(error)
        }
    }

    // MARK: - Latest quotes

    func quotes(for ids: [Int]) async throws -> QuotesResult {
        guard !ids.isEmpty else { return QuotesResult(quotes: [:], inactiveIds: []) }
        let data = try await get(
            "/v2/cryptocurrency/quotes/latest",
            query: [
                ("id", ids.map(String.init).joined(separator: ",")),
                ("convert", "USD"),
            ]
        )
        // v2 returns: data: { "1": { id, is_active, quote: { USD: { price, percent_change_* } } }, ... }
        //
        // Every numeric field is optional on purpose: a token that CMC has
        // stopped tracking (e.g. MATIC after the POL migration) comes back
        // with is_active = 0 and price = null. One such token must not sink
        // the whole refresh — it's simply left out of the result, and its row
        // shows "—".
        struct Response: Decodable {
            struct Item: Decodable {
                struct QuoteWrap: Decodable {
                    struct USD: Decodable {
                        let price: Double?
                        let percent_change_1h: Double?
                        let percent_change_24h: Double?
                        let percent_change_7d: Double?
                        let percent_change_30d: Double?
                        let percent_change_90d: Double?
                    }
                    let USD: USD?
                }
                let id: Int
                let is_active: Int?
                let quote: QuoteWrap?
            }
            let data: [String: Item]
        }
        do {
            let r = try JSONDecoder().decode(Response.self, from: data)
            var out: [Int: Quote] = [:]
            var inactive = Set<Int>()
            for (_, item) in r.data {
                guard let u = item.quote?.USD, let price = u.price, price.isFinite, item.is_active != 0 else {
                    inactive.insert(item.id)
                    continue
                }
                out[item.id] = Quote(
                    price: price,
                    percentChange1h: u.percent_change_1h,
                    percentChange24h: u.percent_change_24h ?? 0,
                    percentChange7d: u.percent_change_7d,
                    percentChange30d: u.percent_change_30d,
                    percentChange90d: u.percent_change_90d
                )
            }
            return QuotesResult(quotes: out, inactiveIds: inactive)
        } catch {
            throw CMCError.decoding(error)
        }
    }

    // MARK: - Token info (notice + successor for no-longer-tracked tokens)

    struct InfoItem {
        let token: Token
        let notice: String?        // raw markdown from CMC (may be empty)
    }

    /// `/v2/cryptocurrency/info` — free tier, 1 credit per call. Only the
    /// fields we need; `aux=notice` keeps the payload small.
    private func infoRaw(query: [(String, String)]) async throws -> [Int: InfoItem] {
        let data = try await get("/v2/cryptocurrency/info", query: query + [("aux", "notice")])
        struct Response: Decodable {
            struct Item: Decodable {
                let id: Int
                let symbol: String
                let name: String
                let slug: String
                let notice: String?
            }
            let data: [String: Item]
        }
        do {
            let r = try JSONDecoder().decode(Response.self, from: data)
            var out: [Int: InfoItem] = [:]
            for (_, it) in r.data {
                out[it.id] = InfoItem(
                    token: Token(id: it.id, symbol: it.symbol, name: it.name, slug: it.slug),
                    notice: it.notice
                )
            }
            return out
        } catch {
            throw CMCError.decoding(error)
        }
    }

    func info(ids: [Int]) async throws -> [Int: InfoItem] {
        guard !ids.isEmpty else { return [:] }
        return try await infoRaw(query: [("id", ids.map(String.init).joined(separator: ","))])
    }

    func info(slug: String) async throws -> InfoItem? {
        try await infoRaw(query: [("slug", slug)]).values.first
    }

    /// The successor coin's slug, if the notice links to one — CMC's
    /// migration notices link the new coin as
    /// `https://coinmarketcap.com/currencies/<slug>/`.
    static func successorSlug(in notice: String) -> String? {
        let pattern = #"coinmarketcap\.com/currencies/([a-z0-9-]+)/?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: notice, range: NSRange(notice.startIndex..., in: notice)),
              let r = Range(m.range(at: 1), in: notice) else { return nil }
        return String(notice[r])
    }

    /// Markdown links → their text, whitespace collapsed, trimmed to the
    /// first sentence or two so it fits under a row.
    static func plainNotice(_ notice: String) -> String? {
        var text = notice
        if let re = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]*\)"#) {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        text = text.replacingOccurrences(of: "*", with: "")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let sentences = text.components(separatedBy: ". ")
        var out = sentences[0]
        if sentences.count > 1, out.count < 90 { out += ". " + sentences[1] }
        if !out.hasSuffix(".") { out += "." }
        return out.count > 220 ? String(out.prefix(217)) + "…" : out
    }

    // Note: CMC's historical OHLCV endpoint requires the paid Hobbyist plan.
    // Removed — we use Binance (primary) and CoinGecko (fallback) for charts.
    // CMCClient now only serves token search + current quotes (free tier).
}
