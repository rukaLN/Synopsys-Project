//
//  ContentView.swift
//  Walking Buddy Watch Watch App
//

import SwiftUI

struct ContentView: View {
    @StateObject private var healthManager = HealthKitManager()

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(healthManager.isTracking ? "Monitoring" : "Walking Buddy")
                    .font(.headline)
                    .foregroundStyle(healthManager.isTracking ? .green : .primary)

                // Composite break-risk score from the shared equation.
                VStack(spacing: 2) {
                    Text(healthManager.riskScoreStatus)
                        .font(.system(.title, design: .rounded)).bold()
                        .foregroundStyle(.purple)
                    Text("Break Risk")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

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
                    Text(healthManager.isTracking ? "Stop" : "Start Walk")
                        .frame(maxWidth: .infinity)
                }
                .tint(healthManager.isTracking ? .red : .blue)
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
}

#Preview {
    ContentView()
}
