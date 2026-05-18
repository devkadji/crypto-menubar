import Foundation

// Binance's public klines endpoint:
//   GET https://api.binance.com/api/v3/klines?symbol=BTCUSDT&interval=1h&limit=168
// No key, no rate-limit issues for our usage (~1200 weight/min IP limit, each
// klines call is weight 2 → effectively unbounded for a personal app).
//
// Pair format: <TICKER>USDT. If the pair doesn't exist Binance returns 400
// with `{"code":-1121,"msg":"Invalid symbol."}` — we treat that as
// "symbolNotFound" so the caller can fall back to another source.

enum BinanceError: Error, LocalizedError {
    case http(Int, String)
    case symbolNotFound
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "Binance \(code): \(String(msg.prefix(150)))"
        case .symbolNotFound: return "Symbol not listed on Binance"
        case .decoding(let e): return "Binance decoding: \(e.localizedDescription)"
        }
    }
}

actor BinanceClient {
    private let baseURL = URL(string: "https://api.binance.com/api/v3")!

    func history(symbol: String, timeframe: Timeframe) async throws -> [PricePoint] {
        let interval = self.interval(for: timeframe)
        let limit = self.limit(for: timeframe)
        let pair = "\(symbol.uppercased())USDT"

        var comps = URLComponents(
            url: baseURL.appendingPathComponent("klines"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "symbol", value: pair),
            URLQueryItem(name: "interval", value: interval),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw BinanceError.http(0, "no response")
        }
        if http.statusCode == 400 {
            // Invalid symbol — let caller fall back to another provider.
            throw BinanceError.symbolNotFound
        }
        if !(200..<300).contains(http.statusCode) {
            throw BinanceError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        // [[openTime(Int64 ms), "open", "high", "low", "close", ...], ...]
        let points: [PricePoint]
        do {
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
                throw BinanceError.decoding(
                    NSError(domain: "binance", code: 0, userInfo: [NSLocalizedDescriptionKey: "unexpected shape"])
                )
            }
            points = arr.compactMap { candle in
                guard candle.count >= 5 else { return nil }
                let openTimeMs: Double
                if let d = candle[0] as? Double { openTimeMs = d }
                else if let i = candle[0] as? Int { openTimeMs = Double(i) }
                else if let n = candle[0] as? NSNumber { openTimeMs = n.doubleValue }
                else { return nil }

                guard let closeStr = candle[4] as? String, let close = Double(closeStr) else {
                    return nil
                }
                return PricePoint(
                    timestamp: Date(timeIntervalSince1970: openTimeMs / 1000),
                    price: close
                )
            }
        } catch {
            throw BinanceError.decoding(error)
        }

        // Sanity check: if the most-recent candle is older than 48h, the symbol
        // has likely been delisted from Binance (e.g. XMR was removed in Feb 2024
        // for compliance reasons, but /klines still returns the last available
        // data). Treat as "not on Binance" so the caller falls back to CoinGecko.
        if let last = points.last, Date().timeIntervalSince(last.timestamp) > 48 * 3600 {
            throw BinanceError.symbolNotFound
        }
        return points
    }

    // Tune interval per timeframe so each chart has 90–180 candles — smooth
    // line, not too dense.
    private func interval(for tf: Timeframe) -> String {
        switch tf {
        case .d7:   return "1h"
        case .d30:  return "4h"
        case .d90:  return "1d"
        case .d365: return "1d"
        }
    }

    private func limit(for tf: Timeframe) -> Int {
        switch tf {
        case .d7:   return 168   // 7 × 24h
        case .d30:  return 180   // 30 × 6 four-hour candles
        case .d90:  return 90    // daily
        case .d365: return 365   // daily
        }
    }
}
