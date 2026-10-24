import Foundation

/// A transparent, weighted model that fuses every available walking metric into
/// a single "needs a break" score between 0 and 1.
///
/// The idea is a small scientific equation:
///
///     risk = ( Σ weightᵢ · subScoreᵢ ) / ( Σ weightᵢ )
///
/// Each metric produces a `subScore` in the range 0...1 describing how far it has
/// drifted from a senior-safe range. Metrics that are missing on the current
/// device (for example heart rate on an iPhone, or gait metrics on a Watch)
/// simply drop out of both sums, so the equation stays correctly normalized.
struct BreakRiskModel {

    // MARK: - Senior-safe reference values

    // Sources: Apple HealthKit mobility documentation and common clinical gait
    // norms for older adults. These are intentionally conservative.
    var safeWalkingSpeed = 0.8        // m/s   — below this is slow / unsafe
    var safeCadence = 1.2             // steps/s
    var safeStepLength = 0.55         // m     — steps shorten ("shuffle") with fatigue
    var steadinessFloor = 0.6         // 0...1 — below this the gait is unsteady
    var normalAsymmetry = 0.05        // 5%    — above this steps are uneven
    var asymmetryCeiling = 0.20       // 20%   — fully "risky"
    var normalDoubleSupport = 0.30    // 30%   — typical is 20–40%
    var doubleSupportCeiling = 0.45   // 45%   — too long balancing on both feet
    var safeHeartRateFraction = 0.70  // fraction of max HR considered the ceiling
    var heartRateCeiling = 0.90
    var exertionFlights = 2.0         // flights of stairs before exertion starts counting
    var flightsCeiling = 8.0          // flights at which stair exertion is fully "risky"

    /// Composite score at or above which we recommend a break.
    var breakThreshold = 0.45

    /// Per-metric trip threshold τ: a single metric's sub-score at or above this
    /// is considered "tripped" and starts its sustained-dwell timer.
    var tripThreshold = 0.5

    /// Require a little walking before alerting, to avoid false positives at the
    /// very start of a session.
    var minimumStepsBeforeAlert = 12

    // MARK: - Weights (relative importance of each signal)

    private enum Metric: String, CaseIterable {
        case speed, cadence, stepLength, steadiness, asymmetry, doubleSupport, heartRate, duration, flights
    }

    private let weights: [Metric: Double] = [
        .speed: 1.0,
        .cadence: 1.0,
        .stepLength: 1.0,
        .steadiness: 1.5,
        .asymmetry: 1.2,
        .doubleSupport: 1.2,
        .heartRate: 1.3,
        .duration: 1.0,
        .flights: 0.8,
    ]

    // MARK: - Inputs / Result

    struct Inputs {
        var walkingSpeed: Double?        // m/s
        var cadence: Double?             // steps/s
        var stepLength: Double?          // m
        var steadiness: Double?          // 0...1
        var asymmetry: Double?           // 0...1 (fraction)
        var doubleSupport: Double?       // 0...1 (fraction)
        var heartRateFraction: Double?   // 0...1 of max HR
        var durationFraction: Double?    // elapsed / maximum walk duration
        var flightsClimbed: Double?      // stairs climbed so far this walk
        var stepCount: Int = 0
    }

    /// One metric's contribution on a single evaluation.
    struct Contribution {
        let metric: String
        let score: Double            // 0...1 sub-score
        let reason: String
    }

    struct Result {
        var score: Double            // 0...1 composite risk
        var reasons: [String]        // human-readable contributors (sub-score ≥ 0.5)
        var needsBreak: Bool
        var contributions: [Contribution]   // every present metric's sub-score
    }

    // MARK: - Evaluation

