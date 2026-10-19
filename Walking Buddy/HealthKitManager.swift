import Combine
import HealthKit
import SwiftUI
import UserNotifications
import WidgetKit

#if os(iOS)
import CoreMotion
import CoreLocation
import ActivityKit
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

    @Published var stepsStatus = "0"
    @Published var distanceStatus = "0 m"
    @Published var elapsedTimeStatus = "0:00"
    @Published var riskScoreStatus = "0%"

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

    // MARK: - Shared dependencies & tuning

    private let healthStore = HKHealthStore()
    private let notificationCenter = UNUserNotificationCenter.current()
    private let riskModel = BreakRiskModel()

    /// App Group shared with the Lock Screen widget extension. Must match the
    /// group ID enabled on both the app and widget targets in Xcode.
    static let appGroupID = "group.Walking-Buddy.shared"

    private let maximumAlertFrequency: TimeInterval = 120
    /// Seniors are advised to rest after a continuous walk of this length.
    private let maximumWalkDuration: TimeInterval = 30 * 60

    /// Hold time H: a metric must stay tripped this long continuously to alarm.
    private let sustainedHoldDuration: TimeInterval = 3
    /// First instant each metric crossed its trip threshold (reset when it drops
    /// back below). Drives the sustained-dwell equation.
    private var metricTripStart: [String: Date] = [:]

    // MARK: - Shared latest readings (inputs to the equation)

    private var latestWalkingSpeed: Double?
    private var latestCadence: Double?
    private var latestWalkingSteadiness: Double?
    private var latestAsymmetry: Double?
    private var latestDoubleSupport: Double?
    private var latestHeartRateFraction: Double?
    private var latestStepCount = 0
    private var lastAlertDate: Date?

    // MARK: - Duration tracking

    private var clockTimer: Timer?
    private var accumulatedWalkTime: TimeInterval = 0
    private var segmentStartDate: Date?
    private var hasWarnedAboutLongWalk = false

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
    private let locationManager = CLLocationManager()
    private let gaitAnalyzer = GaitAnalyzer()
    /// Holds an `Activity<WalkActivityAttributes>` while a walk is running.
    /// Stored as `Any?` so the property doesn't need availability annotation.
    private var liveActivity: Any?
    #endif

    // MARK: - watchOS-only workout state

    #if os(watchOS)
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var maxHeartRate: Double = 220 - 70   // updated from the user's age
    #endif

    // MARK: - Lifecycle (shared)

    func requestAuthorizationAndStart() {
        requestNotificationAuthorization()
        requestHealthAuthorization { [weak self] in
            self?.startSession()
        }
    }

    func stopSession() {
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
        monitoringMessage = "Monitoring stopped."
        publishWidgetSnapshot()

        #if os(iOS)
        if #available(iOS 16.2, *) { endLiveActivity() }
        #endif
    }

    func pauseSession() {
        isPaused = true
        if let segmentStartDate {
            accumulatedWalkTime += Date().timeIntervalSince(segmentStartDate)
        }
        segmentStartDate = nil
        metricTripStart.removeAll()
        stopClock()
        stopSensors()
        monitoringMessage = "Monitoring paused. Data preserved."
    }

    func resumeSession() {
        isPaused = false
        isTracking = true
        segmentStartDate = Date()
        startClock()
        startSensors()
        monitoringMessage = "Resumed live monitoring."
    }

    private func startSession() {
        isTracking = true
        isPaused = false
        hasWarnedAboutLongWalk = false
        metricTripStart.removeAll()
        accumulatedWalkTime = 0
        segmentStartDate = Date()
        stepsStatus = "0"
        distanceStatus = "0 m"
        elapsedTimeStatus = "0:00"
        riskScoreStatus = "0%"
        monitoringMessage = "Reading live walking data from the sensors."

        startClock()
        startSensors()

        #if os(iOS)
        if #available(iOS 16.2, *) { startLiveActivity() }
        #endif
    }

    private func resetLatestReadings() {
        latestWalkingSpeed = nil
        latestCadence = nil
        latestWalkingSteadiness = nil
        latestAsymmetry = nil
        latestDoubleSupport = nil
        latestHeartRateFraction = nil
        latestStepCount = 0
        metricTripStart.removeAll()
    }

    // MARK: - Duration clock (shared)

    private func startClock() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickClock()
        }
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func tickClock() {
        elapsedTimeStatus = Self.durationFormatter.string(from: currentElapsed) ?? "0:00"
        checkWalkDuration()
        updateBreakRisk()
    }

    private func checkWalkDuration() {
        guard !hasWarnedAboutLongWalk, currentElapsed >= maximumWalkDuration else { return }
        hasWarnedAboutLongWalk = true
        let minutes = Int(maximumWalkDuration / 60)
        presentBreakAlert(
            message: "You have been walking for about \(minutes) minutes. Please find a safe place to sit down and rest."
        )
    }

    // MARK: - The "needs a break" equation (shared)

    private func updateBreakRisk() {
        let inputs = BreakRiskModel.Inputs(
            walkingSpeed: latestWalkingSpeed,
            cadence: latestCadence,
            steadiness: latestWalkingSteadiness,
            asymmetry: latestAsymmetry,
            doubleSupport: latestDoubleSupport,
            heartRateFraction: latestHeartRateFraction,
            durationFraction: currentElapsed / maximumWalkDuration,
            stepCount: latestStepCount
        )

        let result = riskModel.evaluate(inputs)
        riskScoreStatus = "\(Int((result.score * 100).rounded()))%"
        publishWidgetSnapshot()

        // Alarm only when a metric has stayed tripped for the full hold window.
        let sustained = evaluateSustainedAlarm(result)
        guard !sustained.isEmpty, latestStepCount >= riskModel.minimumStepsBeforeAlert else { return }
        presentBreakAlert(message: breakMessage(from: sustained))
    }

    /// Applies the sustained-dwell equation: a metric must stay at or above the
    /// trip threshold τ continuously for `sustainedHoldDuration` (H) before it
    /// counts. Returns the reasons for every metric currently alarming.
    ///
    ///     Iₘ(t) = [ sₘ(t) ≥ τ ]
    ///     Dₘ(t) = t − (last instant Iₘ was 0)
    ///     Aₘ(t) = [ Iₘ(t)=1  ∧  Dₘ(t) ≥ H ]
    private func evaluateSustainedAlarm(_ result: BreakRiskModel.Result) -> [String] {
        let now = Date()
        var alarmingReasons: [String] = []

        for contribution in result.contributions {
            if contribution.score >= riskModel.tripThreshold {
                let start = metricTripStart[contribution.metric] ?? now
                metricTripStart[contribution.metric] = start
                if now.timeIntervalSince(start) >= sustainedHoldDuration {
                    alarmingReasons.append(contribution.reason)
                }
            } else {
                // Dropped below τ — reset this metric's dwell timer.
                metricTripStart[contribution.metric] = nil
            }
        }

        return alarmingReasons
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

    private func breakMessage(from reasons: [String]) -> String {
        guard !reasons.isEmpty else {
            return "Your walking pattern suggests fatigue. Please find a safe place to sit down and rest."
        }
        return "Your \(reasons.joined(separator: ", and ")). Please find a safe place to sit down and rest."
    }

    // MARK: - Alerting (shared)

    private func presentBreakAlert(message: String) {
        alertMessage = message
        if !triggersAlert {
            HapticsManager.strongAlert()
        }
        triggersAlert = true
        scheduleBreakNotificationIfNeeded(message: message)
    }

    private func scheduleBreakNotificationIfNeeded(message: String) {
        let now = Date()
        if let lastAlertDate, now.timeIntervalSince(lastAlertDate) < maximumAlertFrequency {
            return
        }
        lastAlertDate = now

        let content = UNMutableNotificationContent()
        content.title = "Time to Take a Break"
        content.body = "\(message)\n\(currentMetricsSummary())"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "walking-break-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        notificationCenter.add(request)
    }

    private func currentMetricsSummary() -> String {
        "Steps: \(stepsStatus) | Distance: \(distanceStatus) | Time: \(elapsedTimeStatus) | Risk: \(riskScoreStatus)"
    }

    private func requestNotificationAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
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

        refreshGaitBaseline()
        startBackgroundLocation()

        #if targetEnvironment(simulator)
        startSimulatedWalkingUpdates()
        monitoringMessage = "Using simulated walking data. Test live sensors on a real iPhone."
        #else
        startPedometerUpdates(from: Date())
        startLiveGaitAnalysis()
        #endif
    }

    /// Streams real-time gait estimates from the IMU into the live metrics,
    /// overriding the frozen HealthKit baseline during the walk.
    private func startLiveGaitAnalysis() {
        guard gaitAnalyzer.isAvailable else { return }
        gaitAnalyzer.onUpdate = { [weak self] metrics in
            guard let self else { return }

            if let steadiness = metrics.steadiness {
                self.latestWalkingSteadiness = steadiness
                self.steadinessStatus = Self.percentFormatter.string(from: NSNumber(value: steadiness))
                    ?? "\(Int(steadiness * 100))%"
            }
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
                self.latestCadence = cadence
                self.cadenceStatus = "\(Int(cadence * 60)) steps/min"
                // Live step length = speed / cadence when both are known.
                if let speed = self.latestWalkingSpeed, cadence > 0 {
                    self.stepLengthStatus = Self.metersString(speed / cadence)
                }
            }

            self.updateBreakRisk()
        }
        gaitAnalyzer.start()
    }

    private func stopSensors() {
        pedometer.stopUpdates()
        pedometer.stopEventUpdates()
        gaitAnalyzer.stop()
        simulatorTimer?.invalidate()
        simulatorTimer = nil
        locationManager.stopUpdatingLocation()
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

        healthStore.requestAuthorization(toShare: nil, read: iOSReadTypes()) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshGaitBaseline()
                completion()
            }
        }
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
        latestStepCount = data.numberOfSteps.intValue
        stepsStatus = "\(latestStepCount)"

        if let distance = data.distance?.doubleValue {
            distanceStatus = Self.metersString(distance)
        }

        if let pace = data.currentPace?.doubleValue, pace > 0 {
            let metersPerSecond = 1 / pace
            latestWalkingSpeed = metersPerSecond
            currentPaceStatus = Self.speedString(metersPerSecond)
        }

        if let cadence = data.currentCadence?.doubleValue {
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
        fetchMostRecent(.appleWalkingSteadiness, unit: .percent()) { [weak self] value in
            guard let self, let value else { return }
            self.latestWalkingSteadiness = value
            self.steadinessStatus = Self.percentFormatter.string(from: NSNumber(value: value)) ?? "\(Int(value * 100))%"
            self.updateBreakRisk()
        }
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
            self.stepLengthStatus = Self.metersString(value)
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
        simulatorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            elapsedSeconds += 1
            let fatigueStarts = elapsedSeconds > 20
            let speed = fatigueStarts ? 0.62 : 1.05
            let cadence = fatigueStarts ? 0.95 : 1.45
            self.latestWalkingSpeed = speed
            self.latestCadence = cadence
            self.latestStepCount = Int(Double(elapsedSeconds) * cadence)
            self.latestWalkingSteadiness = fatigueStarts ? 0.35 : 0.75
            self.stepsStatus = "\(self.latestStepCount)"
            self.distanceStatus = Self.metersString(Double(elapsedSeconds) * speed)
            self.currentPaceStatus = Self.speedString(speed)
            self.cadenceStatus = "\(Int(cadence * 60)) steps/min"
            self.steadinessStatus = fatigueStarts ? "Low" : "OK"
            self.updateBreakRisk()
        }
    }
}

