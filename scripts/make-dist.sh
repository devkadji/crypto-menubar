#!/usr/bin/env bash
# Build the .app, then assemble a friend-ready distribution zip:
#
#   CryptoMenubar-1.0.zip
#     ├── CryptoMenubar.app           (universal: arm64 + x86_64)
#     ├── install.command             (right-click → Open; handles quarantine)
#     └── README.txt                  (plain-English instructions)
#
# Usage:  ./scripts/make-dist.sh

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.4"
DIST_NAME="CryptoMenubar-${VERSION}"
DIST_DIR="dist/${DIST_NAME}"

echo "==> Building universal .app"
./scripts/make-app.sh universal

echo "==> Assembling ${DIST_DIR}"
rm -rf "dist"
mkdir -p "$DIST_DIR"

# Copy the app
cp -R CryptoMenubar.app "$DIST_DIR/"

# Copy install.command and make executable
cp scripts/install.command.tmpl "$DIST_DIR/install.command"
chmod +x "$DIST_DIR/install.command"

# Write a friend-facing README
cat > "$DIST_DIR/README.txt" <<'EOF'
CryptoMenubar
=============

A tiny macOS menubar app showing live crypto prices, charts, and
configurable price alerts. Stays out of your Dock — lives only in the
menubar.

REQUIREMENTS
------------
- macOS 14 (Sonoma) or later
- Apple Silicon OR Intel Mac (universal binary, both work)

INSTALL (the easy way)
----------------------
1. Right-click "install.command" → Open
   (macOS will ask once "are you sure?" — click Open.)
2. The installer copies the app to /Applications, removes the macOS
   quarantine flag so Gatekeeper stops complaining, and launches it.
3. Look for the ₿ icon in your menubar.

INSTALL (if you'd rather drag manually)
---------------------------------------
1. Drag CryptoMenubar.app to /Applications/
2. Open Terminal and run:
       xattr -dr com.apple.quarantine /Applications/CryptoMenubar.app
3. Double-click CryptoMenubar.app.

FIRST-RUN SETUP
---------------
- Click the menubar icon → ⚙ Settings.
- Paste a free CoinMarketCap API key. Get one at:
       https://coinmarketcap.com/api
  (Basic plan, free, 1-minute signup, no credit card.)
- (Optional) Paste a free CoinGecko Demo key for higher chart rate
  limits. Get one at: https://www.coingecko.com/en/api/pricing

USING IT
--------
- Type a ticker (ETH, SOL, BNB, ...) in the search field to add tokens.
- Each token row shows current price + % change, labelled with the
  timeframe it refers to (e.g. "7D +2.3%"). It follows the chart's
  timeframe.
- Click the chevron to expand/collapse a chart (1H / 24H / 7D / 30D /
  90D / 1Y / ALL). Pinch or Option+scroll to zoom, drag to pan.
- Hover the chart to see exact price + date.
- Click the 🔔 bell on any row to set price alerts (above / below).
  When the price crosses a threshold, you get a macOS notification.
- Drag rows to rearrange them, or use the up/down-arrows button to sort
  by name, symbol, price or % change. The menubar shows the top token.
- Windows fit their content. Drag one shorter and it stays that size
  (the list scrolls); drag it to full height to go back to auto-fit.
- Click the pie-chart button for the Portfolio tracker: add tokens by
  ticker, enter how much you hold, and see total value + charts.
  Holdings are stored encrypted on your Mac (key in your login
  Keychain). macOS asks once "CryptoMenubar wants to use your
  confidential information" — click Always Allow.

WHY THE "UNIDENTIFIED DEVELOPER" WARNING?
-----------------------------------------
This app is shared person-to-person, not through the App Store, and isn't
notarized by Apple. The install.command script removes the quarantine
attribute, which is why the warning goes away after running it. Source
code: ask the sender — it's a small SwiftUI project.

EOF

echo "==> Zipping"
cd dist
zip -r -q "${DIST_NAME}.zip" "${DIST_NAME}"
cd ..

echo
echo "✅ Distribution ready:"
echo "    $(pwd)/dist/${DIST_NAME}.zip"
echo
echo "Send this zip to your friends. They:"
echo "  1. Unzip it"
echo "  2. Right-click install.command → Open  (one-time Gatekeeper confirmation)"
echo "  3. Done — app launches, ₿ appears in menubar"
