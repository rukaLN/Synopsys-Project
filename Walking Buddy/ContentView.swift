import SwiftUI
import HealthKit

struct ContentView: View {
    @ObservedObject private var healthManager = HealthKitManager.shared
    @State private var showingRiskInfo = false
    @State private var showingWatchSyncPrompt = false
    @State private var showingWatchConnect = false
    /// Shows the Apple Watch setup screen once, the first time the app is opened.
    @AppStorage("hasSeenWatchSetup") private var hasSeenWatchSetup = false

    var body: some View {
        // The alert sits on the TabView so it appears whichever tab is showing.
        TabView {
            monitor
                .tabItem { Label("Monitor", systemImage: "figure.walk") }
            HistoryView()
                .tabItem { Label("History", systemImage: "chart.line.uptrend.xyaxis") }
        }
        .tint(Theme.brandTeal)
        .onAppear {
            HapticsManager.prepare()
            healthManager.refreshNotificationStatus()
            healthManager.clearOrphanedLiveActivitiesIfIdle()
            healthManager.clearWidgetSnapshotIfIdle()
            healthManager.refreshWatchAvailability()
            if !hasSeenWatchSetup {
                hasSeenWatchSetup = true
                showingWatchConnect = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            healthManager.refreshNotificationStatus()
            healthManager.refreshWatchAvailability()
        }
        .alert(isPresented: $healthManager.triggersAlert) {
            Alert(
                title: Text("Time to Rest!"),
                message: Text(healthManager.alertMessage),
                dismissButton: .default(Text("OK, I am sitting")) {
                    HapticsManager.prepare()
                    healthManager.pauseSession()
                }
            )
        }
    }

    // MARK: - Sections

    private var monitor: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                if healthManager.notificationsDenied { notificationsBanner }
                if healthManager.isTracking && healthManager.locationNeedsAlways { locationBanner }
                riskHero
                controlButton
                metricsGrid
                watchSyncButton
                healthAccessButton
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showingRiskInfo) {
            // "Active" when a Watch is connected (paired + app installed) or already
            // streaming live — either way heart rate is part of the walk's score.
            BreakRiskInfoView(heartRateActive: healthManager.isWatchSynced || healthManager.hasPairedWatch)
        }
        .sheet(isPresented: $showingWatchConnect) {
            WatchConnectView()
        }
        .alert("Manage Health Access", isPresented: $healthManager.healthAccessNeedsSettings) {
            Button("Open Health App") { openHealthApp() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Walking Buddy has already requested Health access, so iOS won\u{2019}t show the prompt again here. If any walk data is missing, re-enable it in the Health app \u{2192} Sharing \u{2192} Apps \u{2192} Walking Buddy.")
        }
        .confirmationDialog("Do you have your Apple Watch with you?", isPresented: $showingWatchSyncPrompt, titleVisibility: .visible) {
            Button("Yes \u{2014} start on both") { healthManager.startWithWatch() }
            Button("No \u{2014} iPhone only") { healthManager.startWithoutWatch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wear your Apple Watch and we\u{2019}ll add live heart rate and active energy to this walk.")
        }
    }

    /// Start a walk. If a synced Apple Watch is available, ask whether the user has it
    /// with them before starting on both devices.
    private func startTracking() {
        healthManager.refreshWatchAvailability()
        if healthManager.hasPairedWatch {
            showingWatchSyncPrompt = true
        } else {
            healthManager.startWithoutWatch()
        }
    }

    private var notificationsBanner: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
            Label("Notifications are off, so you won't be alerted while the phone is locked. Tap to turn them on.",
                  systemImage: "bell.slash.fill")
                .font(.footnote).bold()
                .multilineTextAlignment(.leading)
                .foregroundStyle(.white)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var locationBanner: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
            Label("Set Location to \u{201C}Always\u{201D} so Walking Buddy keeps monitoring during a call or with the screen off. Tap to fix.",
                  systemImage: "location.slash.fill")
                .font(.footnote).bold()
                .multilineTextAlignment(.leading)
                .foregroundStyle(.white)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

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
            Button {
                healthManager.refreshWatchAvailability()
                showingRiskInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.brandTeal)
            }
            .accessibilityLabel("How break risk is calculated")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var riskHero: some View {
        VStack(spacing: 18) {
            StatusPill(isTracking: healthManager.isTracking, isPaused: healthManager.isPaused)

            RiskRing(
                fraction: Double(riskValue) / 100,
                percentText: healthManager.riskScoreStatus,
                color: riskColor
            )
            .frame(width: 200, height: 200)

            elapsedTime

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

    /// Prominent elapsed-time readout shown under the Break Risk ring. Tinted by
    /// the same green/orange/red scale as the ring using the duration sub-score.
    private var elapsedTime: some View {
        let durationRisk = healthManager.metricRisks["duration"]
        let tint = durationRisk.map { Theme.riskColor($0) } ?? .primary
        return HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(healthManager.elapsedTimeStatus)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text("elapsed")
                .font(.subheadline).bold()
                .foregroundStyle(.secondary)
        }
    }

    private var metricsGrid: some View {
        let risks = healthManager.metricRisks
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                MetricCard(icon: "speedometer", label: "Live Speed", value: healthManager.currentPaceStatus, risk: risks["speed"])
                MetricCard(icon: "metronome.fill", label: "Cadence", value: healthManager.cadenceStatus, risk: risks["cadence"])
                MetricCard(icon: "figure.walk", label: "Steps", value: healthManager.stepsStatus)
                MetricCard(icon: "location.fill", label: "Distance", value: healthManager.distanceStatus)
                MetricCard(icon: "figure.stairs", label: "Flights", value: healthManager.flightsStatus, risk: risks["flights"])
                MetricCard(icon: "waveform.path.ecg", label: "Steadiness", value: healthManager.steadinessStatus, risk: risks["steadiness"])
                MetricCard(icon: "arrow.left.and.right", label: "Asymmetry", value: healthManager.asymmetryStatus, risk: risks["asymmetry"])
                MetricCard(icon: "figure.stand", label: "Double Support", value: healthManager.doubleSupportStatus, risk: risks["doubleSupport"])
                MetricCard(icon: "ruler.fill", label: "Step Length", value: healthManager.stepLengthStatus, risk: risks["stepLength"])
                MetricCard(icon: "heart.fill", label: "Heart Rate", value: healthManager.heartRateStatus, risk: risks["heartRate"])
                MetricCard(icon: "flame.fill", label: "Active Energy", value: healthManager.activeEnergyStatus, risk: risks["activeEnergy"])
            }
            Text("Steadiness, asymmetry, double support and step length are live estimates from your phone\u{2019}s motion sensors, not clinical Apple Health readings. Heart rate and active energy require a synced Apple Watch.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var controlButton: some View {
        if healthManager.isPaused {
            // After "I am sitting" the walk is paused — resume or stop.
            HStack(spacing: 12) {
                pillButton("Resume", icon: "play.fill", gradient: Theme.brandGradient, glow: Theme.brandTeal) {
                    healthManager.resumeSession()
                }
                pillButton("Stop", icon: "stop.fill", gradient: Self.stopGradient, glow: .red) {
                    healthManager.stopSession()
                }
            }
        } else if healthManager.isTracking {
            HStack(spacing: 12) {
                pillButton("Pause", icon: "pause.fill", gradient: Theme.brandGradient, glow: Theme.brandTeal) {
                    healthManager.pauseSession()
                }
                pillButton("Stop", icon: "stop.fill", gradient: Self.stopGradient, glow: .red) {
                    healthManager.stopSession()
                }
            }
        } else {
            pillButton("Start Live Track", icon: "figure.walk", gradient: Theme.brandGradient, glow: Theme.brandTeal) {
                startTracking()
            }
        }
    }

    /// Lets the user open the Apple Watch setup screen anytime — e.g. if they get a
    /// Watch after already installing the app. Reflects the current connection state.
    private var watchSyncButton: some View {
        let connected = healthManager.watchAvailability == .connected
        return Button {
            healthManager.refreshWatchAvailability()
            showingWatchConnect = true
        } label: {
            Label(connected ? "Apple Watch Connected" : "Sync Apple Watch",
                  systemImage: connected ? "applewatch.radiowaves.left.and.right" : "applewatch")
                .font(.subheadline).bold()
                .foregroundStyle(connected ? Theme.brandTeal : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.card, in: Capsule())
        }
    }

    /// Lets the user re-check or re-enable Health access anytime, so the first-run prompt
    /// isn't the only chance to grant it.
    private var healthAccessButton: some View {
        Button {
            healthManager.manageHealthAccess()
        } label: {
            Label("Health Access", systemImage: "heart.text.square")
                .font(.subheadline).bold()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.card, in: Capsule())
        }
    }

