import Charts
import SwiftUI

/// Saved walks, the trends across them, and a plain-language summary of the last few.
struct HistoryView: View {
    @ObservedObject private var history = WalkHistory.shared
    @State private var metric = TrendMetric.risk
    @State private var confirmingDelete = false

    /// The latest walks, oldest first — the ones the summary and trends are built from.
    private var recent: [WalkRecord] { Array(history.walks.suffix(WalkTrends.window)) }
    private var trends: [Trend] { WalkTrends.trends(for: history.walks) }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                if history.walks.isEmpty {
                    emptyState
                } else {
                    summaryCard
                    if !trends.isEmpty { trendsCard }
                    if history.walks.count >= 2 { chartCard }
                    walksCard
                    Button("Delete History", role: .destructive) { confirmingDelete = true }
                        .font(.footnote)
                }
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .confirmationDialog("Delete all saved walks?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete History", role: .destructive) { history.clear() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            WalkingBuddyLogo(size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Walk History")
                    .font(.system(.title2, design: .rounded)).bold()
                Text("Trends across recent walks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.brandTeal)
            Text("No walks yet")
                .font(.system(.title3, design: .rounded)).bold()
            Text("Finish a walk of at least 5 minutes on the Monitor tab and it is saved here, so you can see how your walking changes over time.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .card()
    }

    private var summaryCard: some View {
        let status = summaryStatus
        return VStack(alignment: .leading, spacing: 14) {
            Label(status.title, systemImage: status.icon)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(status.color)
            Text(status.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                stat(recent.count == 1 ? "Walk" : "Walks", "\(recent.count)")
                stat("Distance", distanceText(recent.reduce(0) { $0 + $1.distance }))
                stat("Avg risk", percent(recent.reduce(0) { $0 + $1.risk } / Double(recent.count)))
                stat("Alerts", "\(recent.reduce(0) { $0 + $1.alerts })")
            }
        }
        .card()
    }

    private var trendsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Trends", "Recent walks compared with earlier ones")
            ForEach(trends) { trend in
                HStack(spacing: 12) {
                    iconBadge(trend.metric.icon)
                    Text(trend.metric.title)
                        .font(.subheadline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(trend.metric.format(trend.recent))
                            .font(.subheadline.bold())
                        changeLabel(trend)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }

    private var chartCard: some View {
        let points = chartPoints
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Over time", "Oldest to newest")
                Spacer()
                Picker("Metric", selection: $metric) {
                    ForEach(TrendMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Theme.brandTeal)
            }
            if points.count < 2 {
                Text("Not enough \(metric.title.lowercased()) readings yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Walk", point.walk), y: .value(metric.title, point.value))
                    PointMark(x: .value("Walk", point.walk), y: .value(metric.title, point.value))
                }
                .foregroundStyle(Theme.brandTeal)
                .chartXScale(domain: 0.5...(Double(recent.count) + 0.5))
                .chartXAxis {
                    AxisMarks(values: points.map(\.walk)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let walk = value.as(Double.self) { Text("\(Int(walk))") }
                        }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text(metric.format(number)) }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
        .card()
    }

    private var walksCard: some View {
        let shown = Array(history.walks.reversed().prefix(30))
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Recent walks", "\(history.walks.count) saved")
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, walk in
                if index > 0 { Divider() }
                walkRow(walk)
            }
        }
        .card()
    }

    private func walkRow(_ walk: WalkRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            iconBadge(walk.device == "Apple Watch" ? "applewatch" : "iphone")
            VStack(alignment: .leading, spacing: 3) {
                Text(walk.start, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    .font(.subheadline.bold())
                Text("\(HealthKitManager.durationFormatter.string(from: walk.duration) ?? "0:00") · \(walk.steps) steps · \(distanceText(walk.distance))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("Peak \(percent(walk.peakRisk))")
                    .font(.subheadline.bold())
                    .foregroundStyle(riskColor(walk.peakRisk))
                if walk.alerts > 0 {
                    Label("\(walk.alerts)", systemImage: "bell.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pieces

    private struct ChartPoint: Identifiable {
        let walk: Double
        let value: Double
        var id: Double { walk }
    }

    private var chartPoints: [ChartPoint] {
        recent.enumerated().compactMap { index, walk in
            metric.value(in: walk).map { ChartPoint(walk: Double(index + 1), value: $0) }
        }
    }

    private var summaryStatus: (title: String, icon: String, color: Color, detail: String) {
        let missing = WalkTrends.minimumWalks - history.walks.count
        if missing > 0 {
            return ("Keep walking", "figure.walk", Theme.brandTeal,
                    "Finish \(missing) more walk\(missing == 1 ? "" : "s") and Walking Buddy will start comparing them to spot trends.")
        }
        let worse = trends.filter { $0.direction == .worse }      // most worrying first
        if worse.isEmpty {
            return ("Looking steady", "checkmark.seal.fill", Theme.brandGreen,
                    "Nothing is trending the wrong way across your last \(recent.count) walks.")
        }
        var names = worse.prefix(3).map { $0.metric.title.lowercased() }
        if worse.count > 3 { names.append("\(worse.count - 3) more") }
        let list = ListFormatter.localizedString(byJoining: names)
        return ("Worth a look", "exclamationmark.triangle.fill", .orange,
                "\(list.prefix(1).uppercased() + list.dropFirst()) \(worse.count == 1 ? "is" : "are") trending the wrong way across your last \(recent.count) walks. Consider sharing this with a caregiver or doctor.")
    }

    @ViewBuilder
    private func changeLabel(_ trend: Trend) -> some View {
        if trend.direction == .steady {
            Text("Steady")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label(trend.metric.formatChange(abs(trend.change)), systemImage: trend.change < 0 ? "arrow.down" : "arrow.up")
                .font(.caption.bold())
                .foregroundStyle(trend.direction == .worse ? Color.orange : Theme.brandGreen)
        }
    }

    private func iconBadge(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.brandTeal)
            .frame(width: 34, height: 34)
            .background(Theme.brandGreen.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func sectionTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.headline, design: .rounded))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded)).bold()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func distanceText(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : HealthKitManager.metersString(meters)
    }

    /// Same bands as the live risk ring on the Monitor tab.
    private func riskColor(_ fraction: Double) -> Color {
        switch Int((fraction * 100).rounded()) {
        case ..<40: return Theme.brandGreen
        case 40..<70: return .orange
        default: return .red
        }
    }
}

private extension View {
    func card() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Theme.shadow, radius: 8, y: 4)
    }
}

#Preview {
    HistoryView()
}