// MARK: - Background keep-alive (location updates are intentionally unused)

extension HealthKitManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
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
        guard liveActivity == nil,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            liveActivity = try Activity.request(
                attributes: WalkActivityAttributes(),
                content: ActivityContent(state: liveActivityState, staleDate: nil)
            )
        } catch {
            liveActivity = nil
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
    }

    private func stopSensors() {
        workoutSession?.end()
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
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
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
                heartRateStatus = "\(Int(bpm)) bpm"
                if maxHeartRate > 0 { latestHeartRateFraction = bpm / maxHeartRate }
            }
        case HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned):
            if let kcal = statistics.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                activeEnergyStatus = "\(Int(kcal)) kcal"
            }
        case HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning):
            if let meters = statistics.sumQuantity()?.doubleValue(for: .meter()) {
                distanceStatus = Self.metersString(meters)
                let seconds = currentElapsed
                if seconds > 0 { latestWalkingSpeed = meters / seconds }
            }
        case HKQuantityType.quantityType(forIdentifier: .stepCount):
            if let steps = statistics.sumQuantity()?.doubleValue(for: .count()) {
                latestStepCount = Int(steps)
                stepsStatus = "\(latestStepCount)"
                let minutes = currentElapsed / 60
                if minutes > 0 { latestCadence = steps / currentElapsed }
            }
        default:
            break
        }
        updateBreakRisk()
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
