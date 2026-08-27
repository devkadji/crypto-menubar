import SwiftUI
import Charts
import AppKit

// The zoomable / pannable / hoverable line chart, factored out of the token
// ChartSection so the Portfolio window can draw value series with the exact
// same interactions (pinch + ⌥scroll zoom, drag-to-pan, hover crosshair,
// double-click reset). Pure presentation: feed it points, it draws them.

struct InteractiveLineChart: View {
    let points: [PricePoint]
    var tint: Color = .accentColor
    var formatValue: (Double) -> String = formatPrice
    /// Privacy mode: draw the Y grid but no numeric labels (the curve shape
    /// stays readable, the absolute values don't).
    var hideYAxisLabels: Bool = false

    @State private var hoverPoint: PricePoint? = nil
    @State private var xZoom: CGFloat = 1.0           // 1.0 = full range; pinch out to zoom in
    @State private var zoomAtGestureStart: CGFloat = 1.0
    @State private var scrollLeadingEdge: Date = .distantPast
    // Pinch-zoom anchor — the date under the cursor at gesture start. The
    // visible window slides during zoom so this date stays at the same
    // fractional position across the plot width.
    @State private var zoomAnchorDate: Date? = nil
    @State private var zoomAnchorFraction: Double = 0.5
    // Drag-to-pan state — captured at gesture start so we pan relative to it.
    @State private var panStartLeadingEdge: Date? = nil
    @State private var isChartHovered = false         // cursor currently over this chart
    @State private var scrollMonitor: Any? = nil      // NSEvent monitor for Option+scroll zoom
    // Mirror of `points` the scroll monitor can read through a Binding — the
    // monitor closure is installed once, so it must not capture a stale copy.
    @State private var monitorPoints: [PricePoint] = []

    private static let maxZoom: CGFloat = 30.0       // cap so we don't show <2 points

    // Changes whenever the series is swapped (auto-refresh, timeframe change)
    // — triggers a re-anchor to the right edge while keeping the zoom level.
    private var seriesStamp: String {
        "\(points.count)|\(points.first?.timestamp.timeIntervalSince1970 ?? 0)|\(points.last?.timestamp.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        chartView
            .onAppear {
                monitorPoints = points
                resetZoom()
                installScrollZoomMonitor()
            }
            .onDisappear {
                if let m = scrollMonitor { NSEvent.removeMonitor(m) }
                scrollMonitor = nil
            }
            .onChange(of: seriesStamp) { _, _ in
                monitorPoints = points
                hoverPoint = nil
                reanchorRightEdge()
            }
    }

