//
//  WalkLiveActivity.swift
//  Walking Buddy iOS Widget
//
//  The Lock Screen card + Dynamic Island presentation for an active walk.
//  Driven by the app's `Activity<WalkActivityAttributes>`.
//
//  Requires `WalkActivityAttributes.swift` to also be a member of this target.
//

import ActivityKit
import WidgetKit
import SwiftUI

private let brandGreen = Color(red: 0.22, green: 0.86, blue: 0.52)
private let brandTeal = Color(red: 0.02, green: 0.62, blue: 0.47)
private let buddyAmber = Color(red: 1.0, green: 0.76, blue: 0.29)

private func riskColor(_ risk: Int) -> Color {
    switch risk {
    case ..<40: return brandGreen
    case 40..<70: return .orange
    default: return .red
    }
}

@available(iOS 16.2, *)
struct WalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            LockScreenLiveView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.risk)%", systemImage: "figure.walk")
                        .font(.title3).bold()
                        .foregroundStyle(riskColor(context.state.risk))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.time)
                        .font(.title3).bold().monospacedDigit()
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("\(context.state.steps) steps")
                        Spacer()
                        Text(context.state.distance)
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                }
            } compactLeading: {
                Image(systemName: "figure.walk")
                    .foregroundStyle(riskColor(context.state.risk))
            } compactTrailing: {
                Text("\(context.state.risk)%")
                    .foregroundStyle(riskColor(context.state.risk))
            } minimal: {
                Image(systemName: "figure.walk")
                    .foregroundStyle(riskColor(context.state.risk))
            }
        }
    }
}

@available(iOS 16.2, *)
private struct LockScreenLiveView: View {
    let state: WalkActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [brandGreen, brandTeal],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "figure.walk")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text("Walking Buddy")
                    .font(.caption).bold()
                    .foregroundStyle(.white.opacity(0.9))
                Text("Break risk \(state.risk)%")
                    .font(.headline)
                    .foregroundStyle(riskColor(state.risk))
                Text("\(state.steps) steps · \(state.distance)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(state.time)
                    .font(.title2).bold().monospacedDigit()
                    .foregroundStyle(.white)
                Text("elapsed")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(16)
    }
}
