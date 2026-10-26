import Combine
import HealthKit
import SwiftUI
import UserNotifications
import WidgetKit

#if os(iOS)
import CoreMotion
import CoreLocation
import ActivityKit
import UIKit
#endif

/// Drives walking monitoring for both platforms.
///
/// The published state, the "needs a break" equation (``BreakRiskModel``), the
/// walk-duration timer, and the alerting are all **shared**. The live sensor
/// source is **platform-specific**:
///
/// - On **iPhone** we read live pace/cadence/steps/distance from `CMPedometer`
///   and pull recent gait quality (steadiness, asymmetry, double-support,
///   step length) from HealthKit as a baseline.
/// - On **Apple Watch** we run a real `HKWorkoutSession` + `HKLiveWorkoutBuilder`
///   and feed live heart rate, active energy, distance and steps into the model.
final class HealthKitManager: NSObject, ObservableObject {

    // MARK: - Shared published state

    @Published var isTracking = false
    @Published var isPaused = false
    @Published var monitoringMessage = "Start monitoring when the senior begins walking."
    @Published var alertMessage = "Your walking pattern suggests fatigue. Please find a safe place to sit down for a few minutes."
    @Published var triggersAlert = false
    /// True when notifications are switched off, so alerts only reach the user while the app is open.
    @Published var notificationsDenied = false
    /// True while a walk is running but location isn't "Always" — background tracking
    /// (screen off / during calls) needs Always to stay alive.
    @Published var locationNeedsAlways = false

    @Published var stepsStatus = "0"
    @Published var distanceStatus = "0 m"
    @Published var flightsStatus = "0"
    @Published var elapsedTimeStatus = "0:00"
    @Published var riskScoreStatus = "0%"
    /// Per-metric sub-scores (0...1) from the latest ``BreakRiskModel`` evaluation,
    /// keyed by metric name, so each metric card can color itself like the risk ring.
    @Published var metricRisks: [String: Double] = [:]

    // iPhone gait context (from HealthKit).
    @Published var currentPaceStatus = "Unknown"
    @Published var cadenceStatus = "Unknown"
    @Published var steadinessStatus = "Unknown"
    @Published var asymmetryStatus = "Unknown"
    @Published var doubleSupportStatus = "Unknown"
    @Published var stepLengthStatus = "Unknown"

    // Apple Watch live workout metrics.
    @Published var heartRateStatus = "–"
    @Published var activeEnergyStatus = "–"

    // MARK: - Cross-device sync state

    /// The Apple Watch connection state as seen from the iPhone.
    enum WatchAvailability {
        case connected        // paired + our watch app installed → ready to sync
        case appNotInstalled  // watch paired, but Walking Buddy isn't on it yet
        case noWatch          // no Apple Watch paired to this iPhone
    }
    @Published var watchAvailability: WatchAvailability = .noWatch

    /// iPhone-side: true when a paired Apple Watch has the app installed, so we can
    /// offer to sync. Refreshed when the Monitor screen appears.
    @Published var hasPairedWatch = false
    /// True while live Watch metrics (heart rate / energy) are flowing in. When this
    /// is false the iPhone shows "Requires Apple Watch Sync" and heart rate drops out
    /// of the break-risk equation.
    @Published var isWatchSynced = false

    /// True when the current walk was started with the Apple Watch (either from the
    /// iPhone's "start on both" or started on the watch). While true, the Watch's
    /// streamed readings override the iPhone's own pedometer/gait on the phone.
    private var startedWithWatch = false

    /// Set when the user taps "Health Access" but the system won't show the permission
    /// sheet again (they already answered it once). The UI uses this to guide them to
    /// re-enable access in the Health app, since iOS can't re-prompt or deep-link there.
    @Published var healthAccessNeedsSettings = false

    /// Placeholder shown for Watch-only values when no Watch is syncing.
    static let requiresWatchText = "Requires Apple Watch Sync"

    // MARK: - Singleton

    /// Shared instance so WatchConnectivity (via ``WalkHistory``) can drive the same
    /// manager the UI observes — needed for remote start/stop and live metric sync.
    static let shared = HealthKitManager()

    private override init() {
        super.init()
        setupConnectivityHooks()
    }

    /// Wires the WatchConnectivity callbacks to this manager. Remote start/stop act
    /// only when they change state, and pass `fromRemote: true` so they don't echo a
    /// command back to the sender.
    private func setupConnectivityHooks() {
        let history = WalkHistory.shared
        history.onRemoteStart = { [weak self] in
            guard let self, !self.isTracking else { return }
            // A remote start is driven by the Apple Watch, so its readings win.
            self.startedWithWatch = true
            self.requestAuthorizationAndStart(fromRemote: true)
        }
        history.onRemoteStop = { [weak self] in
            guard let self, self.isTracking else { return }
            self.stopSession(fromRemote: true)
        }
        history.onRemotePause = { [weak self] in
            guard let self, self.isTracking, !self.isPaused else { return }
            self.pauseSession(fromRemote: true)
        }
        history.onRemoteResume = { [weak self] in
            guard let self, self.isPaused else { return }
            self.resumeSession(fromRemote: true)
        }
        #if os(iOS)
        history.onLiveMetrics = { [weak self] metrics in
            self?.applyWatchLiveMetrics(metrics)
        }
        #endif
    }

    // MARK: - Shared dependencies & tuning

    private let healthStore = HKHealthStore()
    private let notificationCenter = UNUserNotificationCenter.current()
    private let riskModel = BreakRiskModel()
    /// Live IMU gait estimator. Runs on both platforms — iPhone (near the waist)
    /// and Apple Watch (on the wrist, where it's rougher).
    private let gaitAnalyzer = GaitAnalyzer()

    /// App Group shared with the Lock Screen widget extension. Must match the
    /// group ID enabled on both the app and widget targets in Xcode.
    static let appGroupID = "group.Walking-Buddy.shared"

    /// While a metric stays tripped the alert repeats this often. Recovering, or
    /// stopping to rest, re-arms it so the next trip always alerts straight away.
    private let alertRepeatInterval: TimeInterval = 120
    /// No new steps or distance for this long means the person has stopped walking.
    private let idleThreshold: TimeInterval = 15
    /// Seniors are advised to rest after a continuous walk of this length.
    private let maximumWalkDuration: TimeInterval = 30 * 60
    /// A finished walk must last at least this long to be saved to History — short
    /// accidental walks don't make a meaningful trend. Drives the History/trends.
    private let minimumWalkDurationForHistory: TimeInterval = 5 * 60

    /// Hold time H: the risk ring must stay at/above the break threshold this long
    /// continuously to alarm. Lengthened for the peak-blended score — a single signal
    /// can now lift the composite quickly, so we require it to genuinely persist (not a
    /// momentary spike) before alerting.
    private let sustainedHoldDuration: TimeInterval = 6
    /// First instant the composite risk (the ring) crossed the break threshold
    /// (reset when it drops back below). Drives the sustained-dwell equation.
    private var riskTripStart: Date?

    // MARK: - Shared latest readings (inputs to the equation)

    private var latestWalkingSpeed: Double?
    private var latestCadence: Double?
    private var latestStepLength: Double?
    private var latestWalkingSteadiness: Double?
    /// Raw step-time variability (CV) from the IMU — stored per walk to build the
    /// user's personal steadiness baseline (see ``SteadinessCalibration``).
    private var latestStepVariability: Double?
    private var latestAsymmetry: Double?
    private var latestDoubleSupport: Double?
    private var latestHeartRateFraction: Double?
    private var latestHeartRate: Double?
    /// kcal of active energy burned this walk. On watch it comes from the workout; on
    /// iPhone it's mirrored from the watch. Feeds the break-risk equation's exertion term.
    private var latestActiveEnergyKcal: Double?
    /// iPhone-side: when live Watch metrics last arrived, used to detect a dropped sync.
    private var lastWatchMetricsDate = Date.distantPast
    /// Sync is considered lost if no Watch metrics arrive for this long.
    private let watchSyncTimeout: TimeInterval = 10
    private var latestRisk = 0.0
    private var latestStepCount = 0 { didSet { if latestStepCount > oldValue { lastMovementDate = Date() } } }
    private var latestDistance = 0.0 { didSet { if latestDistance > oldValue { lastMovementDate = Date() } } }
    private var latestFlights = 0.0
    private var lastMovementDate = Date()
    private var lastAlertDate: Date?
    private var recorder = WalkRecorder()

