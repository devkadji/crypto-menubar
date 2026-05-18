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

    func search(symbol: String) async throws -> [Token] {
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
            }
            let data: [Item]
        }
        do {
            let r = try JSONDecoder().decode(Response.self, from: data)
            return r.data.map { Token(id: $0.id, symbol: $0.symbol, name: $0.name, slug: $0.slug) }
        } catch {
            throw CMCError.decoding(error)
        }
    }

    // MARK: - Latest quotes

    func quotes(for ids: [Int]) async throws -> [Int: Quote] {
        guard !ids.isEmpty else { return [:] }
        let data = try await get(
            "/v2/cryptocurrency/quotes/latest",
            query: [
                ("id", ids.map(String.init).joined(separator: ",")),
                ("convert", "USD"),
            ]
        )
        // v2 returns: data: { "1": { id, quote: { USD: { price, percent_change_24h } } }, ... }
        struct Response: Decodable {
            struct Item: Decodable {
                struct QuoteWrap: Decodable {
                    struct USD: Decodable {
                        let price: Double
                        let percent_change_24h: Double?
                    }
                    let USD: USD
                }
                let id: Int
                let quote: QuoteWrap
            }
            let data: [String: Item]
        }
        do {
            let r = try JSONDecoder().decode(Response.self, from: data)
            var out: [Int: Quote] = [:]
            for (_, item) in r.data {
                out[item.id] = Quote(
                    price: item.quote.USD.price,
                    percentChange24h: item.quote.USD.percent_change_24h ?? 0
                )
            }
            return out
        } catch {
            throw CMCError.decoding(error)
        }
    }

    // Note: CMC's historical OHLCV endpoint requires the paid Hobbyist plan.
    // Removed — we use Binance (primary) and CoinGecko (fallback) for charts.
    // CMCClient now only serves token search + current quotes (free tier).
}
