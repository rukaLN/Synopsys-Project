//
//  WatchHistoryView.swift
//  Walking Buddy Watch Watch App
//
//  Compact history + trend graph for the watch, mirroring the iPhone's History
//  tab. Reads the shared `WalkHistory` store (walks finished on this watch) and
//  charts a chosen metric across recent walks with Swift Charts.
//

import SwiftUI
import Charts

struct WatchHistoryView: View {
    @ObservedObject private var history = WalkHistory.shared
    @State private var metric: WatchMetric = .risk

    private static let brandGreen = Color(red: 0.22, green: 0.86, blue: 0.52)
    private static let brandTeal = Color(red: 0.02, green: 0.62, blue: 0.47)

    /// Metrics plotted on the watch, read straight off each `WalkRecord`.
    enum WatchMetric: String, CaseIterable, Identifiable {
        case risk, steadiness, cadence, heartRate
        var id: String { rawValue }

        var title: String {
            switch self {
            case .risk: "Break risk"
            case .steadiness: "Steadiness"
            case .cadence: "Cadence"
            case .heartRate: "Heart rate"
            }
        }

        func value(_ walk: WalkRecord) -> Double? {
            switch self {
            case .risk: walk.risk * 100
            case .steadiness: walk.steadiness.map { $0 * 100 }
            case .cadence: walk.cadence
            case .heartRate: walk.heartRate
            }
        }

        func format(_ value: Double) -> String {
            switch self {
            case .risk, .steadiness: "\(Int(value.rounded()))%"
            case .cadence: "\(Int(value.rounded())) spm"
            case .heartRate: "\(Int(value.rounded())) bpm"
            }
        }
    }

    private struct Point: Identifiable {
        let id = UUID()
        let index: Int
        let value: Double
    }

    private var points: [Point] {
        history.walks.suffix(12).enumerated().compactMap { index, walk in
            metric.value(walk).map { Point(index: index + 1, value: $0) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("History")
                    .font(.headline)
                    .foregroundStyle(Self.brandGreen)

                if history.walks.isEmpty {
                    ContentUnavailableView(
                        "No walks yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Finish a walk of at least 5 minutes to see your trend here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    // Always show the metric picker, so you can switch metrics even when
                    // the selected one doesn't yet have enough data to chart.
                    Picker("Metric", selection: $metric) {
                        ForEach(WatchMetric.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()

                    if points.count < 2 {
                        Text("Not enough \(metric.title.lowercased()) data yet. Try another metric or finish more walks.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        chart

                        if let latest = points.last {
                            Text("Latest: \(metric.format(latest.value))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var chart: some View {
        Chart(points) { point in
            AreaMark(x: .value("Walk", point.index), y: .value(metric.title, point.value))
                .foregroundStyle(LinearGradient(colors: [Self.brandGreen.opacity(0.4), .clear],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Walk", point.index), y: .value(metric.title, point.value))
                .foregroundStyle(Self.brandTeal)
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .frame(height: 110)
    }
}
