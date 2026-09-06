import Combine
import CoreMotion
import HealthKit
import SwiftUI
import UserNotifications

final class HealthKitManager: NSObject, ObservableObject {
    @Published var isTracking = false
    @Published var steadinessStatus = "Unknown"
    @Published var currentPaceStatus = "Unknown"
    @Published var cadenceStatus = "Unknown"
    @Published var stepsStatus = "0"
    @Published var distanceStatus = "0 m"
    @Published var monitoringMessage = "Start monitoring when the senior begins walking."
    @Published var alertMessage = "Your walking pattern suggests fatigue. Please find a safe place to sit down for a few minutes."
    @Published var triggersAlert = false

    private let healthStore = HKHealthStore()
    private let pedometer = CMPedometer()
    private let notificationCenter = UNUserNotificationCenter.current()
    private let walkingSpeedType = HKQuantityType.quantityType(forIdentifier: .walkingSpeed)
    private let walkingSteadinessType = HKQuantityType.quantityType(forIdentifier: .appleWalkingSteadiness)
    private let walkingSpeedUnit = HKUnit.meter().unitDivided(by: .second())
    private let steadinessUnit = HKUnit.percent()
    private let minimumSafeSpeed = 0.8
    private let minimumSafeCadence = 1.2
    private let maximumAlertFrequency: TimeInterval = 120

    private var latestWalkingSpeed: Double?
    private var latestWalkingSteadiness: Double?
    private var latestCadence: Double?
    private var latestStepCount = 0
    private var lastAlertDate: Date?
    private var simulatorTimer: Timer?

    func requestAuthorizationAndStart() {
        requestNotificationAuthorization()
        requestHealthAuthorizationForContext()
        startSession()
    }

    private func requestHealthAuthorizationForContext() {
        guard HKHealthStore.isHealthDataAvailable() else {
            steadinessStatus = "Unavailable"
            return
        }
        
        let readTypes = healthReadTypes()
        healthStore.requestAuthorization(toShare: nil, read: readTypes) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }

