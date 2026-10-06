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
    }

    func setComparison(_ comparison: Comparison?) {
        if comparison != self.comparison { self.comparison = comparison }
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
