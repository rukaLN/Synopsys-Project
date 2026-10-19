//
//  GaitAnalyzer.swift
//  Walking Buddy
//
//  Real-time gait estimation from the iPhone's motion sensors (~50 Hz device
//  motion). HealthKit's gait metrics (steadiness, asymmetry, double support,
//  step length) are only recorded passively a handful of times per day, so
//  they can't drive a live session — fetched once, they sit frozen. This class
//  derives live proxies from vertical acceleration so the values actually move
//  and respond within a second or two of the user's gait changing.
//
//  iOS-only (uses CoreMotion device motion). The file is excluded from the
//  watchOS target, which gets its signal from HKWorkoutSession instead.
//

#if os(iOS)
import CoreMotion
import Foundation

final class GaitAnalyzer {

    struct Metrics {
        var cadence: Double?        // steps/s
        var steadiness: Double?     // 0...1 (1 = very steady)
        var asymmetry: Double?      // 0...1 fraction (left/right step-time imbalance)
        var doubleSupport: Double?  // 0...1 fraction (both-feet-down time)
    }

    /// Called on the main thread whenever a fresh estimate is available
    /// (roughly once per detected step, i.e. a few times per second).
    var onUpdate: ((Metrics) -> Void)?

    var isAvailable: Bool { motion.isDeviceMotionAvailable }

    private let motion = CMMotionManager()
    private let queue = OperationQueue()

    // Step-interval history (seconds between consecutive steps).
    private var intervals: [Double] = []
    private let maxIntervals = 16
    private var lastStepTime: TimeInterval = 0

    // Rolling vertical-acceleration buffer for steadiness / stance estimates.
    private var verticalBuffer: [Double] = []
    private let bufferLimit = 150               // ~3 s at 50 Hz

    // Threshold-crossing step detector state (values are in g).
    private var aboveThreshold = false
    private let stepHigh = 0.10
    private let stepLow = 0.04
    private let refractory = 0.25               // min seconds between steps

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        reset()
        motion.deviceMotionUpdateInterval = 1.0 / 50.0
        queue.maxConcurrentOperationCount = 1
        motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            self.process(data)
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        reset()
    }

    private func reset() {
        intervals.removeAll()
        verticalBuffer.removeAll()
        lastStepTime = 0
        aboveThreshold = false
    }

    private func process(_ data: CMDeviceMotion) {
        // Project user acceleration onto the gravity (vertical) axis so the
        // signal is orientation-independent — works with the phone in a pocket.
        let g = data.gravity
        let a = data.userAcceleration
        let gMag = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        let vertical = gMag > 0 ? (a.x * g.x + a.y * g.y + a.z * g.z) / gMag : a.y

        verticalBuffer.append(vertical)
        if verticalBuffer.count > bufferLimit { verticalBuffer.removeFirst() }

        detectStep(value: vertical, now: data.timestamp)
    }

    private func detectStep(value: Double, now: TimeInterval) {
        if !aboveThreshold, value > stepHigh {
            aboveThreshold = true
            if lastStepTime > 0 {
                let dt = now - lastStepTime
                if dt > refractory, dt < 2.0 {     // plausible walking step
                    intervals.append(dt)
                    if intervals.count > maxIntervals { intervals.removeFirst() }
                    lastStepTime = now
                    emit()
                }
            } else {
                lastStepTime = now
            }
        } else if aboveThreshold, value < stepLow {
            aboveThreshold = false
        }
    }

    private func emit() {
        var m = Metrics()

        if intervals.count >= 2 {
            let meanInterval = intervals.reduce(0, +) / Double(intervals.count)
            if meanInterval > 0 { m.cadence = 1.0 / meanInterval }

            if intervals.count >= 4 {
                // Steadiness: lower step-time variability = steadier gait.
                let variance = intervals.reduce(0) { $0 + ($1 - meanInterval) * ($1 - meanInterval) } / Double(intervals.count)
                let cv = meanInterval > 0 ? variance.squareRoot() / meanInterval : 0
                m.steadiness = clamp(1 - (cv - 0.03) / 0.12)

                // Asymmetry: alternate step intervals correspond to left vs
                // right legs; a steady gait keeps them nearly equal.
                let odd = stride(from: 0, to: intervals.count, by: 2).map { intervals[$0] }
                let even = stride(from: 1, to: intervals.count, by: 2).map { intervals[$0] }
                if let l = mean(odd), let r = mean(even), (l + r) > 0 {
                    m.asymmetry = clamp(abs(l - r) / ((l + r) / 2), upper: 1)
                }
            }
        }

        // Double-support proxy: fraction of recent samples near zero vertical
        // acceleration (both feet planted / stance phase).
        if verticalBuffer.count >= 50 {
            let quiet = verticalBuffer.filter { abs($0) < 0.03 }.count
            let fraction = Double(quiet) / Double(verticalBuffer.count)
            m.doubleSupport = min(max(fraction, 0.1), 0.6)
        }

        let metrics = m
        OperationQueue.main.addOperation { [weak self] in
            self?.onUpdate?(metrics)
        }
    }

    private func clamp(_ x: Double, lower: Double = 0, upper: Double = 1) -> Double {
        min(max(x, lower), upper)
    }

    private func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
}
#endif
