//
//  WalkingBuddyWidget.swift
//  Walking Buddy Widget
//
//  Lock Screen widget for Walking Buddy. Reads the live metrics the app
//  mirrors into the shared App Group and renders them in the accessory
//  families (circular / rectangular / inline).
//
//  Setup reminder: this target must have the App Group
//  "group.Walking-Buddy.shared" enabled (Signing & Capabilities), matching
//  the main app, otherwise the shared values won't be readable.
//

import WidgetKit
import SwiftUI

// MARK: - Shared data

private enum WalkWidgetData {
    static let appGroupID = "group.Walking-Buddy.shared"

    static func load() -> WalkEntry {
        let defaults = UserDefaults(suiteName: appGroupID)
        let isTracking = defaults?.bool(forKey: "wb.isTracking") ?? false
        var entry = WalkEntry(
            date: Date(),
            isTracking: isTracking,
            risk: defaults?.integer(forKey: "wb.risk") ?? 0,
            steps: defaults?.string(forKey: "wb.steps") ?? "0",
            distance: defaults?.string(forKey: "wb.distance") ?? "0 m",
            time: defaults?.string(forKey: "wb.time") ?? "0:00"
        )
        // Float the widget to the top of the Smart Stack while a walk is live.
        entry.relevance = TimelineEntryRelevance(score: isTracking ? 100 : 10)
        return entry
    }
}

struct WalkEntry: TimelineEntry {
    let date: Date
    let isTracking: Bool
    let risk: Int
    let steps: String
    let distance: String
    let time: String
    var relevance: TimelineEntryRelevance? = nil

    static let placeholder = WalkEntry(
        date: .now, isTracking: true, risk: 32, steps: "1,240", distance: "820 m", time: "12:30"
    )
}

// MARK: - Timeline provider

struct WalkProvider: TimelineProvider {
    func placeholder(in context: Context) -> WalkEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (WalkEntry) -> Void) {
        completion(context.isPreview ? .placeholder : WalkWidgetData.load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WalkEntry>) -> Void) {
        // The app pushes WidgetCenter reloads live while monitoring; this
        // periodic refresh is just a safety net for when the app is suspended.
        let entry = WalkWidgetData.load()
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

struct WalkWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WalkEntry

    var body: some View {
        // The small Home Screen widget paints its own brand background; the
        // Lock Screen accessory families stay transparent.
        if family == .systemSmall {
            content
        } else {
            content.widgetContainerBackground()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(min(max(entry.risk, 0), 100)), in: 0...100) {
                Image(systemName: "figure.walk")
            } currentValueLabel: {
                Text("\(entry.risk)")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(riskColor(entry.risk))

        case .accessoryRectangular:
            HStack(spacing: 10) {
                Gauge(value: Double(min(max(entry.risk, 0), 100)), in: 0...100) {
                    Image(systemName: "figure.walk")
                } currentValueLabel: {
                    Text("\(entry.risk)")
                }
                .gaugeStyle(.accessoryCircular)
                .tint(riskColor(entry.risk))

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.isTracking ? "Monitoring" : "Walking Buddy")
                        .font(.caption).bold()
                        .widgetAccentable()
                    Text("Break risk \(entry.risk)%")
                        .font(.caption2)
                    Text("\(entry.steps) steps · \(entry.time)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

        case .accessoryInline:
            Label("Risk \(entry.risk)% · \(entry.steps) steps", systemImage: "figure.walk")

        case .systemSmall:
            HomeSmallView(entry: entry)

        default:
            Gauge(value: Double(min(max(entry.risk, 0), 100)), in: 0...100) {
                Text("Risk")
            } currentValueLabel: {
                Text("\(entry.risk)")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(riskColor(entry.risk))
        }
    }
}

/// Small Home Screen widget: brand gradient with a risk ring and quick stats.
private struct HomeSmallView: View {
    let entry: WalkEntry

    private static let brandGreen = Color(red: 0.22, green: 0.86, blue: 0.52)
    private static let brandTeal = Color(red: 0.02, green: 0.62, blue: 0.47)

    /// The ring stays crisp white when calm and escalates to orange/red, so a
    /// dangerous reading pops against the green gradient.
    private var ringColor: Color {
        entry.risk < 40 ? .white : riskColor(entry.risk)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "figure.walk")
                Text("Walking Buddy")
                    .font(.caption2).fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(entry.isTracking ? Color.white : Color.white.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
            .foregroundStyle(.white)

            Spacer(minLength: 8)

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.22), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.02, min(Double(entry.risk) / 100, 1)))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(entry.risk)%")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("risk")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .foregroundStyle(.white)
            }
            .frame(maxHeight: .infinity)

            Spacer(minLength: 8)

            HStack(alignment: .firstTextBaseline) {
                stat(entry.steps, "steps")
                Spacer()
                stat(entry.time, "time")
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetGradientBackground(
            LinearGradient(colors: [Self.brandGreen, Self.brandTeal],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.caption).fontWeight(.semibold)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

// MARK: - Widget

struct WalkingBuddyWidget: Widget {
    let kind = "WalkingBuddyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WalkProvider()) { entry in
            WalkWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Walking Buddy")
        .description("Live break-risk and walk stats on your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall])
    }
}

@main
struct WalkingBuddyWidgetBundle: WidgetBundle {
    var body: some Widget {
        WalkingBuddyWidget()
        if #available(iOS 16.2, *) {
            WalkLiveActivity()
        }
    }
}

// MARK: - Helpers

private extension View {
    /// `containerBackground` is required for widgets on iOS 17+; this keeps the
    /// widget source compiling on earlier deployment targets too.
    @ViewBuilder
    func widgetContainerBackground() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(.clear, for: .widget)
        } else {
            self
        }
    }

    /// Fills the widget with a style, using `containerBackground` on iOS 17+
    /// (required there) and falling back to padding + `background` below it.
    @ViewBuilder
    func widgetGradientBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 17.0, *) {
            self.padding(14).containerBackground(style, for: .widget)
        } else {
            self.padding(14).background(style)
        }
    }
}