    func evaluate(_ input: Inputs) -> Result {
        var weightedSum = 0.0
        var totalWeight = 0.0
        var reasons: [String] = []
        var contributions: [Contribution] = []

        func contribute(_ metric: Metric, _ risk: Double?, reason: String) {
            guard let risk, let weight = weights[metric] else { return }
            let clamped = min(max(risk, 0), 1)
            weightedSum += clamped * weight
            totalWeight += weight
            contributions.append(Contribution(metric: metric.rawValue, score: clamped, reason: reason))
            if clamped >= 0.5 {
                reasons.append(reason)
            }
        }

        contribute(.speed,
                   input.walkingSpeed.map { deficit(value: $0, safe: safeWalkingSpeed) },
                   reason: "walking speed has dropped")
        contribute(.cadence,
                   input.cadence.map { deficit(value: $0, safe: safeCadence) },
                   reason: "step cadence has slowed")
        contribute(.stepLength,
                   input.stepLength.map { deficit(value: $0, safe: safeStepLength) },
                   reason: "your steps are getting shorter")
        contribute(.steadiness,
                   input.steadiness.map { deficit(value: $0, safe: steadinessFloor) },
                   reason: "walking steadiness is low")
        contribute(.asymmetry,
                   input.asymmetry.map { excess(value: $0, normal: normalAsymmetry, ceiling: asymmetryCeiling) },
                   reason: "your steps are becoming uneven")
        contribute(.doubleSupport,
                   input.doubleSupport.map { excess(value: $0, normal: normalDoubleSupport, ceiling: doubleSupportCeiling) },
                   reason: "you are spending longer balancing on both feet")
        contribute(.heartRate,
                   input.heartRateFraction.map { excess(value: $0, normal: safeHeartRateFraction, ceiling: heartRateCeiling) },
                   reason: "your heart rate is elevated")
        contribute(.duration,
                   input.durationFraction,
                   reason: "you have been walking for a while")
        contribute(.flights,
                   input.flightsClimbed.map { excess(value: $0, normal: exertionFlights, ceiling: flightsCeiling) },
                   reason: "you have climbed several flights of stairs")

        let score = totalWeight > 0 ? weightedSum / totalWeight : 0
        let needsBreak = input.stepCount >= minimumStepsBeforeAlert && score >= breakThreshold
        return Result(score: score, reasons: reasons, needsBreak: needsBreak, contributions: contributions)
    }

    // MARK: - In-app explainer

    /// One row in the break-risk explainer: a metric, its weight in the equation,
    /// and a plain-language description of how its 0...1 sub-score is computed.
    struct MetricInfo: Identifiable {
        let id = UUID()
        let name: String
        let weight: Double
        let rule: String
    }

    /// Describes every metric in the equation, straight from the live weights and
    /// reference values, so the in-app explainer always matches the real model.
    var metricInfo: [MetricInfo] {
        func pct(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
        return [
            MetricInfo(name: "Walking speed", weight: weights[.speed] ?? 0,
                       rule: "Risk climbs as speed falls below \(String(format: "%.1f", safeWalkingSpeed)) m/s."),
            MetricInfo(name: "Cadence", weight: weights[.cadence] ?? 0,
                       rule: "Risk climbs as cadence slows below \(String(format: "%.1f", safeCadence)) steps/s."),
            MetricInfo(name: "Step length", weight: weights[.stepLength] ?? 0,
                       rule: "Risk climbs as steps shorten below \(String(format: "%.2f", safeStepLength)) m."),
            MetricInfo(name: "Steadiness", weight: weights[.steadiness] ?? 0,
                       rule: "Risk climbs as steadiness drops below \(pct(steadinessFloor))."),
            MetricInfo(name: "Asymmetry", weight: weights[.asymmetry] ?? 0,
                       rule: "Risk rises from \(pct(normalAsymmetry)) up to \(pct(asymmetryCeiling)) unevenness."),
            MetricInfo(name: "Double support", weight: weights[.doubleSupport] ?? 0,
                       rule: "Risk rises from \(pct(normalDoubleSupport)) up to \(pct(doubleSupportCeiling)) of each step on both feet."),
            MetricInfo(name: "Heart rate", weight: weights[.heartRate] ?? 0,
                       rule: "Risk rises from \(pct(safeHeartRateFraction)) up to \(pct(heartRateCeiling)) of your max heart rate."),
            MetricInfo(name: "Duration", weight: weights[.duration] ?? 0,
                       rule: "Risk rises steadily toward the 30-minute rest reminder."),
            MetricInfo(name: "Stairs climbed", weight: weights[.flights] ?? 0,
                       rule: "Risk rises from \(Int(exertionFlights)) up to \(Int(flightsCeiling)) flights of stairs."),
        ]
    }

    // MARK: - Sub-score helpers

    /// Risk rises as a value falls below a safe floor (speed, cadence, steadiness).
    private func deficit(value: Double, safe: Double) -> Double {
        guard safe > 0 else { return 0 }
        return (safe - value) / safe
    }

    /// Risk rises as a value climbs above normal toward a ceiling (asymmetry,
    /// double support, heart rate).
    private func excess(value: Double, normal: Double, ceiling: Double) -> Double {
        guard ceiling > normal else { return value > normal ? 1 : 0 }
        return (value - normal) / (ceiling - normal)
    }
}
