import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Portfolio tracker window: total value + change over the selected timeframe,
// a value-over-time chart, a ticker search to add holdings, and the holdings
// list with editable amounts and collapsible per-token value charts.

struct PortfolioView: View {
    @EnvironmentObject var store: TokenStore
    @EnvironmentObject var portfolio: PortfolioStore
    @State private var draggingId: Int? = nil      // holding being drag-reordered

    var body: some View {
        VStack(spacing: 0) {
            switch portfolio.loadState {
            case .notLoaded:
                Spacer()
                ProgressView("Unlocking portfolio…").controlSize(.small)
                Spacer()
            case .failed(let message):
                unlockFailed(message)
            case .loaded:
                loadedBody
            }
        }
        .frame(minWidth: 520)
        .background(Color(NSColor.windowBackgroundColor))
        // Window height follows these (see StatusBarController.fitPortfolioWindow).
        .onPreferenceChange(ChromeHeightKey.self) { portfolio.measuredChromeHeight = $0 }
        .onPreferenceChange(ListHeightKey.self) { portfolio.measuredListHeight = $0 }
    }

    // MARK: - Main layout

    @ViewBuilder
    private var loadedBody: some View {
        // Chrome: everything above the scrollable holdings list. Measured so
        // the window can be sized to chrome + list exactly.
        VStack(spacing: 0) {
            PortfolioHeader()
            Divider()

            if store.apiKey.isEmpty {
                Text("Set your CoinMarketCap API key in the main window's Settings to search tokens and get live prices.")
                    .font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            } else {
                AddTokenView(
                    placeholder: "Add token to portfolio by ticker (e.g. ETH, SOL)",
                    onSelect: { portfolio.add($0) }
                )
                .padding(.vertical, 6)
            }
            Divider()

            PortfolioChart()
            Divider()

            if let err = portfolio.persistError {
                Text("⚠️ Could not save portfolio: \(err)")
                    .font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: ChromeHeightKey.self, value: geo.size.height)
        })

        ScrollView {
            Group {
                if portfolio.holdings.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "chart.pie")
                            .font(.system(size: 28)).foregroundColor(.secondary)
                        Text("No holdings yet")
                            .font(.subheadline).bold()
                        Text("Search a ticker above, then enter how much you hold. Amounts are stored encrypted on this Mac (key in your login Keychain).")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                } else {
                    VStack(spacing: 0) {
                        ForEach(portfolio.displayedHoldings) { holding in
                            HoldingRow(holding: holding, draggingId: $draggingId)
                            Divider().padding(.leading, 12)
                        }
                    }
                    .onDrop(of: [.text], isTargeted: nil) { _ in draggingId = nil; return true }
                }
            }
            // Lay the list out at its natural height so the GeometryReader
            // reports the true content height (not the visible bounds).
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
            })
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func unlockFailed(_ message: String) -> some View {
        Spacer()
        VStack(spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 30)).foregroundColor(.orange)
            Text("Portfolio locked").font(.headline)
            Text(message)
                .font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            HStack {
                Button("Try again") { portfolio.load() }
                    .keyboardShortcut(.defaultAction)
                Button("Reset portfolio…", role: .destructive) { confirmReset() }
            }
            Text("Reset deletes the encrypted file and its key. You will need to re-enter your holdings.")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(24)
        Spacer()
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset portfolio?"
        alert.informativeText = "This permanently deletes the encrypted portfolio file and its Keychain key. Your holdings cannot be recovered."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            portfolio.resetStorage()
        }
    }
}

// MARK: - Header: total value + change + privacy toggle

