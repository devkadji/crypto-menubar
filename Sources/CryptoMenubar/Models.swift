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
    case d7 = "7D"
    case d30 = "30D"
    case d90 = "90D"
    case d365 = "1Y"

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .d7: return 7
        case .d30: return 30
        case .d90: return 90
        case .d365: return 365
        }
    }
}
