# Changelog

## v2.4 — 2026-08-27

- **Drag-and-drop reordering** in the watchlist and the portfolio. Grab a
  row anywhere outside a button / the amount field and drop it onto another
  token's block (its chart counts too); the list re-flows live under the
  cursor. Context menu adds "Move to top / bottom". Manual order persists —
  the watchlist in UserDefaults as before, the portfolio inside the
  encrypted file.
- **Sort menu** (↕ in each header): Manual · Name · Symbol · Price ·
  % change, plus **Value** in the portfolio. Live sorts re-order as quotes
  refresh; ties and missing quotes keep their manual order. Dragging a row
  while a sort is active bakes the shown order in and switches back to
  Manual, so the drop never snaps back.
- The menubar ticker now shows the **top token as displayed** — sorting by
  price puts your biggest coin in the menubar.
- **Window height you can actually control.** The main window still fits
  its content when charts expand/collapse or tokens come and go (growing
  down to the bottom of the screen, then scrolling) — but a manual resize
  is now respected instead of snapped back. Drag it shorter and that height
  becomes a persistent cap (the list scrolls; later expansions grow only up
  to it). Drag it to its full content height or beyond to clear the cap and
  return to pure auto-fit. Also fixed the root cause of the permanent
  scrollbar + cropped last row: the invisible titlebar's safe-area inset was
  pushing the content down ~28 pt without being counted in the fitted
  height. The screen-bottom limit is now taken from the
  display under the window's top edge, so on multi-display setups the
  window no longer runs off the bottom of a shorter screen.
- **Portfolio window fits its content too** — same rules: grows as holdings
  are added or their charts expanded (down to the screen bottom), shrinks
  when they collapse, a manual shrink sticks as a cap, dragging to full
  content height returns to auto-fit.


## v2.3 — 2026-08-27

- **Timeframe-labelled % change.** The figure under each price now reads
  `7D +2.34%` instead of a bare `+2.34%`, and it follows the token's chart
  timeframe (persisted per token, default 30D). While the chart is expanded
  the number is derived from the drawn history (first → last point, so it
  matches the curve exactly); while collapsed it uses CoinMarketCap's own
  1H / 24H / 7D / 30D / 90D figure. 1Y / ALL show `—` until the chart is
  expanded. Hover the badge for the source.
- **Portfolio tracker.** New 🥧 button in the header opens a separate
  window: add tokens by ticker, enter how much you hold, and see the total
  value, its change over the selected timeframe, and a total-value chart
  (same 1H…ALL picker, same pinch/⌥-scroll zoom, pan and hover as the token
  charts). Each holding row has an inline-editable amount, live value,
  share of the total, and a collapsible chart of that holding's value
  (amount × price) on the same time grid. Each expanded holding also has
  its own timeframe picker: the top picker sets every chart, a holding's
  picker overrides just that chart (and its row's % badge) until the top
  picker is changed again. The 👁 toggle masks amounts, values, share,
  chart Y-axes and captions. Holdings that aren't on Binance
  fall back to CoinGecko like everything else; a holding with no history
  at all is flagged and left out of the chart (but still counted in the
  total).
- **Encrypted portfolio storage.** Holdings are saved to
  `~/Library/Application Support/CryptoMenubar/portfolio.v1.enc`, sealed
  with AES-256-GCM. The key lives only in your login Keychain
  ("Crypto Menubar — portfolio encryption key"), so the file on disk is
  opaque to anything that can't get through the Keychain prompt. The file
  is only read when the Portfolio window is opened. An 👁 toggle in the
  window masks all amounts/values for screen-sharing.
- Internals: the interactive chart is now a reusable `InteractiveLineChart`
  view (token charts and portfolio charts share one implementation).
  `Quote` carries all of CMC's percent-change windows; the quote refresh
  covers watchlist + portfolio tokens in a single CMC call.


## v2.2 — 2026-05-27

- **Cursor-anchored pinch zoom.** Pinching now keeps the date under the cursor
  in place — content expands or contracts symmetrically around that point —
  instead of always anchoring to the right edge of the chart.
- **Drag-to-pan within zoomed charts.** Click-and-drag (or three-finger drag
  via macOS Accessibility) horizontally on any chart pans the visible window.
  Movement is clamped at the data boundaries. The chart no longer accidentally
  drags the whole popover window when you grab it — window movement is now
  only via the titlebar strip at the top.
- **Y-axis fit + hover snap follow the visible window.** Previously, when you
  panned left into older data, the Y-axis kept its scale based on the rightmost
  candles (so the curve clipped) and the hover tooltip silently failed for
  cursor positions outside that range. Both now track exactly what's drawn.

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
