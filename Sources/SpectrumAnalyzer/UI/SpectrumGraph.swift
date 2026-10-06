import Foundation

/// One pane's vertical extent in top-down coordinates.
struct GraphPane: Equatable {
    let top: Double
    let height: Double
    var bottom: Double { top + height }
}

/// Frequency-to-x and dB-to-y mapping for the two panes (R11, KTD8). Pure so
/// it is testable without a live view.
enum GraphScale {
    static let dbGridLines: [Float] = [0, -20, -40, -60, -80]
    /// The spectrum pane's share of the height; the difference pane has the rest.
    static let spectrumShare = 0.6
    static let differenceSpanDB: Float = 12
    static let differenceGridLines: [Float] = [6, 0, -6]
    /// The 10 octave bands, which are the EQ2 factory bands.
    static let frequencyGridLines = OctaveBands.centerFrequencies
    static let frequencyGridLabels = OctaveBands.labels

    static func x(forHz hz: Double, width: Double) -> Double {
        let t = log2(hz / SpectrumAnalyzer.minFrequency)
            / log2(SpectrumAnalyzer.maxFrequency / SpectrumAnalyzer.minFrequency)
        return t * width
    }

    static func y(forDB db: Float, height: Double) -> Double {
        let floor = Double(SpectrumAnalyzer.displayFloorDB)
        let clamped = max(Double(db), floor)
        let t = (clamped - floor) / -floor
        return height * (1 - t)
    }

    /// Without a difference pane the spectrum takes the full height.
    static func panes(height: Double, withDifference: Bool = true) -> (spectrum: GraphPane, difference: GraphPane) {
        let spectrum = GraphPane(top: 0, height: withDifference ? height * spectrumShare : height)
        return (spectrum, GraphPane(top: spectrum.bottom, height: height - spectrum.height))
    }

    static func y(forDB db: Float, in pane: GraphPane) -> Double {
        pane.top + y(forDB: db, height: pane.height)
    }

    /// 0 dB at the pane's middle, +/-`differenceSpanDB` at its edges, beyond clamped.
    static func y(forDifferenceDB db: Float, in pane: GraphPane) -> Double {
        let clamped = min(max(db, -differenceSpanDB), differenceSpanDB)
        return pane.top + pane.height * (1 - (Double(clamped) / Double(differenceSpanDB) + 1) / 2)
    }

    /// `a` minus `b` at each display point.
    static func difference(_ a: [SpectrumPoint], minus b: [SpectrumPoint]) -> [SpectrumPoint] {
        zip(a, b).map { SpectrumPoint(frequencyHz: $0.frequencyHz, db: $0.db - $1.db) }
    }

    static func shifted(_ points: [SpectrumPoint], by offsetDB: Float) -> [SpectrumPoint] {
        points.map { SpectrumPoint(frequencyHz: $0.frequencyHz, db: $0.db + offsetDB) }
    }

    /// KTD9: the reference level-matched by `offsetDB`, plus and minus the tone step.
    static func corridor(reference: [SpectrumPoint], offsetDB: Float, stepDB: Float)
        -> (upper: [SpectrumPoint], lower: [SpectrumPoint]) {
        (shifted(reference, by: offsetDB + stepDB), shifted(reference, by: offsetDB - stepDB))
    }

    /// The reference's display powers as a curve against the live guitar.
    static func points(of reference: Reference) -> [SpectrumPoint] {
        zip(SpectrumAnalyzer.displayFrequencies, reference.guitarDisplay).map {
            SpectrumPoint(frequencyHz: $0, db: dB($1, floor: SpectrumAnalyzer.displayFloorDB))
        }
    }
}

/// Everything the graph draws for one tick, pushed to the view through a
/// `LiveSink` (KTD7).
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

    /// Guitar minus the level-matched reference. Without a reference there is
    /// no difference pane: the guitar and the mix share the one spectrum pane.
    var difference: [SpectrumPoint]? {
        guard let guitar, let reference else { return nil }
        return GraphScale.difference(guitar, minus: GraphScale.shifted(reference, by: referenceOffsetDB))
    }
}

/// KTD9: per display point, follows the guitar curve up at once, holds the
/// peak for 1.5 s, then lets it fall 20 dB per second, never below the curve.
struct PeakHold {
    static let holdSeconds = 1.5
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