    // Within-walk fatigue detection: watch pace/cadence/steadiness drift worse
    // than earlier in the SAME walk (the person tiring), not just a single low
    // reading, and nudge a rest.
    private struct GaitSample { let t: TimeInterval; let speed: Double?; let cadence: Double?; let steadiness: Double? }
    private var gaitHistory: [GaitSample] = []
    private var lastFatigueAlert: Date?
    private let fatigueMinWalk: TimeInterval = 3 * 60

    private var isWalking: Bool { Date().timeIntervalSince(lastMovementDate) < idleThreshold }

    /// Enough walking to trust the readings: steps, or distance (~0.7 m a step) where a sensor doesn't report steps.
    private var hasWalkedEnough: Bool {
        latestStepCount >= riskModel.minimumStepsBeforeAlert
            || latestDistance >= Double(riskModel.minimumStepsBeforeAlert) * 0.7
    }

    // MARK: - Duration tracking

    private var clockTimer: Timer?
    private var accumulatedWalkTime: TimeInterval = 0
    private var segmentStartDate: Date?
    private var nextLongWalkWarning: TimeInterval = .infinity

    private var currentElapsed: TimeInterval {
        var total = accumulatedWalkTime
        if let segmentStartDate, isTracking, !isPaused {
            total += Date().timeIntervalSince(segmentStartDate)
        }
        return total
    }

    // MARK: - iOS-only sensor state

    #if os(iOS)
    private let pedometer = CMPedometer()
    private var simulatorTimer: Timer?
    private var pedometerStart: Date?
    private let locationManager = CLLocationManager()
    /// Holds an `Activity<WalkActivityAttributes>` while a walk is running.
    /// Stored as `Any?` so the property doesn't need availability annotation.
    private var liveActivity: Any?
    /// The phone's own *raw* (uncalibrated) sensor readings. Kept so calibration can
    /// always compare raw phone values against a reference (Apple Watch or Apple
    /// Health) without feeding corrected values back into the learner.
    private var phoneRawSpeed: Double?
    private var phoneRawCadence: Double?
    private var phoneRawDistance: Double?
    private var phoneRawStepLength: Double?
    private var phoneRawSteadiness: Double?
    /// Throttle for comparing live readings against Apple Health's latest values.
    private var lastHealthCalibration = Date.distantPast
    private let healthCalibrationInterval: TimeInterval = 45
    /// Calibration source priority, applied once *per walk* (not per sample) so the
    /// phone eases toward the reference over several walks — roughly matched by the
    /// 3rd–5th walk. Priority order:
    ///   1. Same-walk iPhone-vs-Apple-Watch pairing (strongest) — the primary signal.
    ///   2. Cross-walk: typical iPhone-only vs Watch-only values across 3+ walks each.
    ///   3. Apple Health latest values at time of use (lightest).
    /// Steadiness is special-cased to a strong weight for every source, since our
    /// instant-steadiness estimate is uncertain (Apple Health counts equally there).
    private static let watchCalibrationWeight = 0.5
    private static let crossWalkCalibrationWeight = 0.2
    private static let healthCalibrationWeight = 0.12
    private static let steadinessCalibrationWeight = 0.5
    /// Minimum paired readings within a walk before it updates the calibration.
    private let calibrationMinSamples = 3
    /// Minimum walks of each kind (iPhone / Watch) before cross-walk calibration runs.
    private let crossWalkMinimumWalks = 3
    /// Per-metric running sums of (phone, reference) readings for the current walk,
    /// committed to ``SensorCalibration`` as a single EMA step when the walk ends.
    private var calibrationAcc: [SensorCalibration.Metric: (phoneSum: Double, refSum: Double, count: Int)] = [:]
    #endif

    // MARK: - watchOS-only workout state

    #if os(watchOS)
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var maxHeartRate: Double = 220 - 70   // updated from the user's age
    #endif

    // MARK: - Lifecycle (shared)

    func requestAuthorizationAndStart(fromRemote: Bool = false) {
        requestNotificationAuthorization()
        requestHealthAuthorization { [weak self] in
            self?.startSession(fromRemote: fromRemote)
        }
    }

