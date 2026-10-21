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
}

// MARK: - Recorder

/// Collects one walk's readings (one sample per second) and turns them into a `WalkRecord`.
struct WalkRecorder {
    var alerts = 0
    private let start = Date()
    private var peakRisk = 0.0
    private var risk = Mean(), speed = Mean(), cadence = Mean(), steadiness = Mean()
    private var asymmetry = Mean(), doubleSupport = Mean(), heartRate = Mean()

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
                         asymmetry: Double?, doubleSupport: Double?, heartRate: Double?) {
        self.risk.add(risk)
        peakRisk = max(peakRisk, risk)
        self.speed.add(speed)
        self.cadence.add(cadence.map { $0 * 60 })
        self.steadiness.add(steadiness)
        self.asymmetry.add(asymmetry)
        self.doubleSupport.add(doubleSupport)
        self.heartRate.add(heartRate)
    }

    func finish(duration: TimeInterval, steps: Int, distance: Double) -> WalkRecord {
        WalkRecord(start: start, duration: duration, steps: steps, distance: distance,
                   risk: risk.value ?? 0, peakRisk: peakRisk, alerts: alerts, device: Self.deviceName,
                   speed: speed.value, cadence: cadence.value, steadiness: steadiness.value,
                   asymmetry: asymmetry.value, doubleSupport: doubleSupport.value, heartRate: heartRate.value)
    }

    private static var deviceName: String {
        #if os(watchOS)
        return "Apple Watch"
        #else
        return UIDevice.current.model
        #endif
    }
}

// MARK: - Store

/// Every saved walk, oldest first, kept as JSON on disk. Walks finished on the
/// Apple Watch are handed to the iPhone over WatchConnectivity, so the iPhone
/// holds the complete history.
final class WalkHistory: NSObject, ObservableObject {
    static let shared = WalkHistory()

    @Published private(set) var walks: [WalkRecord] = []

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

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo["walk"] as? Data else { return }
        Task { @MainActor in
            if let walk = try? JSONDecoder().decode(WalkRecord.self, from: data) { self.insert(walk) }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
