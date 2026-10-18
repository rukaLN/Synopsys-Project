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
    var steadinessFloor = 0.5         // 0...1 — below this the gait is unsteady
    var normalAsymmetry = 0.05        // 5%    — above this steps are uneven
    var asymmetryCeiling = 0.20       // 20%   — fully "risky"
    var normalDoubleSupport = 0.30    // 30%   — typical is 20–40%
    var doubleSupportCeiling = 0.45   // 45%   — too long balancing on both feet
    var safeHeartRateFraction = 0.70  // fraction of max HR considered the ceiling
    var heartRateCeiling = 0.90

    /// Composite score at or above which we recommend a break.
    var breakThreshold = 0.5

    /// Require a little walking before alerting, to avoid false positives at the
    /// very start of a session.
    var minimumStepsBeforeAlert = 12

    // MARK: - Weights (relative importance of each signal)

    private enum Metric: String, CaseIterable {
        case speed, cadence, steadiness, asymmetry, doubleSupport, heartRate, duration
    }

    private let weights: [Metric: Double] = [
        .speed: 1.0,
        .cadence: 1.0,
        .steadiness: 1.5,
        .asymmetry: 1.2,
        .doubleSupport: 1.2,
        .heartRate: 1.3,
        .duration: 1.0,
    ]

    // MARK: - Inputs / Result

    struct Inputs {
        var walkingSpeed: Double?        // m/s
        var cadence: Double?             // steps/s
        var steadiness: Double?          // 0...1
        var asymmetry: Double?           // 0...1 (fraction)
        var doubleSupport: Double?       // 0...1 (fraction)
        var heartRateFraction: Double?   // 0...1 of max HR
        var durationFraction: Double?    // elapsed / maximum walk duration
        var stepCount: Int = 0
    }

    struct Result {
        var score: Double            // 0...1 composite risk
        var reasons: [String]        // human-readable contributors
        var needsBreak: Bool
    }

    // MARK: - Evaluation

    func evaluate(_ input: Inputs) -> Result {
        var weightedSum = 0.0
        var totalWeight = 0.0
        var reasons: [String] = []

        func contribute(_ metric: Metric, _ risk: Double?, reason: String) {
            guard let risk, let weight = weights[metric] else { return }
            let clamped = min(max(risk, 0), 1)
            weightedSum += clamped * weight
            totalWeight += weight
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

        let score = totalWeight > 0 ? weightedSum / totalWeight : 0
        let needsBreak = input.stepCount >= minimumStepsBeforeAlert && score >= breakThreshold
        return Result(score: score, reasons: reasons, needsBreak: needsBreak)
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