                if success {
                    self.refreshLatestWalkingSteadiness()
                } else {
                    self.steadinessStatus = "Permission Denied"
                }
            }
        }
    }

    func stopSession() {
        isTracking = false
        triggersAlert = false
        latestWalkingSpeed = nil
        latestWalkingSteadiness = nil
        latestCadence = nil
        latestStepCount = 0
        simulatorTimer?.invalidate()
        simulatorTimer = nil
        pedometer.stopUpdates()
        pedometer.stopEventUpdates()
        monitoringMessage = "Monitoring stopped."
    }

    private func startSession() {
        isTracking = true
        steadinessStatus = "Waiting for Data"
        currentPaceStatus = "Waiting for Data"
        cadenceStatus = "Waiting for Data"
        stepsStatus = "0"
        distanceStatus = "0 m"
        monitoringMessage = "Reading live pace and cadence from the motion sensors."

        let startDate = Date()

        #if targetEnvironment(simulator)
        startSimulatedWalkingUpdates()
        steadinessStatus = "Simulator"
        monitoringMessage = "Using simulated walking data. Test live sensors on a real iPhone."
        #else
        startPedometerUpdates(from: startDate)
        #endif
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
                    self.isTracking = false
                    return
                }

                guard let data else { return }
                self.updateLiveWalkingPattern(from: data)
            }
        }
    }

    private func updateLiveWalkingPattern(from data: CMPedometerData) {
        latestStepCount = data.numberOfSteps.intValue
        stepsStatus = "\(latestStepCount)"

        if let distance = data.distance?.doubleValue {
            distanceStatus = Self.distanceFormatter.string(fromMeters: distance)
        }

        if let pace = data.currentPace?.doubleValue, pace > 0 {
            let metersPerSecond = 1 / pace
            latestWalkingSpeed = metersPerSecond
            currentPaceStatus = Self.speedFormatter.string(fromMetersPerSecond: metersPerSecond)
        } else if CMPedometer.isPaceAvailable() {
            currentPaceStatus = "Waiting for Pace"
        } else {
            currentPaceStatus = "Pace Unsupported"
        }

        if let cadence = data.currentCadence?.doubleValue {
            latestCadence = cadence
            cadenceStatus = Self.cadenceFormatter.string(fromStepsPerSecond: cadence)
        } else if CMPedometer.isCadenceAvailable() {
            cadenceStatus = "Waiting for Cadence"
        } else {
            cadenceStatus = "Cadence Unsupported"
        }

        monitoringMessage = "Monitoring live steps, pace, cadence, and Health mobility context."
        updateGaitRiskAlert()
    }

    private func refreshLatestWalkingSteadiness() {
        guard let walkingSteadinessType else {
            steadinessStatus = "Unsupported"
            return
        }

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: walkingSteadinessType,
            predicate: nil,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) { [weak self] _, samples, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if error != nil {
                    self.steadinessStatus = "Unavailable"
                    return
                }

                guard let sample = samples?.first as? HKQuantitySample else {
                    self.steadinessStatus = "No Saved Data"
                    return
                }

                self.latestWalkingSteadiness = sample.quantity.doubleValue(for: self.steadinessUnit)
                self.steadinessStatus = Self.steadinessDescription(for: sample.quantity)
                self.updateGaitRiskAlert()
            }
        }

        healthStore.execute(query)
    }

    private func updateLiveWalkingPattern(speed: Double, cadence: Double, steps: Int, distance: Double) {
        latestWalkingSpeed = speed
        latestCadence = cadence
        latestStepCount = steps
        stepsStatus = "\(steps)"
        distanceStatus = Self.distanceFormatter.string(fromMeters: distance)
        currentPaceStatus = Self.speedFormatter.string(fromMetersPerSecond: speed)
        cadenceStatus = Self.cadenceFormatter.string(fromStepsPerSecond: cadence)
        updateGaitRiskAlert()
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
            let steps = Int(Double(elapsedSeconds) * cadence)
            let distance = Double(elapsedSeconds) * speed

            self.updateLiveWalkingPattern(speed: speed, cadence: cadence, steps: steps, distance: distance)
        }
    }

    private func updateWalkingSpeed(from statistics: HKStatistics?) {
        guard let quantity = statistics?.mostRecentQuantity() ?? statistics?.averageQuantity() else { return }

        let metersPerSecond = quantity.doubleValue(for: walkingSpeedUnit)
        latestWalkingSpeed = metersPerSecond
        currentPaceStatus = Self.speedFormatter.string(fromMetersPerSecond: metersPerSecond)
        updateGaitRiskAlert()
    }

    private func updateWalkingSteadiness(from statistics: HKStatistics?) {
        guard let quantity = statistics?.mostRecentQuantity() ?? statistics?.averageQuantity() else { return }

        latestWalkingSteadiness = quantity.doubleValue(for: steadinessUnit)
        steadinessStatus = Self.steadinessDescription(for: quantity)
        updateGaitRiskAlert()
    }

    private func updateGaitRiskAlert() {
        let paceRisk = latestWalkingSpeed.map { $0 < minimumSafeSpeed } ?? false
        let cadenceRisk = latestCadence.map { $0 < minimumSafeCadence } ?? false
        let steadinessRisk = latestWalkingSteadiness.map { $0 < 0.4 } ?? false
        let shouldAlert = latestStepCount >= 12 && (paceRisk || cadenceRisk || steadinessRisk)

        guard shouldAlert else {
            triggersAlert = false
            return
        }

        alertMessage = breakMessage(paceRisk: paceRisk, cadenceRisk: cadenceRisk, steadinessRisk: steadinessRisk)
        triggersAlert = true
        scheduleBreakNotificationIfNeeded(message: alertMessage)
    }

    private func breakMessage(paceRisk: Bool, cadenceRisk: Bool, steadinessRisk: Bool) -> String {
        var reasons: [String] = []

        if paceRisk {
            reasons.append("walking speed has dropped")
        }

        if cadenceRisk {
            reasons.append("step cadence has slowed")
        }

        if steadinessRisk {
            reasons.append("walking steadiness is low")
        }

        return "Your \(reasons.joined(separator: " and ")). Please find a safe place to sit down and rest."
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
        "Speed: \(currentPaceStatus) | Cadence: \(cadenceStatus) | Steps: \(stepsStatus) | Distance: \(distanceStatus)"
    }

    private func requestNotificationAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func healthReadTypes() -> Set<HKObjectType> {
        [walkingSpeedType, walkingSteadinessType].compactMap { $0 }.reduce(into: Set<HKObjectType>()) { result, type in
            result.insert(type)
        }
    }

    private static func steadinessDescription(for quantity: HKQuantity) -> String {
        if let classification = try? HKAppleWalkingSteadinessClassification(for: quantity) {
            switch classification {
            case .veryLow:
                return "Very Low"
            case .low:
                return "Low"
            case .ok:
                return "OK"
            @unknown default:
                break
            }
        }

        return steadinessDescription(for: quantity.doubleValue(for: .percent()))
    }

    private static func steadinessDescription(for value: Double) -> String {
        switch value {
        case ..<0.2:
            return "Very Low"
        case ..<0.4:
            return "Low"
        default:
            return "OK"
        }
    }

    private static let distanceFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .medium
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let speedFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .medium
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let cadenceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

private extension MeasurementFormatter {
    func string(fromMeters meters: Double) -> String {
        string(from: Measurement(value: meters, unit: UnitLength.meters))
    }

    func string(fromMetersPerSecond metersPerSecond: Double) -> String {
        string(from: Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond))
    }
}

private extension NumberFormatter {
    func string(fromStepsPerSecond stepsPerSecond: Double) -> String {
        let stepsPerMinute = stepsPerSecond * 60
        let formattedValue = string(from: NSNumber(value: stepsPerMinute)) ?? "\(Int(stepsPerMinute.rounded()))"
        return "\(formattedValue) steps/min"
    }
}
