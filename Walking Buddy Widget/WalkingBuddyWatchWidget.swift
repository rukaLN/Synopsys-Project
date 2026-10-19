//
//  WalkingBuddyWatchWidget.swift
//  Walking Buddy Widget  (watchOS widget extension, embedded in the Watch app)
//
//  watchOS complications (watch face) + Smart Stack widget for Walking Buddy.
//  Reads the live workout metrics the watch app mirrors into the shared App
//  Group and renders them in the watchOS accessory families.
//
//  Setup reminder: this target must have the App Group
//  "group.Walking-Buddy.shared" enabled (Signing & Capabilities), matching
//  the Watch app, otherwise the shared values won't be readable.
//

import WidgetKit
import SwiftUI

// MARK: - Shared data

private enum WatchWidgetData {
    static let appGroupID = "group.Walking-Buddy.shared"

    static func load() -> WatchEntry {
        let defaults = UserDefaults(suiteName: appGroupID)
        return WatchEntry(
            date: Date(),
            isTracking: defaults?.bool(forKey: "wb.isTracking") ?? false,
            risk: defaults?.integer(forKey: "wb.risk") ?? 0,
            heartRate: defaults?.string(forKey: "wb.heartRate") ?? "–",
            steps: defaults?.string(forKey: "wb.steps") ?? "0",
            time: defaults?.string(forKey: "wb.time") ?? "0:00"
        )
    }
}

struct WatchEntry: TimelineEntry {
    let date: Date
    let isTracking: Bool
    let risk: Int
    let heartRate: String
    let steps: String
    let time: String

    static let placeholder = WatchEntry(
        date: .now, isTracking: true, risk: 32, heartRate: "96 bpm", steps: "1,240", time: "12:30"
    )
}

// MARK: - Timeline provider

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(context.isPreview ? .placeholder : WatchWidgetData.load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        let entry = WatchWidgetData.load()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }
}

private func riskColor(_ risk: Int) -> Color {
    switch risk {
    case ..<40: return .green
    case 40..<70: return .orange
    default: return .red
    }
}

// MARK: - Views

struct WatchWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchEntry

    private var fraction: Double { Double(min(max(entry.risk, 0), 100)) }

    var body: some View {
        content.widgetContainerBackground()
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: fraction, in: 0...100) {
                Image(systemName: "figure.walk")
            } currentValueLabel: {
                Text("\(entry.risk)")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(riskColor(entry.risk))

        case .accessoryCorner:
            Image(systemName: "figure.walk")
                .font(.title3)
                .widgetLabel {
                    Gauge(value: fraction, in: 0...100) {
                        Text("Risk")
                    } currentValueLabel: {
                        Text("\(entry.risk)%")
                    }
                    .tint(riskColor(entry.risk))
                }

        case .accessoryInline:
            Label("Break risk \(entry.risk)%", systemImage: "figure.walk")

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label(entry.isTracking ? "Monitoring" : "Walking Buddy", systemImage: "figure.walk")
                    .font(.caption).bold()
                    .widgetAccentable()
                Text("Break risk \(entry.risk)%")
                    .font(.headline)
                Text("\(entry.heartRate) · \(entry.time)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        default:
            Gauge(value: fraction, in: 0...100) {
                Text("Risk")
            } currentValueLabel: {
                Text("\(entry.risk)")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(riskColor(entry.risk))
        }
    }
}

// MARK: - Widget

struct WalkingBuddyWatchWidget: Widget {
    let kind = "WalkingBuddyWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchProvider()) { entry in
            WatchWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Walking Buddy")
        .description("Live break-risk and walk stats on your watch face.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}

@main
struct WalkingBuddyWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WalkingBuddyWatchWidget()
    }
}

// MARK: - Helpers

private extension View {
    /// `containerBackground` is required for widgets on watchOS 10+; this keeps
    /// the source compiling on earlier deployment targets too.
    @ViewBuilder
    func widgetContainerBackground() -> some View {
        if #available(watchOS 10.0, *) {
            self.containerBackground(.clear, for: .widget)
        } else {
            self
        }
    }
}
