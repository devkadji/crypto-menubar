# Crypto Menubar

Native macOS menubar app that shows live crypto prices, interactive charts, and
threshold-based price alerts — without taking up a Dock icon or main window.

> Built in SwiftUI + AppKit · macOS 14+ · universal (Apple Silicon + Intel)

## Features

- **Menubar ticker** — your top token's symbol + live price always visible
- **Searchable watchlist** — type a ticker (e.g. `ETH`), pick from results, done
- **Rearrange & sort** — drag rows to reorder (watchlist and portfolio), or
  sort by name / symbol / price / % change (/ value in the portfolio) from
  the ↕ menu; the menubar shows whichever token is on top
- **Per-token charts** — inline 1H / 24H / 7D / 30D / 90D / 1Y / ALL line
  charts, hover for exact date + price near the cursor
- **Timeframe-labelled % change** — `7D +2.34%` under every price, following
  that token's chart timeframe (chart-derived when expanded, CMC's figure when
  collapsed)
- **Portfolio tracker** — separate window with ticker search, editable
  holdings, total value + change over the selected timeframe, a total-value
  chart and collapsible per-holding value charts; holdings are stored
  AES-256-GCM encrypted with the key in your login Keychain
- **Expand / collapse charts individually** — window auto-fits the natural
  content height (grows on expand down to the screen bottom, shrinks on
  collapse). Drag it shorter and that height sticks as a cap (list scrolls);
  drag it to full content height to go back to auto-fit
- **Renamed / delisted tokens** — a coin CoinMarketCap stops tracking gets a
  ⚠️ "not tracked" badge plus CMC's own notice; if the notice names a
  successor (MATIC → POL), one click replaces it in the watchlist and the
  portfolio
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
| Current prices + 1H/24H/7D/30D/90D % change | **CoinMarketCap** | Reliable for any listed asset |
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
│   ├── ContentView.swift               # Main-window SwiftUI views (rows, chart section, sheets)
│   ├── InteractiveLineChart.swift      # Shared zoom/pan/hover chart + % badge + caption
│   ├── PortfolioView.swift             # Portfolio window views
│   ├── TokenStore.swift                # @ObservableObject state + persistence
│   ├── PortfolioStore.swift            # Holdings, value series alignment, encrypted persistence
│   ├── SecureStore.swift               # AES-GCM + Keychain key + portfolio file IO
│   ├── Reorder.swift                   # Drag-and-drop row reordering + sort menu
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
| `chartTimeframes.v1` | Per-token chart timeframe (drives the % badge) |
| `sortOrder.v1`, `portfolioSort.v1` | Sort mode of the watchlist / portfolio (`manual` = drag order) |
| `tokenNotices.v1` | Cached CMC notices + successors for no-longer-tracked tokens (re-checked weekly) |
| `portfolioTimeframe.v1`, `portfolioHoldingTimeframes.v1`, `portfolioExpanded.v1`, `portfolioHideValues.v1` | Portfolio window UI state (timeframes, expanded rows, privacy toggle — no amounts) |
| `CryptoMenubarMainWindow.width.v1`, `CryptoMenubarMainWindow.maxHeight.v1` | Main window width; user height cap (0 = auto-fit) |
| `NSWindow Frame CryptoMenubarPortfolioWindow`, `CryptoMenubarPortfolioWindow.maxHeight.v1` | Portfolio window frame (AppKit autosave); user height cap (0 = auto-fit) |

The portfolio itself (which tokens, how much) is **not** in UserDefaults. It
is written to `~/Library/Application Support/CryptoMenubar/portfolio.v1.enc`
(mode 0600) as `"CMPF1" + AES-256-GCM(nonce ‖ ciphertext ‖ tag)`, with the
header used as additional authenticated data. The random 256-bit key is a
generic-password item in the login Keychain
(service `io.github.devkadji.cryptomenubar`, account
`portfolio-encryption-key`). The file is only read when the Portfolio window
is opened, and the key is only created on the first save.

Because the app is ad-hoc signed, the Keychain ties the key to the exact
binary that created it: after **every rebuild** the first portfolio access
shows a "CryptoMenubar wants to use your confidential information stored in
… in your keychain" dialog — click **Always Allow**. Released builds see it
once per update at most. If you click Deny, the window shows "Portfolio
locked" with a Try-again button (and a destructive Reset as last resort).

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