    /// Call at launch. If we're not actively tracking, clear any Live Activity a
    /// previous session left running after the app was swiped away — otherwise it
    /// lingers as a "ghost" card and the next walk stacks a second one.
    func clearOrphanedLiveActivitiesIfIdle() {
        #if os(iOS)
        if #available(iOS 16.2, *), !isTracking {
            endAllLiveActivities()
        }
        #endif
    }

    func stopSession(fromRemote: Bool = false) {
        // Tell the other device to stop too, unless this stop was itself remote-driven.
        if !fromRemote { WalkHistory.shared.sendCommand("stop") }
        let saved = saveWalk()
        #if os(iOS)
        // Fold this walk's background phone-vs-reference readings into the calibration.
        commitCalibration()
        #endif
        isTracking = false
        isPaused = false
        triggersAlert = false
        resetLatestReadings()
        stopClock()
        accumulatedWalkTime = 0
        segmentStartDate = nil
        elapsedTimeStatus = "0:00"
        riskScoreStatus = "0%"
        stopSensors()
        monitoringMessage = saved ? "Monitoring stopped. Walk saved to History." : "Monitoring stopped."
        publishWidgetSnapshot()

        #if os(iOS)
        if #available(iOS 16.2, *) { endAllLiveActivities() }
        #endif
    }

    func pauseSession(fromRemote: Bool = false) {
        if !fromRemote { WalkHistory.shared.sendCommand("pause") }
        isPaused = true
        if let segmentStartDate {
            accumulatedWalkTime += Date().timeIntervalSince(segmentStartDate)
        }
        segmentStartDate = nil
        riskTripStart = nil
        stopClock()
        pauseSensors()
        monitoringMessage = "Monitoring paused. Data preserved."
        // Publish a paused snapshot so the widget/complication shows "Paused" with the
        // frozen values instead of going stale and resetting to zero.
        publishWidgetSnapshot()
    }

    func resumeSession(fromRemote: Bool = false) {
        if !fromRemote { WalkHistory.shared.sendCommand("resume") }
        isPaused = false
        isTracking = true
        segmentStartDate = Date()
        lastMovementDate = Date()
        startClock()
        resumeSensors()
        monitoringMessage = "Resumed live monitoring."
        publishWidgetSnapshot()
    }

    private func startSession(fromRemote: Bool = false) {
        isTracking = true
        isPaused = false
        nextLongWalkWarning = maximumWalkDuration
        lastAlertDate = nil
        lastMovementDate = Date()
        recorder = WalkRecorder()
        riskTripStart = nil
        accumulatedWalkTime = 0
        segmentStartDate = Date()
        stepsStatus = "0"
        distanceStatus = "0 m"
        flightsStatus = "0"
        elapsedTimeStatus = "0:00"
        riskScoreStatus = "0%"
        gaitHistory.removeAll()
        lastFatigueAlert = nil
        monitoringMessage = "Reading live walking data from the sensors."

        startClock()
        startSensors()

        #if os(watchOS)
        // The Watch drives the iPhone: ask it to start too (unless it started us).
        if !fromRemote { WalkHistory.shared.sendCommand("start") }
        #endif

        #if os(iOS)
        if #available(iOS 16.2, *) { startLiveActivity() }
        #endif
    }

    private func resetLatestReadings() {
        latestWalkingSpeed = nil
        latestCadence = nil
        latestStepLength = nil
        latestWalkingSteadiness = nil
        latestStepVariability = nil
        latestAsymmetry = nil
        latestDoubleSupport = nil
        latestHeartRateFraction = nil
        latestHeartRate = nil
        latestActiveEnergyKcal = nil
        latestRisk = 0
        latestStepCount = 0
        latestDistance = 0
        latestFlights = 0
        riskTripStart = nil
        metricRisks = [:]
        gaitHistory.removeAll()
        lastFatigueAlert = nil
        isWatchSynced = false
        lastWatchMetricsDate = .distantPast
        startedWithWatch = false
    }

    /// Stores the finished walk in History. Accidental starts (hardly any walking)
    /// and walks shorter than ``minimumWalkDurationForHistory`` are ignored.
    private func saveWalk() -> Bool {
        guard isTracking, hasWalkedEnough, currentElapsed >= minimumWalkDurationForHistory else { return false }
        #if os(iOS)
        // A walk started with the Apple Watch is owned by the Watch — it records the
        // canonical entry (with the Watch's values) and syncs it here, so the iPhone
        // doesn't save a duplicate of the same walk. Reported as saved either way.
        if startedWithWatch { return true }
        #endif
        WalkHistory.shared.add(recorder.finish(duration: currentElapsed, steps: latestStepCount, distance: latestDistance, flights: latestFlights))
        return true
    }

    // MARK: - Duration clock (shared)

    private func startClock() {
        clockTimer?.invalidate()
        // `.common` keeps the clock (and so the alerts) running while the screen is being scrolled.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickClock()
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func tickClock() {
        elapsedTimeStatus = Self.durationFormatter.string(from: currentElapsed) ?? "0:00"
        checkWalkDuration()
        checkWatchSyncStaleness()
        updateBreakRisk()
        checkFatigueTrend()
        sampleWalk()
        #if os(iOS)
        calibrateAgainstHealthIfDue()
        #endif
    }

    /// iPhone-side: if the Watch stops sending live metrics, drop the sync so heart
    /// rate leaves the equation and the Watch-only values revert to the placeholder.
    private func checkWatchSyncStaleness() {
        #if os(iOS)
        guard isWatchSynced else { return }
        guard Date().timeIntervalSince(lastWatchMetricsDate) > watchSyncTimeout else { return }
        isWatchSynced = false
        latestHeartRate = nil
        latestHeartRateFraction = nil
        heartRateStatus = Self.requiresWatchText
        activeEnergyStatus = Self.requiresWatchText
        #endif
    }

    /// iPhone-side: refresh the Apple Watch connection state, so the Start button and
    /// the connect screen know what to show.
    func refreshWatchAvailability() {
        #if os(iOS)
        let history = WalkHistory.shared
        if history.isWatchAppInstalled {
            watchAvailability = .connected
        } else if history.isWatchPaired {
            watchAvailability = .appNotInstalled
        } else {
            watchAvailability = .noWatch
        }
        hasPairedWatch = (watchAvailability == .connected)
        #endif
    }

    /// Fatigue = a downward *trend* within the walk, not a single low reading.
    /// If pace, cadence and steadiness have each drifted meaningfully worse than
    /// earlier in the same walk, nudge a rest (paced like the other alerts).
    private func checkFatigueTrend() {
        guard isWalking, currentElapsed >= fatigueMinWalk else { return }

        gaitHistory.append(GaitSample(t: currentElapsed, speed: latestWalkingSpeed,
                                      cadence: latestCadence, steadiness: latestWalkingSteadiness))
        gaitHistory.removeAll { $0.t < currentElapsed - 360 }   // keep ~6 min

        let earliest = gaitHistory.first?.t ?? currentElapsed
        guard currentElapsed - earliest >= 120 else { return }  // need ~2 min of spread

        let baseline = gaitHistory.filter { $0.t <= earliest + 60 }
        let recent = gaitHistory.filter { $0.t >= currentElapsed - 60 }
        guard baseline.count >= 3, recent.count >= 3 else { return }

        func avg(_ key: (GaitSample) -> Double?, _ xs: [GaitSample]) -> Double? {
            let vals = xs.compactMap(key)
            return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
        }

        // Lower pace / cadence / steadiness than early in the walk = worsening.
        var worsened = 0
        if let b = avg(\.speed, baseline), let r = avg(\.speed, recent), b > 0, r < b * 0.85 { worsened += 1 }
        if let b = avg(\.cadence, baseline), let r = avg(\.cadence, recent), b > 0, r < b * 0.85 { worsened += 1 }
        if let b = avg(\.steadiness, baseline), let r = avg(\.steadiness, recent), b > 0, r < b * 0.85 { worsened += 1 }

        guard worsened >= 2 else { return }
        if let last = lastFatigueAlert, Date().timeIntervalSince(last) < alertRepeatInterval { return }
        lastFatigueAlert = Date()
        let stairs = latestFlights >= 2 ? " after climbing stairs" : ""
        presentBreakAlert(message: "Your walking is slowing and becoming less steady\(stairs) — this can be a sign of fatigue. Please find a safe place to sit and rest.")
    }

    /// Warns again after every further `maximumWalkDuration` of walking, not just the first.
    private func checkWalkDuration() {
        guard currentElapsed >= nextLongWalkWarning else { return }
        nextLongWalkWarning = (floor(currentElapsed / maximumWalkDuration) + 1) * maximumWalkDuration
        let minutes = Int((currentElapsed / 60).rounded())
        presentBreakAlert(
            message: "You have been walking for about \(minutes) minutes. Please find a safe place to sit down and rest."
        )
    }

    /// One reading a second while walking, so time spent standing still doesn't dilute the walk's averages.
    private func sampleWalk() {
        guard isWalking else { return }
        recorder.sample(risk: latestRisk, speed: latestWalkingSpeed, cadence: latestCadence,
                        steadiness: latestWalkingSteadiness, asymmetry: latestAsymmetry,
                        doubleSupport: latestDoubleSupport, heartRate: latestHeartRate,
                        steadinessCV: latestStepVariability)
    }

    // MARK: - The "needs a break" equation (shared)

    /// Live steadiness from raw step-time variability, personalized to the user once
    /// they have enough walks (their steadiest walk anchors 100%). Falls back to the
    /// generic estimate until the baseline exists.
    private func calibratedSteadiness(variability cv: Double?, generic: Double?) -> Double? {
        if let cv, let calibration = WalkHistory.shared.steadinessCalibration {
            return calibration.steadiness(forCV: cv)
        }
        return generic
    }

    /// Refreshes the displayed/stored steadiness as an Apple-style composite of the
    /// live gait-quality signals (speed, step length, double support, asymmetry). It's
    /// a summary only — ``BreakRiskModel`` deliberately keeps it out of the risk score.
    private func updateCompositeSteadiness() {
        guard let steadiness = riskModel.compositeSteadiness(
            walkingSpeed: latestWalkingSpeed,
            stepLength: latestStepLength,
            doubleSupport: latestDoubleSupport,
            asymmetry: latestAsymmetry
        ) else { return }
        latestWalkingSteadiness = steadiness
        steadinessStatus = Self.percentFormatter.string(from: NSNumber(value: steadiness)) ?? "\(Int(steadiness * 100))%"
    }

    private func updateBreakRisk() {
        updateCompositeSteadiness()
        let inputs = BreakRiskModel.Inputs(
            walkingSpeed: latestWalkingSpeed,
            cadence: latestCadence,
            stepLength: latestStepLength,
            asymmetry: latestAsymmetry,
            doubleSupport: latestDoubleSupport,
            heartRateFraction: latestHeartRateFraction,
            durationFraction: currentElapsed / maximumWalkDuration,
            flightsClimbed: latestFlights,
            activeEnergy: latestActiveEnergyKcal,
            stepCount: latestStepCount
        )

        let result = riskModel.evaluate(inputs)
        latestRisk = result.score
        riskScoreStatus = "\(Int((result.score * 100).rounded()))%"
        var risks: [String: Double] = [:]
        for contribution in result.contributions { risks[contribution.metric] = contribution.score }
        metricRisks = risks
        publishWidgetSnapshot()

        // Alarm when the risk ring itself stays at/above the break threshold for
        // the full hold window, while the person is actually walking (stale
        // readings from a rest don't count).
        //
        //     I(t) = [ risk(t) ≥ breakThreshold ]
        //     D(t) = t − (last instant I was 0)
        //     Alarm = [ I(t)=1  ∧  D(t) ≥ H ]
        guard isWalking else {
            riskTripStart = nil
            return
        }

        let sustained: Bool
        if result.score >= riskModel.breakThreshold {
            let start = riskTripStart ?? Date()
            riskTripStart = start
            sustained = Date().timeIntervalSince(start) >= sustainedHoldDuration
        } else {
            riskTripStart = nil
            sustained = false
        }

        guard sustained, hasWalkedEnough else {
            if !sustained { lastAlertDate = nil }   // recovered or resting: next trip alerts immediately
            return
        }
        if let lastAlertDate, Date().timeIntervalSince(lastAlertDate) < alertRepeatInterval { return }
        presentBreakAlert(message: breakMessage(from: result.reasons))
    }

    /// Break risk as a plain integer, parsed from the "NN%" status string.
    private var riskPercentInt: Int {
        Int(riskScoreStatus.filter(\.isNumber)) ?? 0
    }

    /// Mirrors the current live metrics into the shared App Group so the
    /// widgets / watch complications can display them, then asks WidgetKit to
    /// refresh. On watchOS we additionally publish the live workout metrics
    /// (heart rate, active energy). The App Group ID string is the same on
    /// both platforms; each device keeps its own container.
    private func publishWidgetSnapshot() {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID) else { return }
        defaults.set(isTracking, forKey: "wb.isTracking")
        defaults.set(isPaused, forKey: "wb.isPaused")
        defaults.set(riskPercentInt, forKey: "wb.risk")
        defaults.set(stepsStatus, forKey: "wb.steps")
        defaults.set(distanceStatus, forKey: "wb.distance")
        defaults.set(elapsedTimeStatus, forKey: "wb.time")
        #if os(watchOS)
        defaults.set(heartRateStatus, forKey: "wb.heartRate")
        defaults.set(activeEnergyStatus, forKey: "wb.energy")
        #endif
        defaults.set(Date(), forKey: "wb.updated")
        WidgetCenter.shared.reloadAllTimelines()

        #if os(iOS)
        if #available(iOS 16.2, *) { updateLiveActivity() }
        #endif
    }

    /// At launch, if no walk is actually running, reset the shared App Group snapshot
    /// so a widget / complication left over from a swiped-away walk doesn't keep
    /// showing a stale "Monitoring" state. Runs on both iPhone and Apple Watch.
    func clearWidgetSnapshotIfIdle() {
        guard !isTracking, let defaults = UserDefaults(suiteName: Self.appGroupID) else { return }
        defaults.set(false, forKey: "wb.isTracking")
        defaults.set(false, forKey: "wb.isPaused")
        defaults.set(0, forKey: "wb.risk")
        defaults.set("0", forKey: "wb.steps")
        defaults.set("0 m", forKey: "wb.distance")
        defaults.set("0:00", forKey: "wb.time")
        defaults.set("–", forKey: "wb.heartRate")
        defaults.set("–", forKey: "wb.energy")
        defaults.set(Date(), forKey: "wb.updated")
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func breakMessage(from reasons: [String]) -> String {
        guard !reasons.isEmpty else {
            return "Your walking pattern suggests fatigue. Please find a safe place to sit down and rest."
        }
        return "Your \(reasons.joined(separator: ", and ")). Please find a safe place to sit down and rest."
    }

    // MARK: - Alerting (shared)

    /// Every alert reaches the user three ways: a haptic, the in-app alert (screen on) and a
    /// notification (phone locked or app in the background). Repeats are paced by the callers.
    private func presentBreakAlert(message: String) {
        lastAlertDate = Date()
        recorder.alerts += 1
        alertMessage = message
        triggersAlert = true
        HapticsManager.strongAlert()
        sendBreakNotification(message: message)
    }

    private func sendBreakNotification(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Time to Take a Break"
        content.body = "\(message)\n\(currentMetricsSummary())"
        content.sound = .default
        content.threadIdentifier = "walking-break"
        // Cuts through Focus modes once the "Time Sensitive Notifications" capability is added in Xcode.
        content.interruptionLevel = .timeSensitive

        notificationCenter.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func currentMetricsSummary() -> String {
        "Steps: \(stepsStatus) | Distance: \(distanceStatus) | Time: \(elapsedTimeStatus) | Risk: \(riskScoreStatus)"
    }

    private func requestNotificationAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            self?.refreshNotificationStatus()
        }
    }

    func refreshNotificationStatus() {
        notificationCenter.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async { self?.notificationsDenied = settings.authorizationStatus == .denied }
        }
    }

    // MARK: - Formatters (shared)

    static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    static func metersString(_ meters: Double) -> String {
        String(format: "%.0f m", meters)
    }

    static func speedString(_ metersPerSecond: Double) -> String {
        String(format: "%.2f m/s", metersPerSecond)
    }

    static let cadenceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

