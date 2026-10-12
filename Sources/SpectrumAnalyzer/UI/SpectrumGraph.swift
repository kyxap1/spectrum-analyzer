import Foundation

/// Frequency-to-x and dB-to-y mapping for the spectrum graph and the
/// difference pane (R11, R13, KTD8). Pure so it is testable without a live view.
enum GraphScale {
    /// KTD8: Friture's default spectrum range, fixed so a height reads the same at any moment.
    static let spectrumRange: ClosedRange<Float> = -100 ... -20
    static let spectrumGridStepDB: Float = 10
    static let differenceRange: ClosedRange<Float> = -12 ... 12
    static let differenceGridStepDB: Float = 6
    /// The 10 octave bands, which are the EQ2 factory bands.
    static let frequencyGridLines = OctaveBands.centerFrequencies
    static let frequencyGridLabels = OctaveBands.labels

    static func x(forHz hz: Double, width: Double) -> Double {
        let t = log2(hz / SpectrumAnalyzer.minFrequency)
            / log2(SpectrumAnalyzer.maxFrequency / SpectrumAnalyzer.minFrequency)
        return t * width
    }

    /// Top-down y within `height`, clamped to the range's edges so a curve
    /// never breaks; nil only for a point with no value, which draws as a gap.
    static func y(forDB db: Float, range: ClosedRange<Float>, height: Double) -> Double? {
        guard db.isFinite else { return nil }
        let t = Double((range.upperBound - db) / (range.upperBound - range.lowerBound))
        return height * min(1, max(0, t))
    }

    /// The multiples of `step` inside `range`, top first.
    static func gridLines(range: ClosedRange<Float>, step: Float) -> [Float] {
        stride(from: (range.upperBound / step).rounded(.down) * step, through: range.lowerBound, by: -step).map { $0 }
    }

    /// The indices of the labels at `ys` (top first) that fit `labelHeight`
    /// apart: both ends always, each one between only clear of its neighbours.
    static func fittingLabels(_ ys: [Double], labelHeight: Double) -> [Int] {
        guard let last = ys.indices.last, last > 0 else { return Array(ys.indices) }
        var chosen = [0]
        for i in 1..<last where ys[i] - ys[chosen[chosen.count - 1]] >= labelHeight && ys[last] - ys[i] >= labelHeight {
            chosen.append(i)
        }
        return chosen + [last]
    }

    static func shifted(_ points: [SpectrumPoint], by offsetDB: Float) -> [SpectrumPoint] {
        points.map { SpectrumPoint(frequencyHz: $0.frequencyHz, db: $0.db + offsetDB) }
    }

    /// `a` minus `b` per point where both are at or above `bottomDB`, else
    /// -infinity (KTD8): a difference against a curve outside the range is noise.
    static func difference(_ a: [SpectrumPoint], minus b: [SpectrumPoint], bottomDB: Float) -> [SpectrumPoint] {
        zip(a, b).map {
            SpectrumPoint(frequencyHz: $0.frequencyHz,
                          db: $0.db >= bottomDB && $1.db >= bottomDB ? $0.db - $1.db : -.infinity)
        }
    }

    /// The reference's display powers as a curve against the live guitar.
    static func points(of reference: Reference) -> [SpectrumPoint] {
        points(displayPower: reference.guitarDisplay)
    }

    /// Display powers, as the band log keeps them, as a curve.
    static func points(displayPower: [Float]) -> [SpectrumPoint] {
        zip(SpectrumAnalyzer.displayFrequencies, displayPower).map {
            SpectrumPoint(frequencyHz: $0, db: SpectrumAnalyzer.pointDB($1))
        }
    }
}

/// Everything the graph and the difference pane draw for one tick, pushed to
/// the views through a `LiveSink` (KTD7).
struct GraphFrame {
    var guitar: [SpectrumPoint]?
    var mix: [SpectrumPoint] = []
    /// Nil while the peak-hold toggle is off.
    var peakHold: [SpectrumPoint]?
    var reference: [SpectrumPoint]?
    /// Live loudness minus the reference's, which level-matches the corridor
    /// and the difference curve.
    var referenceOffsetDB: Float = 0
    var toneStepDB: Float = 1
    /// Held tone counts for the tone row (R8); nil until a full window.
    var toneSteps: [Int]?
    /// Tune: the window the curves average; nil in real-time.
    var windowSeconds: Int?
    /// The reference level-matched to the live guitar.
    var drawnReference: [SpectrumPoint]? {
        reference.map { GraphScale.shifted($0, by: referenceOffsetDB) }
    }

    /// Guitar minus the level-matched reference, where both lie inside the
    /// spectrum range (R13). Nil without a reference.
    var difference: [SpectrumPoint]? {
        guard let guitar, let reference = drawnReference else { return nil }
        return GraphScale.difference(guitar, minus: reference, bottomDB: GraphScale.spectrumRange.lowerBound)
    }
}

/// KTD9: per display point, follows the guitar curve up at once, holds the
/// peak for 3 s, then lets it fall 20 dB per second, never below the curve.
struct PeakHold {
    static let holdSeconds = 3.0
    static let fallDBPerSecond: Float = 20

    private(set) var points: [SpectrumPoint] = []
    /// Seconds since each point last rose to a new peak.
    private var ages: [Double] = []

    mutating func update(with curve: [SpectrumPoint], elapsedSeconds: Double) {
        guard points.count == curve.count else {
            points = curve
            ages = Array(repeating: 0, count: curve.count)
            return
        }
        for i in curve.indices {
            let previousAge = ages[i]
            ages[i] += elapsedSeconds
            let falling = ages[i] - max(previousAge, Self.holdSeconds)
            var held = points[i].db - (falling > 0 ? Self.fallDBPerSecond * Float(falling) : 0)
            if curve[i].db >= held {
                held = curve[i].db
                ages[i] = 0
            }
            points[i] = SpectrumPoint(frequencyHz: curve[i].frequencyHz, db: held)
        }
    }

    mutating func reset() {
        points = []
        ages = []
    }
}