    /// Opens the Health app so the user can re-enable Walking Buddy's categories, falling
    /// back to the app's Settings page if the Health app can't be opened directly.
    private func openHealthApp() {
        guard let url = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(url) { success in
            if !success, let settings = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settings)
            }
        }
    }

    private func pillButton(_ title: String, icon: String, gradient: LinearGradient,
                            glow: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(.title3, design: .rounded)).bold()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .background(Capsule().fill(gradient))
                .shadow(color: glow.opacity(0.35), radius: 10, y: 5)
        }
    }

    private static let stopGradient = LinearGradient(
        colors: [Color(red: 0.95, green: 0.33, blue: 0.33), Color(red: 0.80, green: 0.16, blue: 0.22)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: - Derived values

    /// Break risk as an integer, parsed from the shared "NN%" status string.
    private var riskValue: Int {
        Int(healthManager.riskScoreStatus.filter(\.isNumber)) ?? 0
    }

    private var riskColor: Color {
        Theme.riskColor(Double(riskValue) / 100)
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

    /// Shared green → orange → red scale used by the break-risk ring and every
    /// metric card, so a "dangerous" reading looks the same everywhere. `fraction`
    /// is a 0...1 risk sub-score (higher = more dangerous).
    static func riskColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.4: return brandGreen
        case ..<0.7: return .orange
        default: return .red
        }
    }
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
    var isPaused: Bool = false

    private var text: String {
        if isPaused { return "Paused — Resting" }
        return isTracking ? "Monitoring Live" : "Not Tracking"
    }

    private var color: Color {
        if isPaused { return .orange }
        return isTracking ? Theme.brandGreen : Color.secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(text)
                .font(.subheadline).bold()
                .foregroundStyle(isPaused ? .orange : (isTracking ? Theme.brandTeal : Color.secondary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(color.opacity(0.12), in: Capsule())
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
    /// 0...1 danger sub-score for this metric. When present, the value is tinted
    /// green/orange/red like the break-risk ring; `nil` metrics stay neutral.
    var risk: Double? = nil

    private var valueColor: Color {
        guard let risk else { return .primary }
        return Theme.riskColor(risk)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.brandTeal)
                .frame(width: 34, height: 34)
                .background(Theme.brandGreen.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(value)
                .font(.system(.title3, design: .rounded)).bold()
                .foregroundStyle(valueColor)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)

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

// MARK: - Break-risk explainer

/// Explains how the composite break-risk score is calculated, mirroring the live
/// ``BreakRiskModel`` (weights, reference values, and threshold).
struct BreakRiskInfoView: View {
    /// Whether heart rate (an Apple Watch–only signal) is currently part of the
    /// equation. Drives the sync banner and how the heart-rate row is shown.
    var heartRateActive: Bool = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var calibration = SensorCalibration.shared
    @State private var confirmingCalibrationReset = false
    private let model = BreakRiskModel()

    private var breakPercent: Int { Int((model.breakThreshold * 100).rounded()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Walking Buddy blends every available walking signal into one \u{201C}Break Risk\u{201D} score between 0% and 100%. Each signal gets a 0\u{2013}1 sub-score for how far it has drifted from a senior-safe range, then they\u{2019}re combined as a weighted average.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    equationCard
                    syncStatusCard
                    calibrationCard
                    legendCard
                    metricsCard

                    Text("Metrics that aren\u{2019}t available (for example heart rate without a synced Apple Watch) simply drop out of both sums, so the score stays balanced on whichever signals you do have.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("How Break Risk Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Reset Apple Watch calibration?", isPresented: $confirmingCalibrationReset, titleVisibility: .visible) {
                Button("Reset calibration", role: .destructive) { calibration.reset() }
            } message: {
                Text("Walking Buddy will forget how your iPhone differs from your Apple Watch and relearn it over your next few shared walks. Your walk history isn\u{2019}t affected.")
            }
        }
    }

    private var equationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The equation")
                .font(.headline)
            Text("risk = ( \u{03A3} w\u{1D62} \u{00D7} s\u{1D62} ) / ( \u{03A3} w\u{1D62} )")
                .font(.system(.body, design: .monospaced)).bold()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
                .background(Theme.brandGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("w\u{1D62} is each metric\u{2019}s weight (how much it matters) and s\u{1D62} is its 0\u{2013}1 sub-score. A break is recommended once the risk reaches \(breakPercent)%.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var syncStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: heartRateActive ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(heartRateActive ? Theme.brandTeal : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(heartRateActive ? "Apple Watch connected" : "No Apple Watch sync")
                    .font(.subheadline).bold()
                Text(heartRateActive
                     ? "Heart rate is included in your Break Risk score while you walk with your Apple Watch."
                     : "Heart rate is excluded — your score uses the remaining signals. Sync an Apple Watch to include it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Apple Watch calibration", systemImage: "wand.and.stars")
                .font(.headline)
            if calibration.isActive {
                Text("Walking Buddy has tuned this iPhone\u{2019}s sensors toward your Apple Watch from your shared walks, so iPhone-only walks read more like the Watch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(SensorCalibration.Metric.allCases, id: \.self) { metric in
                    if let adjustment = calibration.adjustmentDescription(metric) {
                        HStack {
                            Text(metric.displayName).font(.subheadline)
                            Spacer()
                            Text(adjustment)
                                .font(.caption).bold()
                                .foregroundStyle(Theme.brandTeal)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.brandGreen.opacity(0.14), in: Capsule())
                        }
                    }
                }
                Button("Reset calibration", role: .destructive) { confirmingCalibrationReset = true }
                    .font(.footnote)
                    .padding(.top, 2)
                Text("Clears what Walking Buddy has learned and returns the iPhone to its own raw readings. Your walk history is kept, and it relearns over your next few \u{201C}start on both\u{201D} walks.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Take a few walks with your Apple Watch (\u{201C}start on both\u{201D}) and Walking Buddy will learn how this iPhone\u{2019}s sensors differ from the Watch, then adjust iPhone-only walks to match \u{2014} usually within 3\u{2013}5 walks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var legendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reading the colors")
                .font(.headline)
            legendRow(Theme.riskColor(0.1), "Below 40% — in a safe range")
            legendRow(Theme.riskColor(0.5), "40–70% — getting risky")
            legendRow(Theme.riskColor(0.8), "70% and up — dangerous")
            Text("The same scale colors the big ring and each metric below.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func legendRow(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(text).font(.subheadline)
        }
    }

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What goes into it")
                .font(.headline)
            ForEach(model.metricInfo) { info in
                let inactive = info.name == "Heart rate" && !heartRateActive
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(info.name).font(.subheadline).bold()
                        Spacer()
                        Text(inactive ? "Requires Apple Watch Sync" : "weight \(String(format: "%g", info.weight))")
                            .font(.caption).bold()
                            .foregroundStyle(inactive ? Color.secondary : Theme.brandTeal)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background((inactive ? Color.secondary : Theme.brandGreen).opacity(0.14), in: Capsule())
                    }
                    Text(info.rule)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .opacity(inactive ? 0.5 : 1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Apple Watch connect / setup

/// Pairing-style setup screen for the Apple Watch. The WatchConnectivity link is
/// automatic once both apps are installed, so this screen *reflects* the live
/// connection state and guides the user when something is missing. Shown once on
/// first run and reachable anytime from the "Sync Apple Watch" button.
struct WatchConnectView: View {
    @ObservedObject private var healthManager = HealthKitManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pollTimer: Timer?

    private var state: HealthKitManager.WatchAvailability { healthManager.watchAvailability }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    watchGraphic
                    statusBlock
                    if state != .connected { stepsBlock }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Apple Watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(state == .connected ? "Done" : "Close") { dismiss() }
                }
            }
        }
        .onAppear {
            healthManager.refreshWatchAvailability()
            // Poll while visible so the status updates live as the Watch connects.
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                healthManager.refreshWatchAvailability()
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private var accent: Color {
        switch state {
        case .connected: return Theme.brandGreen
        case .appNotInstalled: return .orange
        case .noWatch: return .secondary
        }
    }

    private var watchGraphic: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.14))
                .frame(width: 150, height: 150)
            Image(systemName: "applewatch")
                .font(.system(size: 72, weight: .regular))
                .foregroundStyle(accent)
            if state == .connected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.brandGreen)
                    .background(Circle().fill(Theme.background))
                    .offset(x: 50, y: 50)
            }
        }
        .padding(.top, 12)
    }

    private var statusBlock: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title2).bold()
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch state {
        case .connected: return "Apple Watch Connected"
        case .appNotInstalled: return "Add Walking Buddy to your Watch"
        case .noWatch: return "No Apple Watch Found"
        }
    }

    private var subtitle: String {
        switch state {
        case .connected:
            return "You\u{2019}re all set. Heart rate and active energy will sync automatically during your walks, and starting a walk on one device starts it on both."
        case .appNotInstalled:
            return "Your Apple Watch is paired, but Walking Buddy isn\u{2019}t installed on it yet. Install it to sync heart rate and energy."
        case .noWatch:
            return "Walking Buddy works great on its own. Pair an Apple Watch to add live heart rate and active energy."
        }
    }

    private var stepsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How to connect")
                .font(.headline)
            if state == .appNotInstalled {
                step(1, "Open the Apple Watch app on your iPhone.")
                step(2, "Scroll to \u{201C}Available Apps\u{201D} and tap Install next to Walking Buddy.")
                step(3, "Come back here \u{2014} it\u{2019}ll connect automatically.")
            } else {
                step(1, "Open the Apple Watch app on your iPhone.")
                step(2, "Follow the steps to pair your Apple Watch.")
                step(3, "Install Walking Buddy on the Watch, then return here.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline).bold()
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.brandTeal))
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ContentView()
}

#Preview("Apple Watch Connect") {
    WatchConnectView()
}

#Preview("Break Risk Info") {
    BreakRiskInfoView()
}