// MARK: - iPhone sensor source (CMPedometer + HealthKit gait baseline)

#if os(iOS)
extension HealthKitManager {

    private func startSensors() {
        steadinessStatus = "Waiting for Data"
        currentPaceStatus = "Waiting for Data"
        cadenceStatus = "Waiting for Data"

        phoneRawSpeed = nil
        phoneRawCadence = nil
        phoneRawDistance = nil
        phoneRawStepLength = nil
        phoneRawSteadiness = nil
        lastHealthCalibration = .distantPast
        calibrationAcc = [:]

        refreshGaitBaseline()
        startBackgroundLocation()
        observeForegroundReturn()

        #if targetEnvironment(simulator)
        startSimulatedWalkingUpdates()
        monitoringMessage = "Using simulated walking data. Test live sensors on a real iPhone."
        #else
        pedometerStart = Date()
        startPedometerUpdates(from: pedometerStart ?? Date())
        startLiveGaitAnalysis()
        #endif
    }

    /// A phone call (e.g. FaceTime), Control Center, or any interruption can
    /// stall `CMMotionManager` / live pedometer updates and they don't auto-resume.
    /// When the app returns to the foreground mid-walk we re-prime the sensors so
    /// tracking stays smooth instead of freezing until the call ends.
    private func observeForegroundReturn() {
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        guard isTracking, !isPaused else { return }
        resyncSensors()
    }

    /// Restarts the live sensors, backfilling any steps/distance missed while the
    /// app was interrupted (the pedometer query runs from the original start date).
    private func resyncSensors() {
        gaitAnalyzer.stop()
        startLiveGaitAnalysis()

        #if !targetEnvironment(simulator)
        pedometer.stopUpdates()
        startPedometerUpdates(from: pedometerStart ?? Date())
        #endif
    }

    /// Streams real-time gait estimates from the IMU into the live metrics,
    /// overriding the frozen HealthKit baseline during the walk.
    private func startLiveGaitAnalysis() {
        guard gaitAnalyzer.isAvailable else { return }
        gaitAnalyzer.onUpdate = { [weak self] metrics in
            guard let self else { return }

            self.latestStepVariability = metrics.stepTimeVariability

            // Capture the phone's own raw cadence / step length (kept for calibration
            // even when the Watch is driving the display). Steadiness is no longer taken
            // from here — it's recomputed as a composite in `updateCompositeSteadiness`.
            if let cadence = metrics.cadence { self.phoneRawCadence = cadence }
            if let speed = self.phoneRawSpeed, let cadence = self.phoneRawCadence, cadence > 0 {
                self.phoneRawStepLength = speed / cadence
            }

            // During a watch-started walk the Watch's readings win — the raw values
            // above feed calibration, but we don't display the phone's own estimates.
            guard !self.watchOwnsLiveMetrics else { return }

            if let asymmetry = metrics.asymmetry {
                self.latestAsymmetry = asymmetry
                self.asymmetryStatus = Self.percentFormatter.string(from: NSNumber(value: asymmetry))
                    ?? "\(Int(asymmetry * 100))%"
            }
            if let doubleSupport = metrics.doubleSupport {
                self.latestDoubleSupport = doubleSupport
                self.doubleSupportStatus = Self.percentFormatter.string(from: NSNumber(value: doubleSupport))
                    ?? "\(Int(doubleSupport * 100))%"
            }
            if let cadence = metrics.cadence {
                let correctedCadence = SensorCalibration.shared.corrected(.cadence, cadence)
                self.latestCadence = correctedCadence
                self.cadenceStatus = "\(Int(correctedCadence * 60)) steps/min"
            }
            if let rawStepLength = self.phoneRawStepLength {
                let length = SensorCalibration.shared.corrected(.stepLength, rawStepLength)
                self.latestStepLength = length
                self.stepLengthStatus = Self.metersString(length)
            }

            self.updateBreakRisk()
        }
        gaitAnalyzer.start()
    }

