import Foundation

/// The meters and the live comparison, which change many times a second. They
/// live apart from `AppModel` so a refresh re-lays out only the views that show
/// them, and each field publishes only when its value changed.
@MainActor
final class LiveLevels: ObservableObject {
    @Published private(set) var guitar: LevelReading?
    @Published private(set) var mix: LevelReading?
    /// Non-nil exactly while a reference is set.
    @Published private(set) var comparison: Comparison?

    /// The unsmoothed readings, which the export reports.
    private(set) var rawGuitar: LevelReading?
    private(set) var rawMix: LevelReading?

    /// Shown readings release slowly; `seconds` is the time since the last call.
    func setMeters(guitar: LevelReading?, mix: LevelReading?, seconds: Double) {
        rawGuitar = guitar
        rawMix = mix
        let shownGuitar = guitar.map { $0.released(from: self.guitar, seconds: seconds) }
        let shownMix = mix.map { $0.released(from: self.mix, seconds: seconds) }
        if shownGuitar != self.guitar { self.guitar = shownGuitar }
        if shownMix != self.mix { self.mix = shownMix }
    }

    func setComparison(_ comparison: Comparison?) {
        if comparison != self.comparison { self.comparison = comparison }
    }
}

/// The three curves, which change 30 times a second. Only the graph observes
/// them, so a frame redraws the canvas and not the whole window.
@MainActor
final class LiveCurves: ObservableObject {
    @Published private(set) var mix: [SpectrumPoint] = []
    @Published private(set) var guitar: [SpectrumPoint]?
    @Published private(set) var difference: [SpectrumPoint]?

    func set(mix: [SpectrumPoint], guitar: [SpectrumPoint]?, difference: [SpectrumPoint]?) {
        self.mix = mix
        self.guitar = guitar
        if difference != self.difference { self.difference = difference }
    }
}