struct PortfolioHeader: View {
    @EnvironmentObject var store: TokenStore
    @EnvironmentObject var portfolio: PortfolioStore

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total value")
                    .font(.caption).foregroundColor(.secondary)
                Text(portfolio.hideValues ? "••••••" : (portfolio.totalValue.map(formatPrice) ?? "—"))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                changeLine
            }
            Spacer()
            HStack(spacing: 10) {
                SortMenu(selection: $portfolio.sortOrder,
                         options: [.manual, .name, .symbol, .value, .price, .change])

                Button {
                    portfolio.hideValues.toggle()
                } label: {
                    Image(systemName: portfolio.hideValues ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(portfolio.hideValues ? "Show values" : "Hide values — masks amounts, values, share and chart axes (privacy / screen-sharing)")

                Button {
                    Task { await store.refresh() }
                    portfolio.reloadSeries(silent: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh prices and chart now")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var changeLine: some View {
        let tf = portfolio.timeframe
        HStack(spacing: 4) {
            if let c = portfolio.totalChange {
                Text(portfolio.hideValues
                     ? (c.absolute >= 0 ? "+••••" : "−••••")
                     : signedMoney(c.absolute))
                    .font(.subheadline).monospacedDigit()
                    .foregroundColor(c.absolute >= 0 ? .green : .red)
                Text("(\(formatPercent(c.percent)))")
                    .font(.subheadline).monospacedDigit()
                    .foregroundColor(c.absolute >= 0 ? .green : .red)
                Text("over \(tf.rawValue)")
                    .font(.caption).foregroundColor(.secondary)
            } else if portfolio.holdings.isEmpty {
                Text("Add holdings to see the change").font(.caption).foregroundColor(.secondary)
            } else {
                Text("Change over \(tf.rawValue): —")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        let tf = portfolio.timeframe
        if let c = portfolio.totalChange {
            return "Total portfolio value change over the \(tf.changeDescription) (\(c.source.label)). Follows the chart timeframe below."
        }
        return "Change over the \(tf.changeDescription) is computed from the chart once it loads."
    }

    private func signedMoney(_ v: Double) -> String {
        (v >= 0 ? "+" : "−") + formatPrice(abs(v))
    }
}

// MARK: - Total-value chart with timeframe picker

struct PortfolioChart: View {
    @EnvironmentObject var portfolio: PortfolioStore

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Portfolio value").font(.subheadline).bold()
                Spacer()
                Picker("", selection: $portfolio.timeframe) {
                    ForEach(Timeframe.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 280)
                .labelsHidden()
                .controlSize(.small)
                .help("Sets the timeframe for the total chart, the change above, and every holding — expanded holdings can then pick their own below")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ZStack {
                if portfolio.holdings.isEmpty {
                    Text("Add holdings to see the value chart")
                        .font(.caption).foregroundColor(.secondary)
                } else if portfolio.seriesLoading && portfolio.totalSeries.isEmpty {
                    ProgressView().controlSize(.small)
                } else if portfolio.totalSeries.count >= 2 {
                    InteractiveLineChart(
                        points: portfolio.totalSeries,
                        formatValue: { portfolio.hideValues ? "••••" : formatPrice($0) },
                        hideYAxisLabels: portfolio.hideValues
                    )
                    .frame(height: 170)
                    .padding(.horizontal, 12)
                } else if portfolio.holdings.allSatisfy({ $0.amount == 0 }) {
                    Text("Enter amounts below to build the chart")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("No chart data for this timeframe")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .frame(height: 180)

            captionRow
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var captionRow: some View {
        let sources = Set(portfolio.seriesSources.values).map(\.label).sorted().joined(separator: " + ")
        let excluded = portfolio.excludedIds.compactMap { id in
            portfolio.holdings.first { $0.id == id }?.token.symbol
        }
        if !portfolio.totalSeries.isEmpty || !excluded.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SourceCaption(
                    text: "Σ amount × price · via \(sources.isEmpty ? "—" : sources)",
                    last: portfolio.totalSeries.last?.timestamp,
                    fetchedAt: portfolio.lastSeriesFetch
                )
                if !excluded.isEmpty {
                    Text("⚠️ No history for \(excluded.joined(separator: ", ")) — excluded from the chart (still counted in the total above).")
                        .font(.caption2).foregroundColor(.orange)
                        .padding(.horizontal, 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - One holding

struct HoldingRow: View {
    let holding: Holding
    @Binding var draggingId: Int?
    @EnvironmentObject var store: TokenStore
    @EnvironmentObject var portfolio: PortfolioStore

    private var isExpanded: Bool { portfolio.expandedIds.contains(holding.id) }
    private var quote: Quote? { store.quotes[holding.id] }
    private var value: Double? { portfolio.value(of: holding) }
    private var share: Double? {
        guard let v = value, let total = portfolio.totalValue, total > 0 else { return nil }
        return v / total * 100
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    portfolio.toggleExpanded(holding.id)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12, alignment: .center)
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Collapse value chart" : "Expand value chart")

                TokenIcon(cmcId: holding.id, symbol: holding.token.symbol)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(holding.token.symbol).bold()
                    Text(holding.token.name).font(.caption).foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 70, alignment: .leading)

                Spacer(minLength: 8)

                // Amount — editable inline. Commits on ⏎ or focus loss.
                VStack(alignment: .trailing, spacing: 2) {
                    AmountField(amount: holding.amount, hidden: portfolio.hideValues) { new in
                        portfolio.setAmount(new, for: holding.id)
                    }
                    Text(quote.map { "@ \(formatPrice($0.price))" } ?? "@ —")
                        .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text(portfolio.hideValues ? "••••" : (value.map(formatPrice) ?? "—"))
                        .bold().monospacedDigit()
                    HStack(spacing: 6) {
                        if let s = share, !portfolio.hideValues {
                            Text(String(format: "%.1f%%", s))
                                .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                                .help("Share of total portfolio value")
                        }
                        ChangeBadge(timeframe: portfolio.holdingTimeframe(for: holding.id),
                                    change: portfolio.change(for: holding))
                    }
                }
                .frame(minWidth: 110, alignment: .trailing)

                Button {
                    portfolio.remove(id: holding.id)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, alignment: .center)
                }
                .buttonStyle(.borderless)
                .help("Remove from portfolio")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            // Grab the row anywhere outside the amount field to rearrange.
            .reorderable(id: holding.id, draggingId: $draggingId) { dragged, onto in
                portfolio.moveHolding(id: dragged, before: onto)
            }
            .contextMenu {
                Button(isExpanded ? "Collapse chart" : "Expand chart") {
                    portfolio.toggleExpanded(holding.id)
                }
                Divider()
                Button("Move to top") { moveToEdge(top: true) }
                Button("Move to bottom") { moveToEdge(top: false) }
                Divider()
                if !store.tokens.contains(where: { $0.id == holding.id }) {
                    Button("Add to watchlist") { store.add(holding.token) }
                }
                Button("Remove from portfolio", role: .destructive) {
                    portfolio.remove(id: holding.id)
                }
            }

            if isExpanded {
                HoldingChart(holding: holding)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.04))
                    .onDrop(of: [.text], delegate: ReorderDropDelegate(
                        rowId: holding.id, draggingId: $draggingId,
                        move: { portfolio.moveHolding(id: $0, before: $1) }))
            }
        }
    }

    private func moveToEdge(top: Bool) {
        let shown = portfolio.displayedHoldings
        guard let edge = top ? shown.first : shown.last, edge.id != holding.id else { return }
        portfolio.moveHolding(id: holding.id, before: edge.id)
    }
}

// Value-over-time chart for a single holding (amount × price). Follows the
// top picker by default; its own segmented picker overrides just this chart
// (and the row's % badge) until the top picker is changed again.
struct HoldingChart: View {
    let holding: Holding
    @EnvironmentObject var portfolio: PortfolioStore

    private var timeframeBinding: Binding<Timeframe> {
        Binding(
            get: { portfolio.holdingTimeframe(for: holding.id) },
            set: { portfolio.setHoldingTimeframe($0, for: holding.id) }
        )
    }

    var body: some View {
        let id = holding.id
        let series = portfolio.chartSeries(for: id)
        let overridden = portfolio.holdingTimeframes[id] != nil
        VStack(spacing: 6) {
            HStack {
                Text("\(holding.token.symbol) value")
                    .font(.subheadline).bold()
                if overridden {
                    Text("own timeframe")
                        .font(.caption2).foregroundColor(.secondary)
                        .help("This chart uses its own timeframe. Pick the same value as the top picker to follow it again.")
                }
                Spacer()
                Picker("", selection: timeframeBinding) {
                    ForEach(Timeframe.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 280)
                .labelsHidden()
                .controlSize(.small)
                .help("Timeframe for this holding's chart and % change (overrides the top picker)")
            }
            .padding(.horizontal, 12)

            ZStack {
                if holding.amount == 0 {
                    Text("Enter an amount to chart this holding's value")
                        .font(.caption).foregroundColor(.secondary)
                } else if portfolio.chartFailed(for: id) {
                    Text("No price history available for \(holding.token.symbol)")
                        .font(.caption).foregroundColor(.orange)
                } else if series.count >= 2 {
                    InteractiveLineChart(
                        points: series,
                        formatValue: { portfolio.hideValues ? "••••" : formatPrice($0) },
                        hideYAxisLabels: portfolio.hideValues
                    )
                    .frame(height: 110)
                    .padding(.horizontal, 12)
                } else if portfolio.chartLoading(for: id) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("No data").font(.caption).foregroundColor(.secondary)
                }
            }
            .frame(height: 120)

            if series.count >= 2, let src = portfolio.chartSource(for: id) {
                SourceCaption(
                    text: "\(portfolio.hideValues ? "••••" : formatAmount(holding.amount)) \(holding.token.symbol) × price · via \(src.label)",
                    last: series.last?.timestamp,
                    fetchedAt: portfolio.lastSeriesFetch
                )
            }
        }
    }
}

// MARK: - Inline amount editor

// Commits on ⏎ or focus loss. The field is the source of truth while it has
// focus; after a commit it shows the value that was just committed (NOT the
// `amount` prop, which only catches up on the next render — re-reading it
// here is what used to blank the field and then zero the holding on the next
// focus change).
struct AmountField: View {
    let amount: Double
    let hidden: Bool
    let onCommit: (Double) -> Void
    @State private var text: String = ""
    @State private var lastCommittedText: String? = nil
    @State private var invalid = false
    @FocusState private var focused: Bool

    private static let mask = "••••"

    var body: some View {
        TextField("amount", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.body.monospacedDigit())
            .frame(width: 120)
            .focused($focused)
            .onSubmit {
                commit()
                focused = false
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(invalid ? Color.red : Color.clear, lineWidth: 1)
            )
            .help("How much you hold — press ⏎ or click elsewhere to save")
            .onAppear { showModel() }
            .onChange(of: amount) { _, _ in if !focused { showModel() } }
            .onChange(of: hidden) { _, _ in if !focused { showModel() } }
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    // Reveal the real number for editing even in privacy mode.
                    text = Self.editText(amount)
                    lastCommittedText = text
                    invalid = false
                } else {
                    commit()
                }
            }
    }

    private static func editText(_ v: Double) -> String {
        v == 0 ? "" : formatAmount(v)
    }

    private func showModel() {
        text = hidden ? Self.mask : Self.editText(amount)
        invalid = false
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == Self.mask { return }               // untouched privacy placeholder
        if trimmed == lastCommittedText { invalid = false; return }   // nothing changed
        let value: Double
        if trimmed.isEmpty {
            value = 0
        } else if let v = parseAmount(trimmed), v.isFinite, v >= 0 {
            value = v
        } else {
            invalid = true                                // keep the text so the user can fix it
            return
        }
        invalid = false
        onCommit(value)
        let shown = Self.editText(value)
        lastCommittedText = shown
        text = (hidden && !focused) ? Self.mask : shown
    }
}