    private func stopSensors() {
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        pedometer.stopUpdates()
        pedometer.stopEventUpdates()
        gaitAnalyzer.stop()
        simulatorTimer?.invalidate()
        simulatorTimer = nil
        locationManager.stopUpdatingLocation()
    }

    /// Pause live sensors; `stopSensors` already preserves `pedometerStart`, so resuming
    /// continues the same cumulative step/distance count rather than restarting at zero.
    private func pauseSensors() {
        stopSensors()
    }

    private func resumeSensors() {
        startBackgroundLocation()
        observeForegroundReturn()
        #if targetEnvironment(simulator)
        startSimulatedWalkingUpdates()
        #else
        startPedometerUpdates(from: pedometerStart ?? Date())
        startLiveGaitAnalysis()
        #endif
    }

    /// Keeps the app alive with the screen off / backgrounded by running
    /// low-power location updates. We don't use the coordinates — the live
    /// signal just keeps the risk timer and pedometer updates flowing.
    ///
    /// Requires the "Location updates" background mode and Always-location
    /// permission. `allowsBackgroundLocationUpdates` is only enabled once the
    /// background mode is present, so the app won't crash before it's set up.
    private func startBackgroundLocation() {
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestAlwaysAuthorization()

        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        if backgroundModes.contains("location") {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }

        locationManager.startUpdatingLocation()
    }

    private func requestHealthAuthorization(completion: @escaping () -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            steadinessStatus = "Unavailable"
            completion()
            return
        }

