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
    var safeWalkingSpeed = 0.9        // m/s   — below this is slow / unsafe
    var safeCadence = 1.3             // steps/s
    var safeStepLength = 0.60         // m     — steps shorten ("shuffle") with fatigue
    var steadinessFloor = 0.7         // 0...1 — below this the gait is unsteady
    var normalAsymmetry = 0.04        // 4%    — above this steps are uneven
    var asymmetryCeiling = 0.15       // 15%   — fully "risky"
    var normalDoubleSupport = 0.28    // 28%   — typical is 20–40%
    var doubleSupportCeiling = 0.40   // 40%   — too long balancing on both feet
    var safeHeartRateFraction = 0.70  // fraction of max HR considered the ceiling
    var heartRateCeiling = 0.90
    var exertionFlights = 2.0         // flights of stairs before exertion starts counting
    var flightsCeiling = 8.0          // flights at which stair exertion is fully "risky"
    var exertionEnergy = 150.0        // kcal of active energy before exertion starts counting
    var energyCeiling = 450.0         // kcal at which exertion is fully "risky"

    /// How much the composite leans on the single worst signal vs. the weighted
    /// average (0 = pure average, 1 = pure worst-signal). Lets one severe reading lift
    /// the overall score into red instead of being averaged away.
    var peakBlend = 0.55

    /// Composite score at or above which we recommend a break.
    var breakThreshold = 0.40

    /// Per-metric trip threshold τ: a single metric's sub-score at or above this
    /// is considered "tripped" and starts its sustained-dwell timer.
    var tripThreshold = 0.45

    /// Require a little walking before alerting, to avoid false positives at the
    /// very start of a session.
    var minimumStepsBeforeAlert = 12

    // MARK: - Weights (relative importance of each signal)

    private enum Metric: String, CaseIterable {
        case speed, cadence, stepLength, asymmetry, doubleSupport, heartRate, duration, flights, activeEnergy
    }

    // Steadiness is intentionally NOT a scored term: it's a composite of walking
    // speed, step length, double support and asymmetry (see `compositeSteadiness`),
    // all of which the equation already scores individually. Scoring it too would
    // double-count those signals. It's computed as a display/trend summary instead.
    private let weights: [Metric: Double] = [
        .speed: 1.0,
        .cadence: 1.0,
        .stepLength: 1.0,
        .asymmetry: 1.2,
        .doubleSupport: 1.2,
        .heartRate: 1.3,
        .duration: 1.0,
        .flights: 0.8,
        .activeEnergy: 0.8,
    ]

    // MARK: - Inputs / Result

    struct Inputs {
        var walkingSpeed: Double?        // m/s
        var cadence: Double?             // steps/s
        var stepLength: Double?          // m
        var asymmetry: Double?           // 0...1 (fraction)
        var doubleSupport: Double?       // 0...1 (fraction)
        var heartRateFraction: Double?   // 0...1 of max HR
        var durationFraction: Double?    // elapsed / maximum walk duration
        var flightsClimbed: Double?      // stairs climbed so far this walk
        var activeEnergy: Double?        // kcal of active energy burned so far this walk
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
        contribute(.activeEnergy,
                   input.activeEnergy.map { excess(value: $0, normal: exertionEnergy, ceiling: energyCeiling) },
                   reason: "you have burned a lot of energy")

        // A plain weighted average is dragged down by the many signals that are
        // legitimately near zero (no stairs, low energy, normal speed, early in the
        // walk), so it tops out around 50% and never reaches red. Blend the average
        // with the *worst* single sub-score so one severe signal (or a few moderate
        // ones) can push the composite into orange/red the way it should.
        let mean = totalWeight > 0 ? weightedSum / totalWeight : 0
        let peak = contributions.map(\.score).max() ?? 0
        let score = min(max(peakBlend * peak + (1 - peakBlend) * mean, 0), 1)
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
            MetricInfo(name: "Active energy", weight: weights[.activeEnergy] ?? 0,
                       rule: "Risk rises from \(Int(exertionEnergy)) up to \(Int(energyCeiling)) kcal burned this walk."),
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

    /// A live "walking steadiness" summary in the Apple style: a 0...1 blend of how
    /// safe the gait-quality signals are — walking speed, step length, double-support
    /// time and asymmetry (1 = very steady). Averages whichever inputs are available,
    /// so it reports as soon as any exist; returns nil only when none do.
    ///
    /// This is a *display / trend* metric derived from signals the break-risk equation
    /// already scores individually, so it is deliberately NOT fed back into the score.
    func compositeSteadiness(walkingSpeed: Double?, stepLength: Double?,
                             doubleSupport: Double?, asymmetry: Double?) -> Double? {
        var subRisks: [Double] = []
        if let speed = walkingSpeed {
            subRisks.append(min(max(deficit(value: speed, safe: safeWalkingSpeed), 0), 1))
        }
        if let length = stepLength {
            subRisks.append(min(max(deficit(value: length, safe: safeStepLength), 0), 1))
        }
        if let ds = doubleSupport {
            subRisks.append(min(max(excess(value: ds, normal: normalDoubleSupport, ceiling: doubleSupportCeiling), 0), 1))
        }
        if let asym = asymmetry {
            subRisks.append(min(max(excess(value: asym, normal: normalAsymmetry, ceiling: asymmetryCeiling), 0), 1))
        }
        guard !subRisks.isEmpty else { return nil }
        let averageRisk = subRisks.reduce(0, +) / Double(subRisks.count)
        return 1 - averageRisk
    }
}
