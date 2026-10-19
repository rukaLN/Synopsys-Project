//
//  ContentView.swift
//  Walking Buddy Watch Watch App
//

import SwiftUI

struct ContentView: View {
    @StateObject private var healthManager = HealthKitManager()

    private static let brandGreen = Color(red: 0.22, green: 0.86, blue: 0.52)
    private static let brandTeal = Color(red: 0.02, green: 0.62, blue: 0.47)

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: healthManager.isTracking ? "figure.walk" : "figure.walk.circle.fill")
                        .foregroundStyle(healthManager.isTracking ? Self.brandGreen : .secondary)
                    Text(healthManager.isTracking ? "Monitoring" : "Walking Buddy")
                        .font(.headline)
                        .foregroundStyle(healthManager.isTracking ? Self.brandGreen : .primary)
                }

                // Composite break-risk score from the shared equation.
                WatchRiskRing(
                    fraction: Double(riskValue) / 100,
                    percentText: healthManager.riskScoreStatus,
                    color: riskColor
                )
                .frame(width: 96, height: 96)

                VStack(spacing: 6) {
                    metricRow("Heart Rate", healthManager.heartRateStatus)
                    metricRow("Steps", healthManager.stepsStatus)
                    metricRow("Distance", healthManager.distanceStatus)
                    metricRow("Energy", healthManager.activeEnergyStatus)
                    metricRow("Time", healthManager.elapsedTimeStatus)
                }

                Button {
                    if healthManager.isTracking {
                        healthManager.stopSession()
                    } else {
                        healthManager.requestAuthorizationAndStart()
                    }
                } label: {
                    Label(healthManager.isTracking ? "Stop" : "Start Walk",
                          systemImage: healthManager.isTracking ? "stop.fill" : "figure.walk")
                        .frame(maxWidth: .infinity)
                }
                .tint(healthManager.isTracking ? .red : Self.brandTeal)
            }
            .padding(.horizontal, 4)
        }
        .onAppear { HapticsManager.prepare() }
        .alert("Time to Rest!", isPresented: $healthManager.triggersAlert) {
            Button("OK, I'll sit down") { }
        } message: {
            Text(healthManager.alertMessage)
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .bold()
        }
    }

    private var riskValue: Int {
        Int(healthManager.riskScoreStatus.filter(\.isNumber)) ?? 0
    }

    private var riskColor: Color {
        switch riskValue {
        case ..<40: return Self.brandGreen
        case 40..<70: return .orange
        default: return .red
        }
    }
}

/// Compact break-risk ring for the watch face layout.
struct WatchRiskRing: View {
    let fraction: Double
    let percentText: String
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 9)
            Circle()
                .trim(from: 0, to: max(0, min(fraction, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: fraction)
            VStack(spacing: 0) {
                Text(percentText)
                    .font(.system(.title3, design: .rounded)).bold()
                    .foregroundStyle(color)
                Text("Risk")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
}