        // Sharing the workout type lets us launch a mirrored workout on the Watch
        // via `startWatchApp(with:)`.
        healthStore.requestAuthorization(toShare: [HKQuantityType.workoutType()], read: iOSReadTypes()) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshGaitBaseline()
                completion()
            }
        }
    }

    /// User-initiated: re-checks Health access any time, so it isn't a one-time prompt.
    /// If the system can still show the permission sheet, it presents it; otherwise (the
    /// user already answered) it flags the UI to guide them to re-enable it in the Health
    /// app, since iOS won't re-prompt and offers no deep link to the toggle.
    func manageHealthAccess() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        healthStore.getRequestStatusForAuthorization(toShare: [HKQuantityType.workoutType()], read: iOSReadTypes()) { [weak self] status, _ in
            DispatchQueue.main.async {
                if status == .shouldRequest {
                    self?.healthAccessNeedsSettings = false
                    self?.requestHealthAuthorization { self?.refreshGaitBaseline() }
                } else {
                    self?.healthAccessNeedsSettings = true
                }
            }
        }
    }

    // MARK: - Start options (with / without Apple Watch)

    /// Start a walk and launch the companion Watch workout so heart rate and energy
    /// stream back. Called when the user chooses to sync at Start. The Watch is
    /// launched only after authorization completes, since `startWatchApp` needs the
    /// workout-share grant.
    func startWithWatch() {
        startedWithWatch = true
        requestNotificationAuthorization()
        requestHealthAuthorization { [weak self] in
            self?.startWatchWorkout()
            self?.startSession()
        }
    }

    /// Start a walk on iPhone only. Watch-only values show the "Requires Apple Watch
    /// Sync" placeholder until (if ever) a Watch connects.
    func startWithoutWatch() {
        startedWithWatch = false
        heartRateStatus = Self.requiresWatchText
        activeEnergyStatus = Self.requiresWatchText
        requestAuthorizationAndStart()
    }

    /// Launches / wakes the companion watchOS app into a walking workout session.
    /// The Watch picks this up in its `WKApplicationDelegate.handle(_:)`.
    private func startWatchWorkout() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .outdoor
        healthStore.startWatchApp(with: configuration) { _, _ in }
    }

    /// Applies live heart-rate / energy readings streamed from the Apple Watch.
    /// Ignored unless a walk is active, so `isWatchSynced` can't get stuck on between
    /// walks (the staleness check only runs while the clock is ticking).
    private func applyWatchLiveMetrics(_ metrics: WalkHistory.LiveMetrics) {
        guard isTracking, !isPaused else { return }
        lastWatchMetricsDate = Date()
        isWatchSynced = true
        // Heart rate and active energy are Watch-only, so they always apply.
        if let heartRate = metrics.heartRate {
            latestHeartRate = heartRate
            heartRateStatus = "\(Int(heartRate)) bpm"
        }
        if let fraction = metrics.heartRateFraction {
            latestHeartRateFraction = fraction
        }
        if let kcal = metrics.activeEnergyKcal {
            latestActiveEnergyKcal = kcal
            activeEnergyStatus = "\(Int(kcal)) kcal"
        }

        // When the walk was started with the Apple Watch, its sensors are the source
        // of truth: override the iPhone's own pedometer/gait readings with the Watch's.
        // (The iPhone's own sensors are suppressed meanwhile — see `watchOwnsLiveMetrics`.)
        if startedWithWatch {
            if let distance = metrics.distance {
                latestDistance = distance
                distanceStatus = Self.metersString(distance)
            }
            if let steps = metrics.steps {
                latestStepCount = steps
                stepsStatus = "\(steps)"
            }
            if let speed = metrics.speed {
                latestWalkingSpeed = speed
                currentPaceStatus = Self.speedString(speed)
            }
            if let cadence = metrics.cadence {
                latestCadence = cadence
                cadenceStatus = "\(Int(cadence * 60)) steps/min"
            }
            if let flights = metrics.flights {
                latestFlights = flights
                flightsStatus = "\(Int(flights))"
            }
            if let steadiness = metrics.steadiness {
                latestWalkingSteadiness = steadiness
                steadinessStatus = Self.percentFormatter.string(from: NSNumber(value: steadiness)) ?? "\(Int(steadiness * 100))%"
            }
            if let asymmetry = metrics.asymmetry {
                latestAsymmetry = asymmetry
                asymmetryStatus = Self.percentFormatter.string(from: NSNumber(value: asymmetry)) ?? "\(Int(asymmetry * 100))%"
            }
            if let doubleSupport = metrics.doubleSupport {
                latestDoubleSupport = doubleSupport
                doubleSupportStatus = Self.percentFormatter.string(from: NSNumber(value: doubleSupport)) ?? "\(Int(doubleSupport * 100))%"
            }
            if let stepLength = metrics.stepLength {
                latestStepLength = stepLength
                stepLengthStatus = Self.metersString(stepLength)
            }

            // Primary calibration signal: record this walk's phone-vs-Watch pairs in
            // the background (never shown) and commit them once when the walk ends.
            accumulateCalibration(.speed, phone: phoneRawSpeed, reference: metrics.speed)
            accumulateCalibration(.cadence, phone: phoneRawCadence, reference: metrics.cadence)
            accumulateCalibration(.distance, phone: phoneRawDistance, reference: metrics.distance)
            accumulateCalibration(.stepLength, phone: phoneRawStepLength, reference: metrics.stepLength)
            accumulateCalibration(.steadiness, phone: phoneRawSteadiness, reference: metrics.steadiness)
        }
        updateBreakRisk()
    }

    /// iPhone-side: true once a watch-started walk is actively streaming, so the
    /// iPhone's own pedometer and gait estimates stand down and let the Watch's
    /// readings drive the display and the equation. Falls back to the iPhone's own
    /// sensors before the first packet and if the Watch sync drops.
    private var watchOwnsLiveMetrics: Bool {
        startedWithWatch && isWatchSynced
    }

    /// Periodically compares the phone's live readings against Apple Health's latest
    /// values for this person (walking speed, step length, steadiness) and folds the
    /// difference into the calibration. Health carries the Watch's weight for
    /// steadiness — our instant-steadiness estimate is uncertain — and a lighter
    /// weight elsewhere, since the Apple Watch is the primary reference. Skips
    /// watch-driven stretches so it only ever compares the phone's own estimates.
    private func calibrateAgainstHealthIfDue() {
        guard isTracking, !isPaused, isWalking, !watchOwnsLiveMetrics else { return }
        guard Date().timeIntervalSince(lastHealthCalibration) >= healthCalibrationInterval else { return }
        lastHealthCalibration = Date()

        if let phone = phoneRawSpeed, phone > 0 {
            let unit = HKUnit.meter().unitDivided(by: .second())
            fetchMostRecent(.walkingSpeed, unit: unit) { [weak self] value in
                guard let self, let value, value > 0 else { return }
                self.accumulateCalibration(.speed, phone: phone, reference: value)
            }
        }
        if let phone = phoneRawStepLength, phone > 0 {
            fetchMostRecent(.walkingStepLength, unit: .meter()) { [weak self] value in
                guard let self, let value, value > 0 else { return }
                self.accumulateCalibration(.stepLength, phone: phone, reference: value)
            }
        }
        if let phone = phoneRawSteadiness, phone > 0 {
            fetchMostRecent(.appleWalkingSteadiness, unit: .percent()) { [weak self] value in
                guard let self, let value, value > 0 else { return }
                self.accumulateCalibration(.steadiness, phone: phone, reference: value)
            }
        }
    }

    /// Adds one paired (phone, reference) reading for the current walk, if both exist.
    /// Committed as a single calibration step when the walk ends (see ``commitCalibration``).
    private func accumulateCalibration(_ metric: SensorCalibration.Metric, phone: Double?, reference: Double?) {
        guard let phone, let reference, phone > 0, reference > 0 else { return }
        var acc = calibrationAcc[metric] ?? (phoneSum: 0, refSum: 0, count: 0)
        acc.phoneSum += phone
        acc.refSum += reference
        acc.count += 1
        calibrationAcc[metric] = acc
    }

    /// At walk end, folds each metric's walk-average difference into the calibration as
    /// one EMA step, then runs the lighter cross-walk pass. The reference for this walk
    /// is the Apple Watch when it was a watch-started walk, otherwise Apple Health; the
    /// Watch is weighted strongest, Health lightest, steadiness strongly either way.
    private func commitCalibration() {
        let base = startedWithWatch ? Self.watchCalibrationWeight : Self.healthCalibrationWeight
        for (metric, acc) in calibrationAcc where acc.count >= calibrationMinSamples && acc.phoneSum > 0 {
            let weight = (metric == .steadiness) ? Self.steadinessCalibrationWeight : base
            SensorCalibration.shared.learn(metric, phone: acc.phoneSum, reference: acc.refSum, weight: weight)
        }
        calibrationAcc = [:]
        calibrateCrossWalk()
    }

    /// Secondary calibration: compares this person's iPhone-only walks against their
    /// Apple-Watch-only walks across history (needs 3+ of each) to close any residual
    /// gap the same-walk pass didn't. As the iPhone converges toward the Watch this
    /// naturally fades to no change.
    ///
    /// Only *comparable* walks are paired — a hard hike vs a gentle stroll differ by
    /// effort, not sensor bias — judged by context habits (time of day, duration,
    /// distance, steps, flights). And only the agreeable metrics (speed, cadence) are
    /// compared here; steadiness / asymmetry / double-support swing too much between
    /// walks to trust, so they're left to the same-walk and Apple Health passes.
    private func calibrateCrossWalk() {
        let walks = WalkHistory.shared.walks
        let watchWalks = walks.filter { $0.device == "Apple Watch" }
        let phoneWalks = walks.filter { $0.device != "Apple Watch" }
        guard watchWalks.count >= crossWalkMinimumWalks, phoneWalks.count >= crossWalkMinimumWalks else { return }

        func near(_ x: Double, _ y: Double, ratio: Double) -> Bool {
            let hi = max(x, y)
            return hi <= 0 ? true : min(x, y) / hi >= ratio
        }
        func comparable(_ a: WalkRecord, _ b: WalkRecord) -> Bool {
            let hourA = Calendar.current.component(.hour, from: a.start)
            let hourB = Calendar.current.component(.hour, from: b.start)
            return abs(hourA - hourB) <= 3
                && near(a.duration, b.duration, ratio: 0.7)
                && near(a.distance, b.distance, ratio: 0.7)
                && near(Double(a.steps), Double(b.steps), ratio: 0.7)
                && near((a.flights ?? 0) + 1, (b.flights ?? 0) + 1, ratio: 0.6)
        }
        func nudge(_ metric: SensorCalibration.Metric, _ value: (WalkRecord) -> Double?) {
            var phoneSum = 0.0, watchSum = 0.0, pairs = 0
            for watch in watchWalks {
                guard let wv = value(watch), wv > 0 else { continue }
                for phone in phoneWalks where comparable(watch, phone) {
                    guard let pv = value(phone), pv > 0 else { continue }
                    watchSum += wv
                    phoneSum += pv
                    pairs += 1
                }
            }
            guard pairs >= crossWalkMinimumWalks, phoneSum > 0 else { return }
            SensorCalibration.shared.learn(metric, phone: phoneSum, reference: watchSum, weight: Self.crossWalkCalibrationWeight)
        }
        nudge(.speed) { $0.speed }
        nudge(.cadence) { $0.cadence }
    }

    private func iOSReadTypes() -> Set<HKObjectType> {
        let identifiers: [HKQuantityTypeIdentifier] = [
            .walkingSpeed, .appleWalkingSteadiness, .walkingAsymmetryPercentage,
            .walkingDoubleSupportPercentage, .walkingStepLength,
            .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .flightsClimbed,
        ]
        return Set(identifiers.compactMap { HKQuantityType.quantityType(forIdentifier: $0) })
    }

    private func startPedometerUpdates(from startDate: Date) {
        guard CMPedometer.isStepCountingAvailable() else {
            monitoringMessage = "Step counting is not available on this device."
            return
        }

        pedometer.startUpdates(from: startDate) { [weak self] data, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    self.monitoringMessage = "Motion data is unavailable. Check Motion & Fitness permission."
                    return
                }
                guard let data else { return }
                self.applyPedometer(data)
            }
        }
    }

    private func applyPedometer(_ data: CMPedometerData) {
        // Capture the phone's own raw readings first, so calibration can always compare
        // raw-phone vs reference (Watch / Health) regardless of what we display.
        let rawDistance = data.distance?.doubleValue
        let rawSpeed: Double? = {
            if let pace = data.currentPace?.doubleValue, pace > 0 { return 1 / pace }
            return nil
        }()
        let rawCadence = data.currentCadence?.doubleValue
        phoneRawDistance = rawDistance
        phoneRawSpeed = rawSpeed
        phoneRawCadence = rawCadence

        // In a watch-started walk the Apple Watch's readings win — keep the raw phone
        // values above (for calibration) but don't display them.
        guard !watchOwnsLiveMetrics else { return }

        latestStepCount = data.numberOfSteps.intValue
        stepsStatus = "\(latestStepCount)"

        if let rawDistance {
            let distance = SensorCalibration.shared.corrected(.distance, rawDistance)
            latestDistance = distance
            distanceStatus = Self.metersString(distance)
        }

        if let floors = data.floorsAscended?.doubleValue {
            latestFlights = floors
            flightsStatus = "\(Int(floors))"
        }

        if let rawSpeed {
            let speed = SensorCalibration.shared.corrected(.speed, rawSpeed)
            latestWalkingSpeed = speed
            currentPaceStatus = Self.speedString(speed)
        }

        if let rawCadence {
            let cadence = SensorCalibration.shared.corrected(.cadence, rawCadence)
            latestCadence = cadence
            let stepsPerMinute = cadence * 60
            cadenceStatus = (Self.cadenceFormatter.string(from: NSNumber(value: stepsPerMinute)) ?? "\(Int(stepsPerMinute))") + " steps/min"
        }

        updateBreakRisk()
    }

    /// Pulls the most recent passively-recorded gait samples. These update only a
    /// handful of times per day, so they act as a quality baseline rather than a
    /// live signal — but they still feed the break equation.
    private func refreshGaitBaseline() {
        // Steadiness is no longer read directly from Health — it's a composite of the
        // signals below (see `updateCompositeSteadiness`). We still seed asymmetry,
        // double support and step length from Health so the composite has inputs early.
        fetchMostRecent(.walkingAsymmetryPercentage, unit: .percent()) { [weak self] value in
            guard let self, let value else { return }
            self.latestAsymmetry = value
            self.asymmetryStatus = Self.percentFormatter.string(from: NSNumber(value: value)) ?? "\(Int(value * 100))%"
            self.updateBreakRisk()
        }
        fetchMostRecent(.walkingDoubleSupportPercentage, unit: .percent()) { [weak self] value in
            guard let self, let value else { return }
            self.latestDoubleSupport = value
            self.doubleSupportStatus = Self.percentFormatter.string(from: NSNumber(value: value)) ?? "\(Int(value * 100))%"
            self.updateBreakRisk()
        }
        fetchMostRecent(.walkingStepLength, unit: .meter()) { [weak self] value in
            guard let self, let value else { return }
            self.latestStepLength = value
            self.stepLengthStatus = Self.metersString(value)
            self.updateBreakRisk()
        }
    }

    private func fetchMostRecent(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, completion: @escaping (Double?) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            completion(nil)
            return
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
            DispatchQueue.main.async { completion(value) }
        }
        healthStore.execute(query)
    }

    private func startSimulatedWalkingUpdates() {
        simulatorTimer?.invalidate()
        var elapsedSeconds = 0
        var steps = 0.0
        var distance = 0.0
        simulatorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            elapsedSeconds += 1
            // Fresh for 20 s, then tired for 40 s, repeating — so the alert can be seen firing again and again.
            let tired = elapsedSeconds % 60 >= 20
            let speed = tired ? 0.62 : 1.05
            let cadence = tired ? 0.95 : 1.45
            steps += cadence
            distance += speed
            self.latestWalkingSpeed = speed
            self.latestCadence = cadence
            self.latestStepCount = Int(steps)
            self.latestDistance = distance
            self.latestFlights = Double(elapsedSeconds / 20)
            self.flightsStatus = "\(Int(self.latestFlights))"
            self.latestWalkingSteadiness = tired ? 0.25 : 0.75
            self.latestAsymmetry = tired ? 0.14 : 0.04
            self.latestDoubleSupport = tired ? 0.40 : 0.28
            self.stepsStatus = "\(self.latestStepCount)"
            self.distanceStatus = Self.metersString(distance)
            self.currentPaceStatus = Self.speedString(speed)
            self.cadenceStatus = "\(Int(cadence * 60)) steps/min"
            self.steadinessStatus = tired ? "Low" : "OK"
            self.asymmetryStatus = tired ? "14%" : "4%"
            self.doubleSupportStatus = tired ? "40%" : "28%"
            self.updateBreakRisk()
        }
    }
}

