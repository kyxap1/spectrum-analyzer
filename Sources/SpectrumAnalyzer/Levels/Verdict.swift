import Foundation

/// KTD5: turns a raw difference into a held step count. Entering a non-zero
/// count needs a full step, leaving to zero needs less than half a step, and a
/// held count moves to the nearest one only 0.75 steps away from it, which
/// stops flicker at 1.5 steps.
struct StepGate: Equatable {
    private(set) var count = 0

    mutating func update(differenceDB: Float, stepDB: Float) -> Int {
        let steps = differenceDB / stepDB
        if count == 0 {
            if abs(steps) >= 1 { count = Int(steps.rounded()) }
        } else if abs(steps) < 0.5 {
            count = 0
        } else if abs(steps - Float(count)) >= 0.75 {
            count = Int(steps.rounded())
        }
        return count
    }
}

/// What the screen and the export show (KTD6). Figures are held step counts,
/// nil while the window fills or when the reference lacks the data.
struct Verdict: Equatable {
    let unitySteps: Int?
    let toneSteps: [Int]?
    let crestSteps: Int?
    let unityStepDB: Float
    let toneStepDB: Float
    let activeSeconds: Double
    let windowSeconds: Double
    /// The measured loudness difference, shown small under the unity figure.
    let loudnessDifferenceDB: Float?
    /// Sample standard deviations of the per-hop differences, for the export only (KTD4).
    let unitySpreadDB: Float?
    let toneSpreadDB: [Float]?
    let crestSpreadDB: Float?

    var toneCount: Int? { toneSteps?.filter { $0 != 0 }.count }
}

/// KTD6: holds the step gates and nothing else, so the same hop series always
/// gives the same verdict. Advances once per new log hop, not per UI tick.
struct VerdictTracker {
    static let crestStepDB: Float = 2

    var unityStepDB: Float = 2 { didSet { if unityStepDB != oldValue { clear() } } }
    var toneStepDB: Float = 1 { didSet { if toneStepDB != oldValue { clear() } } }
    private(set) var verdict: Verdict?
    private var unity = StepGate()
    private var tones = [StepGate](repeating: StepGate(), count: OctaveBands.centerFrequencies.count)
    private var crest = StepGate()
    private var lastHopSequence: Int?

    /// For Reset, Set reference, a loaded snapshot and a step change.
    mutating func clear() {
        unity = StepGate()
        tones = tones.map { _ in StepGate() }
        crest = StepGate()
        lastHopSequence = nil
        verdict = nil
    }

    /// Nil `comparison` means no reference, and so no verdict.
    mutating func update(_ comparison: Comparison?) -> Verdict? {
        guard let comparison else {
            verdict = nil
            return nil
        }
        if verdict != nil, comparison.lastHopSequence == lastHopSequence { return verdict }
        lastHopSequence = comparison.lastHopSequence

        let ready = !comparison.partial
        let unitySteps = ready ? comparison.loudnessDifferenceDB.map { unity.update(differenceDB: $0, stepDB: unityStepDB) } : nil
        let toneSteps = ready ? comparison.octaveDifferencesDB.map { differences in
            differences.indices.map { tones[$0].update(differenceDB: differences[$0], stepDB: toneStepDB) }
        } : nil
        let crestSteps = ready ? comparison.crestDifferenceDB.map { crest.update(differenceDB: $0, stepDB: Self.crestStepDB) } : nil
        let hopTones = comparison.hopToneDifferencesDB
        verdict = Verdict(
            unitySteps: unitySteps,
            toneSteps: toneSteps,
            crestSteps: crestSteps,
            unityStepDB: unityStepDB,
            toneStepDB: toneStepDB,
            activeSeconds: comparison.activeSeconds,
            windowSeconds: Double(comparison.windowHops) * Payload.hopSeconds,
            loudnessDifferenceDB: comparison.loudnessDifferenceDB,
            unitySpreadDB: Self.spread(comparison.hopLoudnessDifferencesDB),
            toneSpreadDB: hopTones.count > 1 ? hopTones[0].indices.map { i in Self.spread(hopTones.map { $0[i] })! } : nil,
            crestSpreadDB: Self.spread(comparison.hopCrestDifferencesDB))
        return verdict
    }

    /// Sample standard deviation; nil below two values.
    static func spread(_ values: [Float]) -> Float? {
        guard values.count > 1 else { return nil }
        let mean = values.reduce(0, +) / Float(values.count)
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count - 1)).squareRoot()
    }
}
