import Foundation

/// A walking signal tracked from walk to walk.
enum TrendMetric: String, CaseIterable, Identifiable {
    case risk, speed, cadence, steadiness, asymmetry, doubleSupport, heartRate, alerts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .risk: "Break risk"
        case .speed: "Walking speed"
        case .cadence: "Cadence"
        case .steadiness: "Steadiness"
        case .asymmetry: "Asymmetry"
        case .doubleSupport: "Double support"
        case .heartRate: "Heart rate"
        case .alerts: "Alerts per walk"
        }
    }

    var icon: String {
        switch self {
        case .risk: "exclamationmark.triangle.fill"
        case .speed: "speedometer"
        case .cadence: "metronome.fill"
        case .steadiness: "waveform.path.ecg"
        case .asymmetry: "arrow.left.and.right"
        case .doubleSupport: "figure.stand"
        case .heartRate: "heart.fill"
        case .alerts: "bell.fill"
        }
    }

    /// True when a rising value is the unsafe direction.
    var higherIsWorse: Bool {
        switch self {
        case .risk, .asymmetry, .doubleSupport, .heartRate, .alerts: true
        case .speed, .cadence, .steadiness: false
        }
    }

    /// Smallest walk-to-walk change worth flagging, in the metric's own units.
    var significantChange: Double {
        switch self {
        case .risk: 0.05
        case .speed: 0.10           // 0.1 m/s is a clinically meaningful change in gait speed
        case .cadence: 5
        case .steadiness: 0.05
        case .asymmetry: 0.02
        case .doubleSupport: 0.03
        case .heartRate: 5
        case .alerts: 1
        }
    }

    func value(in walk: WalkRecord) -> Double? {
        switch self {
        case .risk: walk.risk
        case .speed: walk.speed
        case .cadence: walk.cadence
        case .steadiness: walk.steadiness
        case .asymmetry: walk.asymmetry
        case .doubleSupport: walk.doubleSupport
        case .heartRate: walk.heartRate
        case .alerts: Double(walk.alerts)
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .speed: String(format: "%.2f m/s", value)
        case .cadence: "\(Int(value.rounded())) steps/min"
        case .heartRate: "\(Int(value.rounded())) bpm"
        case .alerts: String(format: "%.1f", value)
        case .risk, .steadiness, .asymmetry, .doubleSupport: "\(Int((value * 100).rounded()))%"
        }
    }

    /// The size of a change, e.g. "0.14 m/s". Percentage metrics change in points ("7 pts"),
    /// so a drop from 80% to 72% isn't mistaken for "down 8%" of the old value.
    func formatChange(_ value: Double) -> String {
        switch self {
        case .risk, .steadiness, .asymmetry, .doubleSupport: "\(Int((value * 100).rounded())) pts"
        default: format(value)
        }
    }
}

/// How one metric has moved: the average of the recent walks against the earlier ones.
struct Trend: Identifiable {
    enum Direction { case worse, better, steady }

    let metric: TrendMetric
    let recent: Double
    let earlier: Double

    var id: String { metric.id }
    var change: Double { recent - earlier }

    /// How many "meaningful changes" the metric has moved in the unsafe direction (negative when improving).
    var severity: Double { (metric.higherIsWorse ? change : -change) / metric.significantChange }

    var direction: Direction {
        if severity >= 1 { return .worse }
        if severity <= -1 { return .better }
        return .steady
    }
}

enum WalkTrends {
    /// How many of the latest walks the history screen looks at.
    static let window = 8
    /// A trend needs at least this many walks to mean anything.
    static let minimumWalks = 3

    /// Splits the latest walks into an earlier and a recent half and compares their averages.
    /// Metrics with too few readings (e.g. heart rate without an Apple Watch) are skipped,
    /// and the result is ordered with the most worrying trend first.
    static func trends(for walks: [WalkRecord]) -> [Trend] {
        let latest = walks.suffix(window)
        return TrendMetric.allCases.compactMap { metric in
            let values = latest.compactMap(metric.value(in:))
            guard values.count >= minimumWalks else { return nil }
            let recent = values.suffix(values.count / 2)
            let earlier = values.dropLast(recent.count)
            return Trend(metric: metric, recent: average(recent), earlier: average(earlier))
        }
        .sorted { $0.severity > $1.severity }
    }

    private static func average(_ values: ArraySlice<Double>) -> Double {
        values.reduce(0, +) / Double(values.count)
    }
}
