//
//  ContentView.swift
//  Walking Buddy Watch Watch App
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var healthManager = HealthKitManager.shared

    private static let brandGreen = Color(red: 0.22, green: 0.86, blue: 0.52)
    private static let brandTeal = Color(red: 0.02, green: 0.62, blue: 0.47)

    var body: some View {
        TabView {
            monitor
            WatchHistoryView()
            WatchRiskInfoView()
        }
        .tabViewStyle(.verticalPage)
        .onAppear {
            HapticsManager.prepare()
            healthManager.clearWidgetSnapshotIfIdle()
        }
        .alert("Time to Rest!", isPresented: $healthManager.triggersAlert) {
            Button("OK, I'll sit down") { healthManager.pauseSession() }
        } message: {
            Text(healthManager.alertMessage)
        }
        .alert("Health Access", isPresented: $healthManager.healthAccessNeedsSettings) {
            Button("OK") {}
        } message: {
            Text("Health access was already set. If walk data is missing, re-enable it in Settings \u{2192} Privacy & Security \u{2192} Health on your Apple Watch, or from the Health app on your iPhone.")
        }
    }

    private var monitor: some View {
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

                elapsedTime

                controls

                VStack(spacing: 6) {
                    metricRow("Heart Rate", healthManager.heartRateStatus, risk: healthManager.metricRisks["heartRate"])
                    metricRow("Speed", healthManager.currentPaceStatus, risk: healthManager.metricRisks["speed"])
                    metricRow("Cadence", healthManager.cadenceStatus, risk: healthManager.metricRisks["cadence"])
                    metricRow("Steps", healthManager.stepsStatus)
                    metricRow("Distance", healthManager.distanceStatus)
                    metricRow("Flights", healthManager.flightsStatus, risk: healthManager.metricRisks["flights"])
                    metricRow("Steadiness", healthManager.steadinessStatus, risk: healthManager.metricRisks["steadiness"])
                    metricRow("Asymmetry", healthManager.asymmetryStatus, risk: healthManager.metricRisks["asymmetry"])
                    metricRow("Double Support", healthManager.doubleSupportStatus, risk: healthManager.metricRisks["doubleSupport"])
                    metricRow("Step Length", healthManager.stepLengthStatus, risk: healthManager.metricRisks["stepLength"])
                    metricRow("Energy", healthManager.activeEnergyStatus, risk: healthManager.metricRisks["activeEnergy"])

                    Text("Steadiness, asymmetry, double support & step length are wrist estimates.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }

                Button {
                    healthManager.manageHealthAccess()
                } label: {
                    Label("Health Access", systemImage: "heart.text.square").frame(maxWidth: .infinity)
                }
                .tint(.gray)
            }
            .padding(.horizontal, 4)
        }
    }

    /// Prominent elapsed-time readout shown under the risk ring, tinted by the same
    /// scale as the ring using the duration sub-score.
    private var elapsedTime: some View {
        let tint = healthManager.metricRisks["duration"].map { Self.riskColor($0) } ?? .primary
        return HStack(spacing: 5) {
            Image(systemName: "clock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(healthManager.elapsedTimeStatus)
                .font(.system(.title3, design: .rounded)).bold()
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }

    /// Start / pause / resume / stop controls, shown near the top under elapsed time.
    @ViewBuilder
    private var controls: some View {
        if healthManager.isPaused {
            // After "I'll sit down" the walk is paused — resume or stop.
            Button {
                healthManager.resumeSession()
            } label: {
                Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .tint(Self.brandTeal)
            Button {
                healthManager.stopSession()
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .tint(.red)
        } else if healthManager.isTracking {
            // Mirrors the iPhone: Pause beside Stop while a walk is running.
            Button {
                healthManager.pauseSession()
            } label: {
                Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
            }
            .tint(Self.brandTeal)
            Button {
                healthManager.stopSession()
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .tint(.red)
        } else {
            Button {
                healthManager.requestAuthorizationAndStart()
            } label: {
                Label("Start Walk", systemImage: "figure.walk").frame(maxWidth: .infinity)
            }
            .tint(Self.brandTeal)
        }
    }

    private func metricRow(_ label: String, _ value: String, risk: Double? = nil) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .bold()
                .foregroundStyle(risk.map { Self.riskColor($0) } ?? .primary)
        }
    }

    private var riskValue: Int {
        Int(healthManager.riskScoreStatus.filter(\.isNumber)) ?? 0
    }

    private var riskColor: Color {
        Self.riskColor(Double(riskValue) / 100)
    }

    /// Shared green → orange → red scale used by the risk ring and each metric
    /// row, so a "dangerous" reading looks the same everywhere. `fraction` is a
    /// 0...1 risk sub-score (higher = more dangerous).
    static func riskColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.4: return brandGreen
        case ..<0.7: return .orange
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

/// Compact break-risk explainer for the watch, mirroring the shared
/// ``BreakRiskModel`` (weights, reference values, and threshold).
struct WatchRiskInfoView: View {
    private let model = BreakRiskModel()
    private static let brandGreen = Color(red: 0.22, green: 0.86, blue: 0.52)

    private var breakPercent: Int { Int((model.breakThreshold * 100).rounded()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Break Risk")
                    .font(.headline)
                    .foregroundStyle(Self.brandGreen)

                Text("A weighted blend of your walking signals, 0\u{2013}100%. A break is suggested at \(breakPercent)%.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("risk = (\u{03A3} w\u{1D62}\u{00B7}s\u{1D62}) / (\u{03A3} w\u{1D62})")
                    .font(.system(.caption2, design: .monospaced)).bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Self.brandGreen.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

                ForEach(model.metricInfo) { info in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(info.name).font(.caption2).bold()
                            Spacer()
                            Text("\u{00D7}\(String(format: "%g", info.weight))")
                                .font(.system(size: 9))
                                .foregroundStyle(Self.brandGreen)
                        }
                        Text(info.rule)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

#Preview {
    ContentView()
}

#Preview("Watch Risk Info") {
    WatchRiskInfoView()
}
