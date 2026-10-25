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
    var flights: Double?            // flights climbed (optional for back-compatibility)
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

    func finish(duration: TimeInterval, steps: Int, distance: Double, flights: Double? = nil) -> WalkRecord {
        WalkRecord(start: start, duration: duration, steps: steps, distance: distance, flights: flights,
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

    /// Live readings streamed from the Apple Watch to the iPhone during a walk. Heart
    /// rate and active energy are values the iPhone can't measure on its own; the rest
    /// let a watch-started walk use the Watch's sensors as the source of truth on the
    /// phone too. All optional, so older/newer payloads decode cleanly (missing = nil).
    /// Sent latest-wins over WatchConnectivity.
    nonisolated struct LiveMetrics: Codable {
        var heartRate: Double?           // bpm
        var heartRateFraction: Double?   // 0...1 of max HR
        var activeEnergyKcal: Double?    // kcal
        var distance: Double?            // metres
        var steps: Int?
        var speed: Double?               // m/s
        var cadence: Double?             // steps/s
        var flights: Double?
        var steadiness: Double?          // 0...1
        var asymmetry: Double?           // 0...1
        var doubleSupport: Double?       // 0...1
        var stepLength: Double?          // metres
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

    /// iPhone-side: true when **this iPhone's own directly-paired** Apple Watch has the
    /// app installed. `WCSession` only ever forms a session with the iPhone's companion
    /// watch, so a Family Setup watch (one managed here for a relative who has no iPhone)
    /// is excluded by design — it never pairs over WatchConnectivity, so sync can't reach
    /// it. `isPaired` reflects the companion watch, not family-managed watches.
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
        // Share recent history with the counterpart device so both sides converge,
        // no matter which device recorded the walk or how it was started.
        syncHistory()
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

// MARK: - Cross-device history sync (iPhone ↔ Apple Watch)

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

    /// Shares a window of recent walks with the counterpart device so both histories —
    /// and their trends — converge, whichever device recorded each walk and whether or
    /// not the walk was started from the other device. Delivered via `transferUserInfo`,
    /// which queues for background delivery, so missed walks catch up on next launch.
    /// Walks dedupe by id on receipt, so re-sending is harmless. On the iPhone this is a
    /// no-op without a paired watch app, so nothing is sent when the user has no watch.
    func syncHistory() {
        #if os(iOS)
        guard hasPairedWatchApp else { return }
        #endif
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = try? JSONEncoder().encode(Array(walks.suffix(30))) else { return }
        WCSession.default.transferUserInfo(["walks": data])
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

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // Once the link is up, share recent history both ways so past walks converge.
        Task { @MainActor in self.syncHistory() }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo["walk"] as? Data {
            Task { @MainActor in
                if let walk = try? JSONDecoder().decode(WalkRecord.self, from: data) { self.insert(walk) }
            }
        }
        // iPhone → watch batch: a window of recent walks to keep trends in sync.
        if let data = userInfo["walks"] as? Data {
            Task { @MainActor in
                if let walks = try? JSONDecoder().decode([WalkRecord].self, from: data) {
                    walks.forEach { self.insert($0) }
                }
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
