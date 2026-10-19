import SwiftUI
import HealthKit

struct ContentView: View {
    @StateObject private var healthManager = HealthKitManager()

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                riskHero
                metricsGrid
                controlButton
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            HapticsManager.prepare()
        }
        .alert(isPresented: $healthManager.triggersAlert) {
            Alert(
                title: Text("Time to Rest!"),
                message: Text(healthManager.alertMessage),
                dismissButton: .default(Text("OK, I am sitting")) {
                    HapticsManager.prepare()
                }
            )
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            WalkingBuddyLogo(size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Walking Buddy")
                    .font(.system(.title2, design: .rounded)).bold()
                Text("Mobility & fatigue monitor")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var riskHero: some View {
        VStack(spacing: 18) {
            StatusPill(isTracking: healthManager.isTracking)

            RiskRing(
                fraction: Double(riskValue) / 100,
                percentText: healthManager.riskScoreStatus,
                color: riskColor
            )
            .frame(width: 200, height: 200)

            Text(healthManager.monitoringMessage)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.shadow, radius: 12, y: 6)
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            MetricCard(icon: "speedometer", label: "Live Speed", value: healthManager.currentPaceStatus)
            MetricCard(icon: "metronome.fill", label: "Cadence", value: healthManager.cadenceStatus)
            MetricCard(icon: "figure.walk", label: "Steps", value: healthManager.stepsStatus)
            MetricCard(icon: "location.fill", label: "Distance", value: healthManager.distanceStatus)
            MetricCard(icon: "clock.fill", label: "Elapsed Time", value: healthManager.elapsedTimeStatus)
            MetricCard(icon: "waveform.path.ecg", label: "Steadiness", value: healthManager.steadinessStatus)
            MetricCard(icon: "arrow.left.and.right", label: "Asymmetry", value: healthManager.asymmetryStatus)
            MetricCard(icon: "figure.stand", label: "Double Support", value: healthManager.doubleSupportStatus)
            MetricCard(icon: "ruler.fill", label: "Step Length", value: healthManager.stepLengthStatus)
        }
    }

    private var controlButton: some View {
        Button {
            if healthManager.isTracking {
                healthManager.stopSession()
            } else {
                healthManager.requestAuthorizationAndStart()
            }
        } label: {
            Label(
                healthManager.isTracking ? "Stop Monitoring" : "Start Live Track",
                systemImage: healthManager.isTracking ? "stop.fill" : "figure.walk"
            )
            .font(.system(.title3, design: .rounded)).bold()
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(Capsule().fill(buttonGradient))
            .shadow(color: (healthManager.isTracking ? Color.red : Theme.brandTeal).opacity(0.35), radius: 10, y: 5)
        }
    }

    private var buttonGradient: LinearGradient {
        if healthManager.isTracking {
            return LinearGradient(
                colors: [Color(red: 0.95, green: 0.33, blue: 0.33), Color(red: 0.80, green: 0.16, blue: 0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        return Theme.brandGradient
    }

    // MARK: - Derived values

    /// Break risk as an integer, parsed from the shared "NN%" status string.
    private var riskValue: Int {
        Int(healthManager.riskScoreStatus.filter(\.isNumber)) ?? 0
    }

    private var riskColor: Color {
        switch riskValue {
        case ..<40: return Theme.brandGreen
        case 40..<70: return .orange
        default: return .red
        }
    }
}

// MARK: - Brand theme

enum Theme {
    static let brandGreen = Color(red: 0.22, green: 0.86, blue: 0.52)
    static let brandTeal = Color(red: 0.02, green: 0.62, blue: 0.47)

    static let brandGradient = LinearGradient(
        colors: [brandGreen, brandTeal],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let background = Color(.systemGroupedBackground)
    static let card = Color(.secondarySystemGroupedBackground)
    static let shadow = Color.black.opacity(0.06)
}

// MARK: - Logo

/// Reusable Walking Buddy mark: two figures striding together (a person and a
/// smaller amber "buddy") with a heart, on the brand gradient badge.
struct WalkingBuddyLogo: View {
    var size: CGFloat = 52

    private static let buddyAmber = Color(red: 1.0, green: 0.76, blue: 0.29)

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.brandGradient)
            .frame(width: size, height: size)
            .overlay {
                ZStack {
                    Image(systemName: "figure.walk")
                        .font(.system(size: size * 0.56, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: -size * 0.11, y: size * 0.03)
                    Image(systemName: "figure.walk")
                        .font(.system(size: size * 0.36, weight: .bold))
                        .foregroundStyle(Self.buddyAmber)
                        .offset(x: size * 0.16, y: size * 0.10)
                    Image(systemName: "heart.fill")
                        .font(.system(size: size * 0.16, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: size * 0.20, y: -size * 0.20)
                }
            }
            .shadow(color: Theme.brandTeal.opacity(0.35), radius: size * 0.12, y: size * 0.06)
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let isTracking: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isTracking ? Theme.brandGreen : Color.secondary)
                .frame(width: 9, height: 9)
            Text(isTracking ? "Monitoring Live" : "Not Tracking")
                .font(.subheadline).bold()
                .foregroundStyle(isTracking ? Theme.brandTeal : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background((isTracking ? Theme.brandGreen : Color.secondary).opacity(0.12), in: Capsule())
    }
}

// MARK: - Break-risk ring

struct RiskRing: View {
    let fraction: Double
    let percentText: String
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 18)
            Circle()
                .trim(from: 0, to: max(0, min(fraction, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: fraction)
            VStack(spacing: 2) {
                Text(percentText)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text("Break Risk")
                    .font(.caption).bold()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Metric card

struct MetricCard: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.brandTeal)
                .frame(width: 34, height: 34)
                .background(Theme.brandGreen.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(value)
                .font(.system(.title3, design: .rounded)).bold()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Theme.shadow, radius: 8, y: 4)
    }
}

#Preview {
    ContentView()
}
