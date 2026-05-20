# Changelog

## v2.1 — 2026-05-20

- **Charts auto-refresh.** Each expanded chart now re-fetches its history on the
  configured refresh interval (default 5 min) via its own background timer —
  no need to switch timeframes to get fresh data. A `↻ HH:mm` stamp in the
  chart caption shows when it last polled.
- **Mouse zoom.** Hold ⌥ Option and scroll the mouse wheel over a chart to zoom
  the X axis. Trackpad pinch-to-zoom continues to work unchanged.

## v2.0 — 2026-05-19

- **Extended chart timeframes** — 1H / 24H / 7D / 30D / 90D / 1Y / ALL.
- **Pinch-to-zoom** the chart X axis (trackpad); horizontal drag to pan when
  zoomed; double-click resets zoom.
- **Per-chart data-source + freshness indicator** — shows Binance / CoinGecko
  with a color-coded dot (🟢 ≤2h · 🟡 ≤24h · 🔴 >24h).
- **Binance as primary chart source** — no practical rate limits; CoinGecko
  fallback for tokens not on Binance or delisted from it.
- **Y-axis fit-to-data** — charts zoom to the actual price range instead of
  always starting at zero.
- **Price alerts** — per-token high/low thresholds, native macOS notifications
  when crossed.
- **Configurable price-refresh interval** (Settings).
- **Resizable popover-style window** — drag any edge, size persists across
  launches, click outside to dismiss.
- Clean public bundle identifier (`io.github.devkadji.cryptomenubar`).
