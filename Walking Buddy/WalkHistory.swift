import Combine
import Foundation
import WatchConnectivity

#if os(iOS)
import UIKit
#endif

// MARK: - Walk record

/// One finished walk: its totals plus the average of every signal during the walk.
struct WalkRecord: Codable, Identifiable {
    var id = UUID()
    var start: Date
    var duration: TimeInterval      // seconds
    var steps: Int
    var distance: Double            // metres
    var risk: Double                // average break risk, 0...1
    var peakRisk: Double            // highest break risk reached, 0...1
    var alerts: Int                 // break alerts raised during the walk
    var device: String              // "iPhone", "iPad" or "Apple Watch"
    var speed: Double?              // m/s
    var cadence: Double?            // steps/min
    var steadiness: Double?         // 0...1
    var asymmetry: Double?          // 0...1
    var doubleSupport: Double?      // 0...1
    var heartRate: Double?          // bpm, Apple Watch only
    var steadinessCV: Double?       // avg step-time coefficient of variation — personal steadiness calibration
}

// MARK: - Recorder

/// Collects one walk's readings (one sample per second) and turns them into a `WalkRecord`.
struct WalkRecorder {
    var alerts = 0
    private let start = Date()
    private var peakRisk = 0.0
    private var risk = Mean(), speed = Mean(), cadence = Mean(), steadiness = Mean()
    private var asymmetry = Mean(), doubleSupport = Mean(), heartRate = Mean()
    private var steadinessCV = Mean()

    private struct Mean {
        private var sum = 0.0
        private var count = 0
        var value: Double? { count > 0 ? sum / Double(count) : nil }

        mutating func add(_ sample: Double?) {
            guard let sample else { return }
            sum += sample
            count += 1
        }
    }

    /// `cadence` is in steps/s; missing readings (nil) are simply left out of the averages.
    mutating func sample(risk: Double, speed: Double?, cadence: Double?, steadiness: Double?,
                         asymmetry: Double?, doubleSupport: Double?, heartRate: Double?,
                         steadinessCV: Double?) {
        self.risk.add(risk)
        peakRisk = max(peakRisk, risk)
        self.speed.add(speed)
        self.cadence.add(cadence.map { $0 * 60 })
        self.steadiness.add(steadiness)
        self.asymmetry.add(asymmetry)
        self.doubleSupport.add(doubleSupport)
        self.heartRate.add(heartRate)
        self.steadinessCV.add(steadinessCV)
    }

    func finish(duration: TimeInterval, steps: Int, distance: Double) -> WalkRecord {
        WalkRecord(start: start, duration: duration, steps: steps, distance: distance,
                   risk: risk.value ?? 0, peakRisk: peakRisk, alerts: alerts, device: Self.deviceName,
                   speed: speed.value, cadence: cadence.value, steadiness: steadiness.value,
                   asymmetry: asymmetry.value, doubleSupport: doubleSupport.value, heartRate: heartRate.value,
                   steadinessCV: steadinessCV.value)
    }

    private static var deviceName: String {
        #if os(watchOS)
        return "Apple Watch"
        #else
        return UIDevice.current.model
        #endif
    }
}

// MARK: - Personal steadiness calibration

/// Maps the raw step-time variability (CV) to a 0...1 steadiness score using the
/// individual's own history. The steadiest walk the person has recorded anchors
/// "100%", so the number reflects *their* normal rather than a generic threshold.
struct SteadinessCalibration {
    /// Lowest observed average CV (steadiest) → 100% steadiness.
    let bestCV: Double
    /// CV at which steadiness reads 0% (least steady).
    let floorCV: Double

    func steadiness(forCV cv: Double) -> Double {
        guard floorCV > bestCV else { return cv <= bestCV ? 1 : 0 }
        return min(max((floorCV - cv) / (floorCV - bestCV), 0), 1)
    }
}

extension WalkHistory {
    /// Walks needed before a personal steadiness baseline is trustworthy — matches
    /// the trend threshold, so calibration kicks in once trends do.
    static let minimumWalksForCalibration = 3

    /// A personal steadiness baseline, available once enough walks carry CV data.
    /// `nil` until then (callers fall back to the generic estimate).
    var steadinessCalibration: SteadinessCalibration? {
        let cvs = walks.compactMap { $0.steadinessCV }.filter { $0 > 0 }
        guard cvs.count >= Self.minimumWalksForCalibration,
              let best = cvs.min(), let worst = cvs.max() else { return nil }
        // Guarantee a usable range so the steadiest walk doesn't peg everything at 100%.
        let floor = Swift.max(worst, best + 0.08)
        return SteadinessCalibration(bestCV: best, floorCV: floor)
    }
}

