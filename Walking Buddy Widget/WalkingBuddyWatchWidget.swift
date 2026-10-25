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
import AppIntents

// MARK: - Shared data

private enum WatchWidgetData {
    static let appGroupID = "group.Walking-Buddy.shared"
    /// A live walk refreshes the snapshot every second. If the last update is older
    /// than this, the app was swiped away mid-walk — treat the walk as stopped so the
    /// complication doesn't get stuck showing "Monitoring".
    static let staleAfter: TimeInterval = 90

    static func load() -> WatchEntry {
        let defaults = UserDefaults(suiteName: appGroupID)
        let updated = defaults?.object(forKey: "wb.updated") as? Date
        let isPaused = defaults?.bool(forKey: "wb.isPaused") ?? false
        let recentlyUpdated = updated.map { Date().timeIntervalSince($0) < staleAfter } ?? false
        // A paused walk legitimately stops refreshing the snapshot, so don't mistake
        // that for the app being swiped away (which would zero everything out).
        let fresh = isPaused || recentlyUpdated
        let isTracking = fresh && (defaults?.bool(forKey: "wb.isTracking") ?? false)
        var entry = WatchEntry(
            date: Date(),
            isTracking: isTracking,
            isPaused: isTracking && isPaused,
            risk: isTracking ? (defaults?.integer(forKey: "wb.risk") ?? 0) : 0,
            heartRate: isTracking ? (defaults?.string(forKey: "wb.heartRate") ?? "–") : "–",
            steps: isTracking ? (defaults?.string(forKey: "wb.steps") ?? "0") : "0",
            time: isTracking ? (defaults?.string(forKey: "wb.time") ?? "0:00") : "0:00"
        )
        // Float the widget to the top of the Smart Stack while a walk is live.
        entry.relevance = TimelineEntryRelevance(score: isTracking ? 100 : 10)
        return entry
    }
}

struct WatchEntry: TimelineEntry {
    let date: Date
    let isTracking: Bool
    var isPaused: Bool = false
    let risk: Int
    let heartRate: String
    let steps: String
    let time: String
    var relevance: TimelineEntryRelevance? = nil

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
            HStack(spacing: 10) {
                Gauge(value: fraction, in: 0...100) {
                    Image(systemName: "figure.walk")
                } currentValueLabel: {
                    Text("\(entry.risk)")
                }
                .gaugeStyle(.accessoryCircular)
                .tint(riskColor(entry.risk))

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.isPaused ? "Paused" : (entry.isTracking ? "Monitoring" : "Walking Buddy"))
                        .font(.caption).bold()
                        .widgetAccentable()
                    Text("Break risk \(entry.risk)%")
                        .font(.caption2)
                    Text("\(entry.heartRate) · \(entry.time)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

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

// MARK: - RelevanceKit Smart Stack widget (watchOS 12+)

/// Empty configuration intent required by `RelevanceEntriesProvider`.
@available(watchOS 12.0, *)
struct WalkRelevanceIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Walking Buddy"
}

/// Relevance entry wrapping the shared App Group snapshot.
@available(watchOS 12.0, *)
struct WalkRelevanceEntry: RelevanceEntry {
    let date: Date
    let walk: WatchEntry
}

/// Tells the watchOS Smart Stack that Walking Buddy is relevant while a workout
/// is active — a contextual clue instead of the timeline score. The fitness
/// clue only fires if this widget extension has HealthKit permission.
@available(watchOS 12.0, *)
struct WalkRelevanceProvider: RelevanceEntriesProvider {
    func placeholder(context: Context) -> WalkRelevanceEntry {
        WalkRelevanceEntry(date: .now, walk: .placeholder)
    }

    func entry(configuration: WalkRelevanceIntent, context: Context) async throws -> WalkRelevanceEntry {
        WalkRelevanceEntry(date: .now, walk: WatchWidgetData.load())
    }

    func relevance() async -> WidgetRelevance<WalkRelevanceIntent> {
        let attribute = WidgetRelevanceAttribute<WalkRelevanceIntent>(
            configuration: WalkRelevanceIntent(),
            context: .fitness(.workoutActive)
        )
        return WidgetRelevance([attribute])
    }
}

@available(watchOS 12.0, *)
struct WalkingBuddySmartStackWidget: Widget {
    let kind = "WalkingBuddySmartStackWidget"

    var body: some WidgetConfiguration {
        RelevanceConfiguration(kind: kind, provider: WalkRelevanceProvider()) { entry in
            WatchWidgetEntryView(entry: entry.walk)
        }
        .configurationDisplayName("Walking Buddy")
        .description("Appears in the Smart Stack while you're on a walk.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular])
        // Lets this relevance widget stand in for the pinned timeline widget so
        // the Smart Stack doesn't show two Walking Buddy entries.
        .associatedKind("WalkingBuddyWatchWidget")
    }
}

@main
struct WalkingBuddyWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WalkingBuddyWatchWidget()
        if #available(watchOS 12.0, *) {
            WalkingBuddySmartStackWidget()
        }
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