// MARK: - Adaptive sensor calibration

/// Learns how the iPhone's own sensors differ from trusted references — the Apple
/// Watch (primary) and Apple Health — for the *same person*, then nudges the phone's
/// solo-walk readings toward them. One multiplicative factor per metric, updated by a
/// weighted exponential moving average and clamped so a single bad sample can't skew
/// it. Persisted per device in `UserDefaults`. Factors start at 1.0 (no change) until
/// enough paired readings are seen, so behaviour degrades gracefully.
final class SensorCalibration: ObservableObject {
    static let shared = SensorCalibration()

    enum Metric: String, CaseIterable {
        case speed, cadence, distance, stepLength, steadiness

        var displayName: String {
            switch self {
            case .speed: "Walking speed"
            case .cadence: "Cadence"
            case .distance: "Distance"
            case .stepLength: "Step length"
            case .steadiness: "Steadiness"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let key = "wb.sensorCalibration"
    private let minFactor = 0.5
    private let maxFactor = 2.0
    @Published private(set) var factors: [String: Double]

    private init() {
        factors = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    /// True once any metric has been adjusted away from neutral.
    var isActive: Bool { factors.contains { abs($0.value - 1) > 0.01 } }

    /// A short "+8%" / "−3%" description of a metric's current adjustment, or nil when
    /// it hasn't meaningfully moved from neutral.
    func adjustmentDescription(_ metric: Metric) -> String? {
        let f = factor(for: metric)
        guard abs(f - 1) > 0.01 else { return nil }
        let pct = Int(((f - 1) * 100).rounded())
        return pct > 0 ? "+\(pct)%" : "\(pct)%"
    }

    /// Clears every learned factor, returning the phone to its own raw readings.
    func reset() {
        factors = [:]
        defaults.removeObject(forKey: key)
    }

    /// Current correction factor for a metric (1.0 = nothing learned yet).
    func factor(for metric: Metric) -> Double { factors[metric.rawValue] ?? 1 }

    /// Applies the learned correction to a raw phone reading.
    func corrected(_ metric: Metric, _ value: Double) -> Double { value * factor(for: metric) }

    /// Folds one paired (phone, reference) reading into a metric's factor. `weight` is
    /// this sample's EMA weight — how strongly this reference pulls the factor.
    func learn(_ metric: Metric, phone: Double, reference: Double, weight: Double) {
        guard phone > 0, reference > 0 else { return }
        let ratio = min(max(reference / phone, minFactor), maxFactor)
        // Start neutral (1.0 = no correction) and ease toward the ratio one walk at a
        // time, so the phone converges gradually over several walks rather than
        // snapping to a single walk's reading.
        let current = factors[metric.rawValue] ?? 1
        let w = min(max(weight, 0), 1)
        let updated = min(max(current * (1 - w) + ratio * w, minFactor), maxFactor)
        factors[metric.rawValue] = updated
        defaults.set(factors, forKey: key)
    }
}

// MARK: - Background keep-alive (location updates are intentionally unused)

extension HealthKitManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshLocationStatus()
        // If the user upgraded to Always while walking, light up background updates.
        if manager.authorizationStatus == .authorizedAlways {
            let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
            if backgroundModes.contains("location") {
                manager.allowsBackgroundLocationUpdates = true
            }
        }
    }

    /// Flags "needs Always" once the user has chosen anything other than Always
    /// (While-Using, Denied, Restricted). `.notDetermined` is ignored because the
    /// Start prompt is still pending.
    func refreshLocationStatus() {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .denied, .restricted:
            locationNeedsAlways = true
        default:
            locationNeedsAlways = false
        }
    }
}

// MARK: - Live Activity (Lock Screen + Dynamic Island, like a workout card)

@available(iOS 16.2, *)
extension HealthKitManager {

    private var liveActivityState: WalkActivityAttributes.ContentState {
        WalkActivityAttributes.ContentState(
            risk: riskPercentInt,
            steps: stepsStatus,
            distance: distanceStatus,
            time: elapsedTimeStatus
        )
    }

    func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Clear any leftover activities (e.g. orphaned when the app was swiped
        // away mid-walk) so a new walk never stacks a second Live Activity.
        endAllLiveActivities()
        do {
            liveActivity = try Activity.request(
                attributes: WalkActivityAttributes(),
                content: ActivityContent(state: liveActivityState, staleDate: nil)
            )
        } catch {
            liveActivity = nil
        }
    }

    /// Ends every Walking Buddy Live Activity the system still has — including any
    /// orphaned by a previous termination — and drops our reference.
    func endAllLiveActivities() {
        liveActivity = nil
        for activity in Activity<WalkActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func updateLiveActivity() {
        guard let activity = liveActivity as? Activity<WalkActivityAttributes> else { return }
        let state = liveActivityState
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func endLiveActivity() {
        guard let activity = liveActivity as? Activity<WalkActivityAttributes> else { return }
        let state = liveActivityState
        liveActivity = nil
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate) }
    }
}
#endif

// MARK: - Apple Watch sensor source (HKWorkoutSession + HKLiveWorkoutBuilder)

#if os(watchOS)
extension HealthKitManager: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {

    private func startSensors() {
        startWorkoutSession()
        startWatchGaitAnalysis()
    }

    private func stopSensors() {
        workoutSession?.end()
        gaitAnalyzer.stop()
    }