    // Mouse users have no pinch gesture — let Option+scroll-wheel zoom instead.
    // A local NSEvent monitor observes scroll events without sitting in the
    // hit-test path (so it doesn't block the hover tooltip). It only acts when
    // Option is held and the cursor is over THIS chart.
    private func installScrollZoomMonitor() {
        guard scrollMonitor == nil else { return }
        let hovered = $isChartHovered
        let zoom = $xZoom
        let zoomStart = $zoomAtGestureStart
        let scroll = $scrollLeadingEdge
        let live = $monitorPoints
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Mouse wheel only (trackpad has pinch); Option held; over this chart.
            guard event.modifierFlags.contains(.option),
                  !event.hasPreciseScrollingDeltas,
                  hovered.wrappedValue else {
                return event
            }
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return nil }
            // Scroll up → zoom in. Clamp per-event delta so one notch is gentle.
            let clamped = min(max(delta, -3), 3)
            let factor = 1.0 + clamped * 0.08
            let newZoom = max(1.0, min(Self.maxZoom, zoom.wrappedValue * factor))
            zoom.wrappedValue = newZoom
            zoomStart.wrappedValue = newZoom
            // Re-anchor the visible window's right edge to the latest point.
            let pts = live.wrappedValue
            if let first = pts.first?.timestamp, let last = pts.last?.timestamp, last > first {
                let visible = last.timeIntervalSince(first) / Double(newZoom)
                scroll.wrappedValue = last.addingTimeInterval(-visible)
            }
            return nil   // consume — don't let the list scroll
        }
    }

    // Length of the visible X window in seconds. zoom=1 shows the full series;
    // zoom=2 shows half; etc. (Used by .chartXVisibleDomain — Swift Charts'
    // first-class API for fixed-window panning/zooming. The whole series is
    // always fed to the chart; only the visible WINDOW changes, so marks never
    // re-render or fade out during zoom changes.)
    private var visibleDuration: TimeInterval {
        guard let first = points.first?.timestamp,
              let last = points.last?.timestamp,
              last > first else { return 86400 }
        return last.timeIntervalSince(first) / Double(xZoom)
    }

    // Points inside the ACTUAL visible window [scrollLeadingEdge, +visibleDuration].
    // Used by yDomain (Y-axis fit) and nearest() (hover-snap).
    private var visiblePoints: [PricePoint] {
        guard !points.isEmpty else { return points }
        let start = scrollLeadingEdge
        let end = start.addingTimeInterval(visibleDuration)
        let inWindow = points.filter { $0.timestamp >= start && $0.timestamp <= end }
        // Defensive fallback: if scrollLeadingEdge is still .distantPast (i.e.
        // the chart hasn't been anchored yet), return everything so yDomain
        // doesn't degenerate to 0…1.
        return inWindow.isEmpty ? points : inWindow
    }

    // Fit the Y-axis to the data inside the current X window, with 8% padding.
    private var yDomain: ClosedRange<Double> {
        let prices = visiblePoints.map(\.price)
        guard let lo = prices.min(), let hi = prices.max() else { return 0...1 }
        if hi == lo {
            let pad = max(abs(hi) * 0.01, 0.0001)
            return (lo - pad)...(hi + pad)
        }
        let pad = (hi - lo) * 0.08
        return (lo - pad)...(hi + pad)
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0)
            .onChanged { value in
                // First frame of this gesture: capture the date the cursor is
                // over as the zoom anchor (from the hover state we already track).
                if zoomAnchorDate == nil, let hp = hoverPoint,
                   let first = points.first?.timestamp,
                   let last = points.last?.timestamp,
                   last > first {
                    let total = last.timeIntervalSince(first)
                    let curVisible = total / Double(xZoom)
                    let pos = hp.timestamp.timeIntervalSince(scrollLeadingEdge) / curVisible
                    zoomAnchorDate = hp.timestamp
                    zoomAnchorFraction = max(0, min(1, pos))
                }
                let proposed = zoomAtGestureStart * value.magnification
                let new = max(1.0, min(Self.maxZoom, proposed))
                withTransaction(Transaction(animation: nil)) {
                    xZoom = new
                    repositionForZoom()
                }
            }
            .onEnded { _ in
                zoomAtGestureStart = xZoom
                zoomAnchorDate = nil
            }
    }

    // DragGesture for panning the visible window. Three-finger trackpad drag
    // (via macOS Accessibility) is delivered as a regular click-and-drag and
    // triggers this too.
    private func panGesture(plotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if panStartLeadingEdge == nil {
                    panStartLeadingEdge = scrollLeadingEdge
                }
                guard plotWidth > 0,
                      let start = panStartLeadingEdge else { return }
                // translation.width > 0 (drag right) → visible window shifts
                // LEFT in time (earlier data appears).
                let secPerPoint = visibleDuration / Double(plotWidth)
                let deltaSec = -Double(value.translation.width) * secPerPoint
                var newLE = start.addingTimeInterval(deltaSec)
                if let first = points.first?.timestamp,
                   let last = points.last?.timestamp {
                    if newLE < first { newLE = first }
                    let maxLE = last.addingTimeInterval(-visibleDuration)
                    if newLE > maxLE { newLE = maxLE }
                }
                withTransaction(Transaction(animation: nil)) {
                    scrollLeadingEdge = newLE
                }
            }
            .onEnded { _ in
                panStartLeadingEdge = nil
            }
    }

    private func resetZoom() {
        xZoom = 1.0
        zoomAtGestureStart = 1.0
        zoomAnchorDate = nil
        reanchorRightEdge()
    }

    // Reposition during zoom: keep the cursor's anchor date at the same
    // fractional X position. Falls back to right-edge anchor when no cursor
    // anchor was captured (e.g. scroll-wheel zoom with no hover).
    private func repositionForZoom() {
        guard let first = points.first?.timestamp,
              let last = points.last?.timestamp,
              last > first else { return }
        let total = last.timeIntervalSince(first)
        let newVisible = total / Double(xZoom)

        if let anchor = zoomAnchorDate {
            var newLE = anchor.addingTimeInterval(-zoomAnchorFraction * newVisible)
            if newLE < first { newLE = first }
            let maxLE = last.addingTimeInterval(-newVisible)
            if newLE > maxLE { newLE = maxLE }
            scrollLeadingEdge = newLE
        } else {
            scrollLeadingEdge = last.addingTimeInterval(-newVisible)
        }
    }

    // Right-edge anchor — initial load, series swap, and manual zoom reset.
    private func reanchorRightEdge() {
        guard let last = points.last?.timestamp else { return }
        scrollLeadingEdge = last.addingTimeInterval(-visibleDuration)
    }

    @ViewBuilder
    private var chartView: some View {
        let domain = yDomain
        // Feed Chart ALL points; the visible window is controlled below via
        // chartXVisibleDomain + chartScrollPosition (Swift Charts' first-class
        // windowing API). This avoids per-frame data mutation during zoom,
        // which was leaving brief rendering gaps in the curve.
        Chart {
            ForEach(points) { p in
                // Anchor the area's bottom to the visible domain's lower bound,
                // not to y=0. Without this the fill extends down to 0 (off-screen
                // since we've restricted the Y axis) and bleeds into rows below.
                AreaMark(
                    x: .value("Date", p.timestamp),
                    yStart: .value("Bottom", domain.lowerBound),
                    yEnd: .value("Price", p.price)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.35), tint.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Date", p.timestamp),
                    y: .value("Price", p.price)
                )
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)
            }

            // Hover crosshair: vertical rule + highlighted point + value/date annotation.
            if let hp = hoverPoint {
                RuleMark(x: .value("Date", hp.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                PointMark(
                    x: .value("Date", hp.timestamp),
                    y: .value("Price", hp.price)
                )
                .foregroundStyle(tint)
                .symbolSize(70)
                .annotation(
                    // .automatic lets Swift Charts pick top vs. bottom based on
                    // where there's room — avoids the leftmost-curve occlusion
                    // we saw when .top forced the tooltip into the data band.
                    position: .automatic,
                    alignment: .center,
                    spacing: 6,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    HoverTooltip(point: hp, formatValue: formatValue)
                }
            }
        }
        .chartYScale(domain: domain)
        // Visible window: only this slice of the X axis is shown at any moment.
        // The chart still has access to all points, so marks render once
        // and aren't dropped/recreated as the window changes.
        .chartXVisibleDomain(length: visibleDuration)
        .chartScrollPosition(x: $scrollLeadingEdge)
        .chartScrollableAxes(.horizontal)
        // Belt and suspenders: even if the gesture transaction misses a frame,
        // tell Charts not to animate any state derived from the zoom value.
        .animation(nil, value: xZoom)
        .chartYAxis {
            // .automatic(desiredCount:) sometimes gives ceil+1 ticks; cap at 4
            // explicitly so labels never get crammed at the top/bottom edges.
            if hideYAxisLabels {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine()
                    AxisTick()
                }
            } else {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            isChartHovered = true
                            guard let plotFrame = proxy.plotFrame else { return }
                            let origin = geo[plotFrame].origin
                            let xInPlot = location.x - origin.x
                            if let date: Date = proxy.value(atX: xInPlot, as: Date.self) {
                                hoverPoint = nearest(to: date)
                            }
                        case .ended:
                            isChartHovered = false
                            hoverPoint = nil
                        }
                    }
                    // Pinch lives INSIDE the overlay's hit area so it competes
                    // for the same events the overlay rect was eating.
                    .simultaneousGesture(zoomGesture)
                    // Drag-to-pan. Uses the plot width from the proxy to map
                    // pixel drag → time.
                    .gesture(
                        panGesture(plotWidth: (proxy.plotFrame.map { geo[$0].width } ?? 0))
                    )
                    .onTapGesture(count: 2) { resetZoom() }
            }
        }
    }

    private func nearest(to date: Date) -> PricePoint? {
        let candidates = visiblePoints.isEmpty ? points : visiblePoints
        guard !candidates.isEmpty else { return nil }
        return candidates.min { a, b in
            abs(a.timestamp.timeIntervalSince(date)) < abs(b.timestamp.timeIntervalSince(date))
        }
    }
}

