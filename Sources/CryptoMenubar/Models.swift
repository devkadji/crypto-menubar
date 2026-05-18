import Foundation

struct Token: Identifiable, Codable, Hashable {
    let id: Int            // CoinMarketCap id
    let symbol: String     // e.g. "BTC"
    let name: String       // e.g. "Bitcoin"
    let slug: String       // e.g. "bitcoin"
}

struct Quote: Equatable {
    let price: Double
    let percentChange24h: Double
}

struct PricePoint: Identifiable {
    var id: Date { timestamp }
    let timestamp: Date
    let price: Double
}

enum ChartSource: String, Codable {
    case binance
    case coingecko

    var label: String {
        switch self {
        case .binance:   return "Binance"
        case .coingecko: return "CoinGecko"
        }
    }
}

struct HistoryResult {
    let points: [PricePoint]
    let source: ChartSource
}

struct PriceAlert: Codable, Equatable {
    var high: Double?           // fire when price ≥ high
    var low: Double?            // fire when price ≤ low
    var highArmed: Bool = true  // false after firing; re-arms when price falls back below
    var lowArmed: Bool = true   // false after firing; re-arms when price rises back above

    var isActive: Bool { high != nil || low != nil }
}

enum Timeframe: String, CaseIterable, Identifiable {
    case h1 = "1H"
    case h24 = "24H"
    case d7 = "7D"
    case d30 = "30D"
    case d90 = "90D"
    case d365 = "1Y"
    case all = "ALL"

    var id: String { rawValue }

    // ---- Binance /klines parameters ----
    // Interval × limit ≈ the time span. 60–180 candles per chart keeps it smooth.
    var binanceInterval: String {
        switch self {
        case .h1:   return "1m"
        case .h24:  return "15m"
        case .d7:   return "1h"
        case .d30:  return "4h"
        case .d90:  return "1d"
        case .d365: return "1d"
        case .all:  return "1w"
        }
    }
    var binanceLimit: Int {
        switch self {
        case .h1:   return 60      // 60 × 1m
        case .h24:  return 96      // 96 × 15m = 24h
        case .d7:   return 168     // 168 × 1h
        case .d30:  return 180     // 180 × 4h
        case .d90:  return 90      // 90 × 1d
        case .d365: return 365     // 365 × 1d
        case .all:  return 1000    // Binance per-request max (~19y weekly)
        }
    }

    // ---- CoinGecko /coins/{id}/market_chart parameter ----
    // The free API returns 5-min granularity for days=1, hourly for 2..90,
    // daily for >90, and "max" returns all available history (daily).
    var coinGeckoDaysParam: String {
        switch self {
        case .h1, .h24: return "1"
        case .d7:       return "7"
        case .d30:      return "30"
        case .d90:      return "90"
        case .d365:     return "365"
        case .all:      return "max"
        }
    }

    // For 1H we ask CoinGecko for the whole last day (5-min granularity) and
    // slice the most-recent hour client-side — there's no sub-day param.
    var trimToHours: Int? {
        self == .h1 ? 1 : nil
    }

    // How old the most-recent candle is allowed to be before we treat the
    // source as stale (delisted symbol, exchange outage, etc.) and fall back.
    // Scaled to the candle interval used for this timeframe.
    var maxStaleness: TimeInterval {
        switch self {
        case .h1:           return 10 * 60        // 10 min  (1m candles)
        case .h24:          return 60 * 60        // 1 hr    (15m candles)
        case .d7:           return 6 * 3600       // 6 hr    (1h candles)
        case .d30:          return 24 * 3600      // 1 day   (4h candles)
        case .d90, .d365:   return 3 * 86400      // 3 days  (daily)
        case .all:          return 30 * 86400     // 30 days (weekly)
        }
    }
}