    /// Pause the live workout *without ending it*, so its cumulative stats (steps,
    /// distance, energy) are preserved and the workout stays active — otherwise the
    /// Smart Stack loses its workout relevance and the metrics collapse to zero.
    private func pauseSensors() {
        workoutSession?.pause()
        gaitAnalyzer.stop()
    }

    private func resumeSensors() {
        workoutSession?.resume()
        startWatchGaitAnalysis()
    }

    /// Live gait quality from the wrist IMU, so the Watch shows steadiness,
    /// asymmetry, double-support and step length like the iPhone. Speed and
    /// cadence stay sourced from the workout (more reliable than the wrist).
    private func startWatchGaitAnalysis() {
        guard gaitAnalyzer.isAvailable else { return }
        steadinessStatus = "Waiting for Data"
        asymmetryStatus = "Waiting for Data"
        doubleSupportStatus = "Waiting for Data"
        gaitAnalyzer.onUpdate = { [weak self] metrics in
            guard let self else { return }
            self.latestStepVariability = metrics.stepTimeVariability
            // Steadiness is recomputed as a composite in `updateCompositeSteadiness`
            // (from speed / step length / double support / asymmetry).
            if let asymmetry = metrics.asymmetry {
                self.latestAsymmetry = asymmetry
                self.asymmetryStatus = Self.percentFormatter.string(from: NSNumber(value: asymmetry)) ?? "\(Int(asymmetry * 100))%"
            }
            if let doubleSupport = metrics.doubleSupport {
                self.latestDoubleSupport = doubleSupport
                self.doubleSupportStatus = Self.percentFormatter.string(from: NSNumber(value: doubleSupport)) ?? "\(Int(doubleSupport * 100))%"
            }
            // Step length = workout speed / cadence (don't override the workout's
            // own speed/cadence with the wrist estimate).
            if let speed = self.latestWalkingSpeed, let cadence = self.latestCadence, cadence > 0 {
                let length = speed / cadence
                self.latestStepLength = length
                self.stepLengthStatus = Self.metersString(length)
            }
            self.updateBreakRisk()
            self.streamLiveMetricsToiPhone()
        }
        gaitAnalyzer.start()
    }

    private func requestHealthAuthorization(completion: @escaping () -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion()
            return
        }

        var share: Set<HKSampleType> = [HKQuantityType.workoutType()]
        if let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { share.insert(energy) }
        if let distance = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) { share.insert(distance) }
        if let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) { share.insert(heartRate) }

        let read: Set<HKObjectType> = {
            var types = Set(share.map { $0 as HKObjectType })
            if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) { types.insert(steps) }
            if let flights = HKQuantityType.quantityType(forIdentifier: .flightsClimbed) { types.insert(flights) }
            types.insert(HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!)
            return types
        }()

        healthStore.requestAuthorization(toShare: share, read: read) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateMaxHeartRateFromAge()
                completion()
            }
        }
    }

    /// User-initiated: re-checks Health access any time, so it isn't a one-time prompt.
    /// Re-presents the permission sheet when the system still allows it; otherwise flags
    /// the UI to guide the user to re-enable access in Settings, since watchOS won't
    /// re-prompt once the user has answered.
    func manageHealthAccess() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        var share: Set<HKSampleType> = [HKQuantityType.workoutType()]
        if let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { share.insert(energy) }
        if let distance = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) { share.insert(distance) }
        if let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) { share.insert(heartRate) }
        var read = Set(share.map { $0 as HKObjectType })
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) { read.insert(steps) }
        if let flights = HKQuantityType.quantityType(forIdentifier: .flightsClimbed) { read.insert(flights) }
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) { read.insert(dob) }

        healthStore.getRequestStatusForAuthorization(toShare: share, read: read) { [weak self] status, _ in
            DispatchQueue.main.async {
                if status == .shouldRequest {
                    self?.healthAccessNeedsSettings = false
                    self?.requestHealthAuthorization { }
                } else {
                    self?.healthAccessNeedsSettings = true
                }
            }
        }
    }

    private func updateMaxHeartRateFromAge() {
        if let components = try? healthStore.dateOfBirthComponents(),
           let birthYear = components.year {
            let age = Calendar.current.component(.year, from: Date()) - birthYear
            if age > 0 { maxHeartRate = Double(220 - age) }
        }
    }

    private func startWorkoutSession() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .outdoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            let dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            // Flights and step count aren't collected for a walking workout by default;
            // opt in so the Watch reports steps (and the cadence / step-length derived
            // from them) and stair exertion like the iPhone's pedometer does.
            if let flights = HKQuantityType.quantityType(forIdentifier: .flightsClimbed) {
                dataSource.enableCollection(for: flights, predicate: nil)
            }
            if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) {
                dataSource.enableCollection(for: steps, predicate: nil)
            }
            builder.dataSource = dataSource
            session.delegate = self
            builder.delegate = self

            let start = Date()
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { _, _ in }

            workoutSession = session
            workoutBuilder = builder
            monitoringMessage = "Live workout running on Apple Watch."
        } catch {
            monitoringMessage = "Could not start the workout session."
        }
    }

    // MARK: HKLiveWorkoutBuilderDelegate

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType,
                  let statistics = workoutBuilder.statistics(for: quantityType) else { continue }
            DispatchQueue.main.async {
                self.apply(quantityType, statistics)
            }
        }
    }

    private func apply(_ type: HKQuantityType, _ statistics: HKStatistics) {
        switch type {
        case HKQuantityType.quantityType(forIdentifier: .heartRate):
            let unit = HKUnit.count().unitDivided(by: .minute())
            if let bpm = statistics.mostRecentQuantity()?.doubleValue(for: unit) {
                latestHeartRate = bpm
                heartRateStatus = "\(Int(bpm)) bpm"
                if maxHeartRate > 0 { latestHeartRateFraction = bpm / maxHeartRate }
            }
        case HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned):
            if let kcal = statistics.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                latestActiveEnergyKcal = kcal
                activeEnergyStatus = "\(Int(kcal)) kcal"
            }
        case HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning):
            if let meters = statistics.sumQuantity()?.doubleValue(for: .meter()) {
                latestDistance = meters
                distanceStatus = Self.metersString(meters)
                let seconds = currentElapsed
                if seconds > 0 {
                    latestWalkingSpeed = meters / seconds
                    currentPaceStatus = Self.speedString(meters / seconds)
                }
            }
        case HKQuantityType.quantityType(forIdentifier: .stepCount):
            if let steps = statistics.sumQuantity()?.doubleValue(for: .count()) {
                latestStepCount = Int(steps)
                stepsStatus = "\(latestStepCount)"
                if currentElapsed > 0 {
                    latestCadence = steps / currentElapsed
                    cadenceStatus = "\(Int((steps / currentElapsed) * 60)) steps/min"
                }
            }
        case HKQuantityType.quantityType(forIdentifier: .flightsClimbed):
            if let flights = statistics.sumQuantity()?.doubleValue(for: .count()) {
                latestFlights = flights
                flightsStatus = "\(Int(flights))"
            }
        default:
            break
        }
        updateBreakRisk()
        streamLiveMetricsToiPhone()
    }

    /// Streams the Watch's live readings to the iPhone so a watch-started walk shows
    /// and records the Watch's sensor values there too — not just heart rate / energy.
    private func streamLiveMetricsToiPhone() {
        WalkHistory.shared.sendLiveMetrics(
            WalkHistory.LiveMetrics(heartRate: latestHeartRate,
                                    heartRateFraction: latestHeartRateFraction,
                                    activeEnergyKcal: latestActiveEnergyKcal,
                                    distance: latestDistance,
                                    steps: latestStepCount,
                                    speed: latestWalkingSpeed,
                                    cadence: latestCadence,
                                    flights: latestFlights,
                                    steadiness: latestWalkingSteadiness,
                                    asymmetry: latestAsymmetry,
                                    doubleSupport: latestDoubleSupport,
                                    stepLength: latestStepLength)
        )
    }

    // MARK: HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        if toState == .ended {
            workoutBuilder?.endCollection(withEnd: date) { [weak self] _, _ in
                self?.workoutBuilder?.finishWorkout { _, _ in }
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.monitoringMessage = "The workout session ended unexpectedly."
        }
    }
}
#endif
