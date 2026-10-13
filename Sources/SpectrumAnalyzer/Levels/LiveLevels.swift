import Foundation

/// The meters and the live comparison, which change many times a second. They
/// live apart from `AppModel` so a refresh re-lays out only the views that show
/// them, and each field publishes only when its value changed. The meter
/// readings themselves never publish: they reach the meter views through
/// sinks (KTD7).
@MainActor
final class LiveLevels: ObservableObject {
    let guitarMeter = LiveSink<MeterDisplay?>(nil)
    let mixMeter = LiveSink<MeterDisplay?>(nil)
    private var guitarBallistics = MeterBallistics()
    private var mixBallistics = MeterBallistics()
    /// Tune: each input's figures over its window, with the reference's; nil in real-time.
    @Published private(set) var table: LevelsTable?
    /// Whether each input has a reading; changes rarely, so it is published.
    @Published private(set) var hasGuitar = false
    @Published private(set) var hasMix = false
    /// Non-nil exactly while a reference is set.
    @Published private(set) var comparison: Comparison?
    @Published private(set) var verdict: Verdict?
    /// Changes only when a shown string does, unlike the verdict (KTD7).
    @Published private(set) var verdictText = VerdictText(nil)
    let history = LiveSink(HistoryFrame())
    @Published private(set) var clipping: ClipLatch.Inputs = []
    private var clipLatch = ClipLatch()

    /// The unsmoothed readings, which the export reports.
    private(set) var rawGuitar: LevelReading?
    private(set) var rawMix: LevelReading?

    /// Feeds the meters the frames since the last call, nil while an input
    /// is not captured; `seconds` is the time since the last call.
    func showMeters(guitar: [Int16]?, mix: [Int16], seconds: Double) {
        if let guitar {
            guitarMeter.send(guitarBallistics.update(interleaved: guitar, seconds: seconds))
        } else {
            guitarBallistics = MeterBallistics()
            guitarMeter.send(nil)
        }
        mixMeter.send(mixBallistics.update(interleaved: mix, seconds: seconds))
    }

    /// `seconds` is the time since the last call.
    func setMeters(guitar: LevelReading?, mix: LevelReading?, seconds: Double) {
        rawGuitar = guitar
        rawMix = mix
        if hasGuitar != (guitar != nil) { hasGuitar = guitar != nil }
        if hasMix != (mix != nil) { hasMix = mix != nil }
        let clipping = clipLatch.update(guitarPeakDBFS: guitar?.peakDBFS, mixPeakDBFS: mix?.peakDBFS, seconds: seconds)
        if clipping != self.clipping { self.clipping = clipping }
    }

    func setTable(_ table: LevelsTable?) {
        if table != self.table { self.table = table }
    }

    func setComparison(_ comparison: Comparison?) {
        if comparison != self.comparison { self.comparison = comparison }
    }

    func setVerdict(_ verdict: Verdict?, isPaused: Bool, referenceTooShort: Bool = false) {
        if verdict != self.verdict { self.verdict = verdict }
        let text = VerdictText(verdict, isPaused: isPaused, referenceTooShort: referenceTooShort)
        if text != verdictText { verdictText = text }
    }
}

/// One row of the levels table; a nil figure reads as a dash.
struct LevelsRow: Equatable {
    var loudnessDB: Float?
    var averagePeakDBFS: Float?
    var crestDB: Float?
    var playing: String

    init(loudnessDB: Float?, averagePeakDBFS: Float?, crestDB: Float?, playing: String = "") {
        self.loudnessDB = loudnessDB
        self.averagePeakDBFS = averagePeakDBFS
        self.crestDB = crestDB
        self.playing = playing
    }

    init(_ window: ActiveWindow, windowSeconds: Int) {
        self.init(loudnessDB: window.hops.isEmpty ? nil : Loudness.db(bands: window.bandPower),
                  averagePeakDBFS: window.averagePeakDBFS, crestDB: window.crestDB,
                  playing: String(format: "%.1f / %d s", window.activeSeconds, windowSeconds))
    }
}

/// Tune: the guitar and the mix over the window, the reference, and the
/// guitar minus the reference, which is what the verdict reads.
struct LevelsTable: Equatable {
    /// Nil while the guitar is not captured.
    var guitar: LevelsRow?
    var reference: LevelsRow?
    var difference: LevelsRow?
    var mix: LevelsRow

    init(guitar: ActiveWindow?, mix: ActiveWindow, reference: Reference?, comparison: Comparison?, windowSeconds: Int) {
        self.guitar = guitar.map { LevelsRow($0, windowSeconds: windowSeconds) }
        self.reference = reference.map {
            LevelsRow(loudnessDB: Loudness.db(bands: $0.guitarBands), averagePeakDBFS: $0.guitarAveragePeakDBFS,
                      crestDB: $0.guitarCrestDB, playing: String(format: "%.0f s", $0.activeSeconds))
        }
        difference = comparison.map {
            LevelsRow(loudnessDB: $0.loudnessDifferenceDB, averagePeakDBFS: $0.averagePeakDifferenceDB, crestDB: $0.crestDifferenceDB)
        }
        self.mix = LevelsRow(mix, windowSeconds: windowSeconds)
    }
}

/// Latches a clip warning per input while a peak at or above -1 dBFS is
/// under 3 s old (KTD10).
struct ClipLatch {
    struct Inputs: OptionSet, Equatable {
        let rawValue: Int
        static let guitar = Inputs(rawValue: 1)
        static let mix = Inputs(rawValue: 2)
    }

    static let thresholdDBFS: Float = -1
    static let holdSeconds = 3.0

    private var guitarAge = Double.infinity
    private var mixAge = Double.infinity
    private(set) var clipping: Inputs = []

    /// `seconds` is the time since the last call.
    mutating func update(guitarPeakDBFS: Float?, mixPeakDBFS: Float?, seconds: Double) -> Inputs {
        guitarAge = (guitarPeakDBFS ?? -.infinity) >= Self.thresholdDBFS ? 0 : guitarAge + seconds
        mixAge = (mixPeakDBFS ?? -.infinity) >= Self.thresholdDBFS ? 0 : mixAge + seconds
        clipping = []
        // Ages are sums of tick lengths, so 3 s must not read as 2.9999.
        let hold = Self.holdSeconds - 1e-6
        if guitarAge < hold { clipping.insert(.guitar) }
        if mixAge < hold { clipping.insert(.mix) }
        return clipping
    }

    static func warning(_ inputs: Inputs) -> String? {
        let names = [(Inputs.guitar, "guitar"), (.mix, "mix")].filter { inputs.contains($0.0) }.map(\.1)
        return names.isEmpty ? nil : "Clipping: " + names.joined(separator: ", ")
    }
}

/// Hands a fast-changing value to AppKit views without SwiftUI state: any
/// published change re-lays out the whole window, which at 10-30 Hz costs more
/// CPU than the drawing, while a pushed value only redraws the views (KTD7).
/// A view attaches once and is dropped when it goes away.
@MainActor
final class LiveSink<Value> {
    private(set) var value: Value
    private var targets: [(Value) -> Bool] = []

    init(_ value: Value) { self.value = value }

    /// Shows the current value at once, then every sent one.
    func attach<Target: AnyObject>(_ target: Target, _ show: @escaping (Target, Value) -> Void) {
        show(target, value)
        targets.append { [weak target] value in
            guard let target else { return false }
            show(target, value)
            return true
        }
    }

    func send(_ value: Value) {
        self.value = value
        targets.removeAll { !$0(value) }
    }
}
