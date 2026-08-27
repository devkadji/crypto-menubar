import Foundation

struct Token: Identifiable, Codable, Hashable {
    let id: Int            // CoinMarketCap id
    let symbol: String     // e.g. "BTC"
    let name: String       // e.g. "Bitcoin"
    let slug: String       // e.g. "bitcoin"
}

struct Quote: Equatable {
    let price: Double
    // CMC ships several look-back windows in the same quote. 24h is always
    // present; the others are optional in the API (nil for very new listings).
    let percentChange1h: Double?
    let percentChange24h: Double
    let percentChange7d: Double?
    let percentChange30d: Double?
    let percentChange90d: Double?

    init(price: Double,
         percentChange1h: Double? = nil,
         percentChange24h: Double,
         percentChange7d: Double? = nil,
         percentChange30d: Double? = nil,
         percentChange90d: Double? = nil) {
        self.price = price
        self.percentChange1h = percentChange1h
        self.percentChange24h = percentChange24h
        self.percentChange7d = percentChange7d
        self.percentChange30d = percentChange30d
        self.percentChange90d = percentChange90d
    }

    /// CMC's own percent change for a chart timeframe, when it has one.
    /// 1Y / ALL have no CMC equivalent — those are only available from chart
    /// history (see `ChartStats`).
    func percentChange(for tf: Timeframe) -> Double? {
        switch tf {
        case .h1:   return percentChange1h
        case .h24:  return percentChange24h
        case .d7:   return percentChange7d
        case .d30:  return percentChange30d
        case .d90:  return percentChange90d
        case .d365, .all: return nil
        }
    }
}

/// First/last price of the history currently drawn in a token's expanded
/// chart. Published by ChartSection so the row's % badge can show the change
/// over exactly what the chart shows.
struct ChartStats: Equatable {
    let timeframe: Timeframe
    let firstPrice: Double
    let lastPrice: Double
    let source: ChartSource

    var percentChange: Double? {
        guard firstPrice > 0 else { return nil }
        return (lastPrice / firstPrice - 1) * 100
    }
}

/// A % change plus where it came from — shown under the price in each row.
struct PriceChange: Equatable {
    enum Source: Equatable {
        case chart(ChartSource)   // derived from the drawn history (first → last point)
        case cmc                  // CoinMarketCap's percent_change_* field

        var label: String {
            switch self {
            case .chart(let s): return "\(s.label) chart data"
            case .cmc:          return "CoinMarketCap"
            }
        }
    }
    let timeframe: Timeframe
    let percent: Double
    let source: Source

    /// Builds a change from a drawn series if one is available for `timeframe`,
    /// otherwise from CMC's matching field. nil when neither is available
    /// (e.g. 1Y/ALL with the chart collapsed).
    static func resolve(timeframe: Timeframe,
                        series: [PricePoint]?,
                        seriesSource: ChartSource?,
                        quote: Quote?) -> PriceChange? {
        if let series, let f = series.first, let l = series.last, f.price > 0 {
            return PriceChange(timeframe: timeframe,
                               percent: (l.price / f.price - 1) * 100,
                               source: .chart(seriesSource ?? .binance))
        }
        if let q = quote, let p = q.percentChange(for: timeframe) {
            return PriceChange(timeframe: timeframe, percent: p, source: .cmc)
        }
        return nil
    }
}

func formatPercent(_ p: Double) -> String {
    String(format: "%@%.2f%%", p >= 0 ? "+" : "", p)
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

enum Timeframe: String, CaseIterable, Identifiable, Codable {
    case h1 = "1H"
    case h24 = "24H"
    case d7 = "7D"
    case d30 = "30D"
    case d90 = "90D"
    case d365 = "1Y"
    case all = "ALL"

    var id: String { rawValue }

    /// Human wording for tooltips: "change over the last 7 days".
    var changeDescription: String {
        switch self {
        case .h1:   return "last hour"
        case .h24:  return "last 24 hours"
        case .d7:   return "last 7 days"
        case .d30:  return "last 30 days"
        case .d90:  return "last 90 days"
        case .d365: return "last year"
        case .all:  return "entire available history"
        }
    }

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

/// Row ordering for the watchlist and the portfolio. `manual` = the order
/// the user arranged by drag-and-drop; the others re-sort live as quotes
/// change (name/symbol ascending, numeric ones descending).
enum ListSort: String, CaseIterable, Identifiable, Codable {
    case manual, name, symbol, price, change, value

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Manual (drag to reorder)"
        case .name:   return "Name A→Z"
        case .symbol: return "Symbol A→Z"
        case .price:  return "Price, high → low"
        case .change: return "% change, high → low"
        case .value:  return "Value, high → low"
        }
    }

    /// Stable sort — ties (and missing numbers) keep their manual order;
    /// items without a quote sink to the bottom for numeric sorts.
    func apply<T>(_ items: [T],
                  name: (T) -> String,
                  symbol: (T) -> String,
                  price: (T) -> Double?,
                  change: (T) -> Double?,
                  value: (T) -> Double?) -> [T] {
        guard self != .manual else { return items }
        let indexed = Array(items.enumerated())
        func numeric(_ key: (T) -> Double?) -> [T] {
            indexed.sorted { a, b in
                let x = key(a.element), y = key(b.element)
                switch (x, y) {
                case let (x?, y?) where x != y: return x > y
                case (.some, .none): return true
                case (.none, .some): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
        }
        func text(_ key: (T) -> String) -> [T] {
            indexed.sorted { a, b in
                let c = key(a.element).localizedCaseInsensitiveCompare(key(b.element))
                return c == .orderedSame ? a.offset < b.offset : c == .orderedAscending
            }.map(\.element)
        }
        switch self {
        case .manual: return items
        case .name:   return text(name)
        case .symbol: return text(symbol)
        case .price:  return numeric(price)
        case .change: return numeric(change)
        case .value:  return numeric(value)
        }
    }
}
