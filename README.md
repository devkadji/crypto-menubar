# Crypto Menubar

Native macOS menubar app that shows live crypto prices, interactive charts, and
threshold-based price alerts — without taking up a Dock icon or main window.

> Built in SwiftUI + AppKit · macOS 14+ · universal (Apple Silicon + Intel)

## Features

- **Menubar ticker** — your top token's symbol + live price always visible
- **Searchable watchlist** — type a ticker (e.g. `ETH`), pick from results, done
- **Per-token charts** — inline 7D / 30D / 90D / 1Y line charts, hover for
  exact date + price near the cursor
- **Expand / collapse charts individually** — window auto-fits the natural
  content height (grows on expand up to screen height, shrinks on collapse)
- **Price alerts** — set high / low thresholds per token; the bot fires a
  macOS notification when the price crosses, then re-arms once it moves back
- **Configurable refresh interval** — 1 / 5 / 15 / 30 min, with CMC usage notes
- **Data-source transparency** — every chart shows which provider it came from
  (Binance / CoinGecko) with a freshness dot (🟢 ≤2h, 🟡 ≤24h, 🔴 >24h)
- **Resizable popover-style window** — drag any edge; size persists across
  launches; click outside to dismiss
- **Dark mode** — adapts to system appearance automatically

## Data sources

| What | Source | Why |
|---|---|---|
| Token search + name resolution | **CoinMarketCap** (free Basic plan) | Authoritative ticker → id/name mapping, market-cap ranked |
| Current prices + 24h % change | **CoinMarketCap** | Reliable for any listed asset |
| Historical charts (primary) | **Binance** public `klines` API | No key, no rate limits in practice |
| Historical charts (fallback) | **CoinGecko** public API (optional Demo key) | Used when a token isn't on Binance OR Binance's data is stale (>48h old → e.g. XMR after their 2024 delisting) |

CMC and CoinGecko Demo keys are both free and 1-minute signups. Only CMC is
required; CoinGecko works key-less but rate-limits more aggressively.

## Build & run

```bash
git clone <this-repo>
cd crypto-menubar
open Package.swift    # Xcode 16.x opens it as a project; ⌘R to run
```

Or from the command line:

```bash
swift run
```

First launch: click the menubar icon → ⚙ Settings → paste a CoinMarketCap key
from <https://coinmarketcap.com/api> (Basic plan, free).

## Build a distributable `.app`

```bash
./scripts/make-app.sh            # universal binary (arm64 + x86_64)
./scripts/make-app.sh native     # only the host arch (faster build)
```

Produces `CryptoMenubar.app` in the project root, ad-hoc signed so it launches
without a Gatekeeper prompt on the build machine.

## Build a shareable distribution

```bash
./scripts/make-dist.sh
```

Produces `dist/CryptoMenubar-<version>.zip` containing:

- The universal `.app` bundle
- `install.command` — a one-double-click installer that moves the app to
  `/Applications`, strips the macOS quarantine flag, and launches it
- `README.txt` — friend-facing setup instructions

Hand the zip to a friend; they right-click `install.command` → Open, and
they're running.

## Project layout

```
crypto-menubar/
├── Package.swift                       # SwiftPM manifest (macOS 14+ exec)
├── Sources/CryptoMenubar/
│   ├── CryptoMenubarApp.swift          # @main + AppDelegate boot
│   ├── StatusBarController.swift       # NSStatusItem + custom resizable NSWindow
│   ├── ContentView.swift               # All SwiftUI views (rows, charts, sheets)
│   ├── TokenStore.swift                # @ObservableObject state + persistence
│   ├── CMCClient.swift                 # CoinMarketCap REST client
│   ├── BinanceClient.swift             # Binance klines (primary chart source)
│   ├── CoinGeckoClient.swift           # Fallback charts + Demo-key support + cache
│   ├── AlertManager.swift              # UNUserNotificationCenter wrapper
│   └── Models.swift                    # Token, Quote, PricePoint, Timeframe, etc.
├── scripts/
│   ├── make-app.sh                     # Build universal .app
│   ├── make-dist.sh                    # Build .app + zip for distribution
│   └── install.command.tmpl            # Template installer included in dist zip
└── README.md
```

## Persistence

State lives in `UserDefaults` under bundle id `io.github.devkadji.cryptomenubar`:

| Key | What |
|---|---|
| `tokens.v1` | Watchlist (Token JSON array) |
| `expandedTokenIds.v1` | Which token charts are expanded |
| `alerts.v1` | Per-token high/low thresholds + armed state |
| `cmcAPIKey.v1`, `coingeckoDemoKey.v1` | API keys (move to Keychain for hardened distribution) |
| `refreshInterval.v1`, `requestThrottle.v1` | Settings sliders |
| `coingeckoIdCache.v1`, `coingeckoHistoryCache.v1` | CMC↔CoinGecko slug mapping + chart cache |
| `NSWindow Frame CryptoMenubarMainWindow` | Window size (AppKit autosave) |

## Restrictions

- **Apple Silicon + Intel** — universal binary works on both
- **macOS 14.0 (Sonoma) or later** — Swift Charts + `MenuBarExtra`-free
  architecture rely on Ventura/Sonoma APIs
- **Not sandboxed, not notarized** — distributed person-to-person via the zip
  workflow above. For App Store / wider distribution you'd need a $99/yr Apple
  Developer ID + a notarization step

## Settings cheat sheet

- **Price refresh interval** — every 5 min by default (≈8.6 K CMC calls/month,
  fits the 10 K free tier). Tighten to 1 min if you're on a paid plan.
- **CoinGecko Demo key** — optional. Raises chart rate limit ~3×.
- **Chart request throttle** — only applies when the CoinGecko fallback kicks
  in. `Off` is fine with a Demo key; `1.5 s` is the safe pick without one.

## License

MIT.