// MARK: - Store

/// Every saved walk, oldest first, kept as JSON on disk. Walks finished on the
/// Apple Watch are handed to the iPhone over WatchConnectivity, so the iPhone
/// holds the complete history.
final class WalkHistory: NSObject, ObservableObject {
    static let shared = WalkHistory()

    @Published private(set) var walks: [WalkRecord] = []

    // MARK: - Live cross-device sync

    /// Live Watch-only readings streamed to the iPhone during a walk (the values an
    /// iPhone can't measure on its own). Sent latest-wins over WatchConnectivity.
    nonisolated struct LiveMetrics: Codable {
        var heartRate: Double?           // bpm
        var heartRateFraction: Double?   // 0...1 of max HR
        var activeEnergyKcal: Double?    // kcal
        var timestamp: Date = Date()
    }

    /// Set by the active `HealthKitManager`. Invoked on the main actor when the
    /// counterpart device asks us to start/stop a walk, or sends live metrics.
    var onRemoteStart: (() -> Void)?
    var onRemoteStop: (() -> Void)?
    var onRemotePause: (() -> Void)?
    var onRemoteResume: (() -> Void)?
    var onLiveMetrics: ((LiveMetrics) -> Void)?

    /// True when the counterpart app is available for immediate messaging.
    var isCounterpartReachable: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    /// iPhone-side: true when a paired Apple Watch has the app installed.
    var hasPairedWatchApp: Bool {
        #if os(iOS)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return false }
        return WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
        #else
        return false
        #endif
    }

    /// iPhone-side: an Apple Watch is paired to this iPhone (app may or may not be installed).
    var isWatchPaired: Bool {
        #if os(iOS)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return false }
        return WCSession.default.isPaired
        #else
        return false
        #endif
    }

    /// iPhone-side: our watch app is installed on the paired Apple Watch.
    var isWatchAppInstalled: Bool {
        #if os(iOS)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return false }
        return WCSession.default.isWatchAppInstalled
        #else
        return false
        #endif
    }

    private let limit = 200
    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("walks.json")

    private override init() {
        super.init()
        walks = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([WalkRecord].self, from: $0) } ?? []
        startSync()
    }

    func add(_ walk: WalkRecord) {
        insert(walk)
        #if os(watchOS)
        if let data = try? JSONEncoder().encode(walk) {
            WCSession.default.transferUserInfo(["walk": data])
        }
        #endif
    }

    func clear() {
        walks = []
        save()
    }

    private func insert(_ walk: WalkRecord) {
        guard !walks.contains(where: { $0.id == walk.id }) else { return }
        walks.append(walk)
        walks.sort { $0.start < $1.start }
        walks = Array(walks.suffix(limit))
        save()
    }

    private func save() {
        try? JSONEncoder().encode(walks).write(to: fileURL, options: .atomic)
    }
}

// MARK: - Apple Watch → iPhone sync

extension WalkHistory: WCSessionDelegate {

    private func startSync() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Sending

    /// Tells the counterpart device to start or stop a walk ("start" / "stop").
    /// Delivered immediately when reachable, otherwise queued for background delivery.
    func sendCommand(_ command: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let message = ["cmd": command]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { _ in
                WCSession.default.transferUserInfo(message)
            }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

    /// Streams the Watch's live heart-rate / energy to the iPhone. Uses application
    /// context (latest-wins, delivered even in the background) plus an immediate
    /// message when the iPhone is reachable for low latency.
    func sendLiveMetrics(_ metrics: LiveMetrics) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = try? JSONEncoder().encode(metrics) else { return }
        try? WCSession.default.updateApplicationContext(["live": data])
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["live": data], replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: Receiving

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo["walk"] as? Data {
            Task { @MainActor in
                if let walk = try? JSONDecoder().decode(WalkRecord.self, from: data) { self.insert(walk) }
            }
        }
        handlePayload(userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handlePayload(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handlePayload(applicationContext)
    }

    /// Routes start/stop commands and live metrics to the active `HealthKitManager`.
    private nonisolated func handlePayload(_ payload: [String: Any]) {
        if let command = payload["cmd"] as? String {
            Task { @MainActor in
                switch command {
                case "start": self.onRemoteStart?()
                case "stop": self.onRemoteStop?()
                case "pause": self.onRemotePause?()
                case "resume": self.onRemoteResume?()
                default: break
                }
            }
        }
        if let data = payload["live"] as? Data,
           let metrics = try? JSONDecoder().decode(LiveMetrics.self, from: data) {
            Task { @MainActor in self.onLiveMetrics?(metrics) }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
