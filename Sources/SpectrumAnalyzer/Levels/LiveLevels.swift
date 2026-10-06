import Foundation

/// The meters and the live comparison, which change many times a second. They
/// live apart from `AppModel` so a refresh re-lays out only the views that show
/// them, and each field publishes only when its value changed. The meter
/// readings themselves never publish: they reach the meter views through
/// sinks (KTD7).
@MainActor
final class LiveLevels: ObservableObject {
    let guitarMeter = LiveSink<LevelReading?>(nil)
    let mixMeter = LiveSink<LevelReading?>(nil)
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

    var guitar: LevelReading? { guitarMeter.value }
    var mix: LevelReading? { mixMeter.value }

    /// The unsmoothed readings, which the export reports.
    private(set) var rawGuitar: LevelReading?
    private(set) var rawMix: LevelReading?

    /// Shown RMS releases slowly; `seconds` is the time since the last call.
    func setMeters(guitar: LevelReading?, mix: LevelReading?, seconds: Double) {
        rawGuitar = guitar
        rawMix = mix
        guitarMeter.send(guitar.map { $0.shown(after: self.guitar, seconds: seconds) })
        mixMeter.send(mix.map { $0.shown(after: self.mix, seconds: seconds) })
        if hasGuitar != (guitar != nil) { hasGuitar = guitar != nil }
        if hasMix != (mix != nil) { hasMix = mix != nil }
        let clipping = clipLatch.update(guitarPeakDBFS: guitar?.peakDBFS, mixPeakDBFS: mix?.peakDBFS, seconds: seconds)
        if clipping != self.clipping { self.clipping = clipping }
    }

    func setComparison(_ comparison: Comparison?) {
        if comparison != self.comparison { self.comparison = comparison }
    }

    func setVerdict(_ verdict: Verdict?, isPaused: Bool) {
        if verdict != self.verdict { self.verdict = verdict }
        let text = VerdictText(verdict, isPaused: isPaused)
        if text != verdictText { verdictText = text }
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