// MARK: - Hover tooltip (date + value near cursor)

struct HoverTooltip: View {
    let point: PricePoint
    var formatValue: (Double) -> String = formatPrice

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(point.timestamp.formatted(
                .dateTime.month(.abbreviated).day().hour().minute()
            ))
            .font(.caption2)
            .foregroundColor(.secondary)
            Text(formatValue(point.price))
                .font(.caption.bold())
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - "% over timeframe" badge

/// "7D +2.34%" — the timeframe label makes it unambiguous which window the
/// number refers to; the tooltip spells out the source.
struct ChangeBadge: View {
    let timeframe: Timeframe
    let change: PriceChange?
    var font: Font = .caption

    var body: some View {
        HStack(spacing: 3) {
            Text(timeframe.rawValue)
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
            if let c = change {
                Text(formatPercent(c.percent))
                    .font(font)
                    .monospacedDigit()
                    .foregroundColor(c.percent >= 0 ? .green : .red)
            } else {
                Text("—")
                    .font(font)
                    .foregroundColor(.secondary)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        if let c = change {
            return "Price change over the \(timeframe.changeDescription) (\(c.source.label)). Follows the chart timeframe — change it in the expanded chart."
        }
        return "No \(timeframe.rawValue) change available while the chart is collapsed — expand the chart to compute it from history."
    }
}

// MARK: - Source + freshness caption under a chart

struct SourceCaption: View {
    let text: String
    let last: Date?
    let fetchedAt: Date?

    var body: some View {
        // Dot color reflects how fresh the most-recent data point is:
        // green ≤2h, yellow ≤24h, red >24h.
        let age = last.map { Date().timeIntervalSince($0) } ?? .infinity
        let color: Color = age <= 2 * 3600 ? .green
            : (age <= 24 * 3600 ? .yellow : .red)
        // "↻ HH:mm" is when we last polled — advances every refresh interval,
        // so it's a visible confirmation the chart is auto-updating.
        let updated = fetchedAt.map {
            "↻ " + $0.formatted(.dateTime.hour().minute())
        } ?? ""
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(text) · \(updated)")
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }
}
