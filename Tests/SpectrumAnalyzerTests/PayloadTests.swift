import AVFoundation
import Darwin
import Testing
@testable import SpectrumAnalyzer

private let rate = HistoryRing.sampleRate

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

/// Writes stereo white noise (independent seeded per channel is unnecessary
/// here; both channels carry the same sample) at `amplitudeDBFS` peak.
private func writeWhiteNoise(_ ring: HistoryRing, amplitudeDBFS: Double, seconds: Double) {
    let count = Int(seconds * Double(rate))
    let amplitude = pow(10, amplitudeDBFS / 20)
    var rng = SeededGenerator(state: 12_345)
    var frames = [Int16](repeating: 0, count: count * HistoryRing.channels)
    for n in 0..<count {
        let sample = amplitude * Double.random(in: -1...1, using: &rng)
        let quantized = Int16(clamping: Int((sample * 32767).rounded()))
        frames[n * 2] = quantized
        frames[n * 2 + 1] = quantized
    }
    ring.write(at: 0, frames)
}

/// Zero-fills the ring from its current head up to (excluding) `frame`,
/// leaving the head at `frame`, by relying on `HistoryRing.write`'s own
/// gap-fill rather than allocating an explicit silent chunk.
private func extendWithSilence(_ ring: HistoryRing, to frame: Int) {
    ring.write(at: frame - 1, [Int16](repeating: 0, count: HistoryRing.channels))
}

private func dB(_ power: Float) -> Float {
    power > 0 ? 10 * log10(power) : -.infinity
}

@Suite("Payload")
struct PayloadTests {
    @Test("a 100 Hz tone lands in the 100 Hz third-octave band")
    func toneLandsInBand() {
        let ring = HistoryRing(capacity: SpectrumAnalyzer.fftSize * 2)
        writeSine(ring, frequency: 100, amplitudeDBFS: -6, seconds: Double(SpectrumAnalyzer.fftSize) / Double(rate))

        let (power, binHz) = fftPowerSpectrum(ring: ring, endFrame: SpectrumAnalyzer.fftSize, fftSize: SpectrumAnalyzer.fftSize)
        let bands = ThirdOctaveBands.aggregate(power: power, binHz: binHz)
        let peakIndex = bands.indices.max(by: { bands[$0] < bands[$1] })!

        #expect(ThirdOctaveBands.centerFrequencies[peakIndex] == 100)
    }

    @Test("white noise rises about 3 dB per octave across third-octave bands")
    func whiteNoiseRisesWithBandwidth() {
        let ring = HistoryRing(capacity: SpectrumAnalyzer.fftSize * 2)
        writeWhiteNoise(ring, amplitudeDBFS: -20, seconds: Double(SpectrumAnalyzer.fftSize) / Double(rate))

        let (power, binHz) = fftPowerSpectrum(ring: ring, endFrame: SpectrumAnalyzer.fftSize, fftSize: SpectrumAnalyzer.fftSize)
        let bands = ThirdOctaveBands.aggregate(power: power, binHz: binHz)

        // Bands three apart are one octave apart (1/3-octave spacing); a flat
        // spectral density's power per band doubles across an octave, a ~3 dB rise.
        let index1kHz = ThirdOctaveBands.centerFrequencies.firstIndex(of: 1000)!
        let index2kHz = ThirdOctaveBands.centerFrequencies.firstIndex(of: 2000)!
        let rise = dB(bands[index2kHz]) - dB(bands[index1kHz])

        #expect(abs(rise - 3) < 2)
    }

    @Test("covers AE6: 4 minutes of history reports 240 s analyzed and 31 band rows for mix, guitar and difference")
    func fourMinutesReportsAE6() {
        let seconds = 240.0
        let mixRing = HistoryRing(capacity: Int(seconds * Double(rate)))
        let guitarRing = HistoryRing(capacity: Int(seconds * Double(rate)))
        writeSine(mixRing, frequency: 200, amplitudeDBFS: -6, seconds: seconds)
        writeSine(guitarRing, frequency: 800, amplitudeDBFS: -6, seconds: seconds)

        let mix = Payload.analyze(ring: mixRing, thresholdDBFS: -70)
        let guitar = Payload.analyze(ring: guitarRing, thresholdDBFS: -70)
        #expect(abs(mix.analyzedSeconds - seconds) < 0.001)
        #expect(abs(guitar.analyzedSeconds - seconds) < 0.001)

        let text = Payload.render(mix: mix, guitar: guitar, rig: RigText(markdown: "rig text", cachedAt: nil))
        let rows = text.components(separatedBy: "\n").filter { $0.contains("\t") && !$0.hasPrefix("Band") }
        #expect(rows.count == ThirdOctaveBands.centerFrequencies.count)
        #expect(text.contains("Mix analyzed: 240 s"))
        #expect(text.contains("Guitar analyzed: 240 s"))
        #expect(text.contains("Guitar - Mix"))
    }

    @Test("2 minutes of guitar then 2 minutes of silence matches 2 minutes alone, reporting 120 s")
    func silenceTailIsExcluded() {
        let toneSeconds = 120.0
        let totalSeconds = 240.0
        let ringWithTail = HistoryRing(capacity: Int(totalSeconds * Double(rate)))
        writeSine(ringWithTail, frequency: 300, amplitudeDBFS: -6, seconds: toneSeconds)
        extendWithSilence(ringWithTail, to: Int(totalSeconds * Double(rate)))

        let ringToneOnly = HistoryRing(capacity: Int(toneSeconds * Double(rate)))
        writeSine(ringToneOnly, frequency: 300, amplitudeDBFS: -6, seconds: toneSeconds)

        let withTail = Payload.analyze(ring: ringWithTail, thresholdDBFS: -70)
        let toneOnly = Payload.analyze(ring: ringToneOnly, thresholdDBFS: -70)

        #expect(abs(withTail.analyzedSeconds - 120) < 0.001)
        #expect(withTail.analyzedSeconds == toneOnly.analyzedSeconds)
        #expect(withTail.power == toneOnly.power)
    }

    @Test("with no guitar audio, the payload says the guitar was not captured and carries the mix only")
    func noGuitarAudio() {
        let mixRing = HistoryRing(capacity: 4 * rate)
        writeSine(mixRing, frequency: 200, amplitudeDBFS: -6, seconds: 4)
        let guitarRing = HistoryRing(capacity: 4 * rate) // nothing written: empty kept range

        let mix = Payload.analyze(ring: mixRing, thresholdDBFS: -70)
        let guitar = Payload.analyze(ring: guitarRing, thresholdDBFS: -70)
        #expect(guitar.analyzedSeconds == 0)

        let text = Payload.render(mix: mix, guitar: guitar, rig: RigText(markdown: "rig", cachedAt: nil))
        #expect(text.contains("Guitar was not captured."))
        #expect(!text.contains("Guitar - Mix"))
    }

    @Test("when the rig fetch fails, the cached copy is used and its date appears in the payload")
    func fetchFailureFallsBackToCache() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = StubRigCache(stored: ("cached rig text", date))
        let result = await RigSource.fetch(url: URL(string: "https://example.invalid/raw")!,
                                           fetcher: FailingRigFetcher(),
                                           cache: cache)

        guard case .success(let rig) = result else {
            Issue.record("expected a successful fallback to the cache")
            return
        }
        #expect(rig.markdown == "cached rig text")
        #expect(rig.cachedAt == date)

        let payload = Payload.render(mix: SourceBands(power: [Float](repeating: 0, count: 31), analyzedSeconds: 4),
                                     guitar: nil,
                                     rig: rig)
        #expect(payload.contains("cached copy"))
    }

    @Test("with no cache, a failed fetch is refused with a reason")
    func fetchFailureWithNoCacheIsRefused() async {
        let result = await RigSource.fetch(url: URL(string: "https://example.invalid/raw")!,
                                           fetcher: FailingRigFetcher(),
                                           cache: StubRigCache(stored: nil))

        guard case .failure(let error) = result, case .unavailable(let reason) = error else {
            Issue.record("expected a refusal")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("the payload contains no sample data and stays under 30 KB including the rig")
    func payloadStaysUnder30KB() {
        let mix = SourceBands(power: [Float](repeating: 0.001, count: ThirdOctaveBands.centerFrequencies.count), analyzedSeconds: 240)
        let guitar = SourceBands(power: [Float](repeating: 0.002, count: ThirdOctaveBands.centerFrequencies.count), analyzedSeconds: 240)
        let rigText = String(repeating: "a", count: 21_700) // ~ the real rig's size on 2026-09-14

        let payload = Payload.render(mix: mix, guitar: guitar, rig: RigText(markdown: rigText, cachedAt: nil))

        #expect(payload.utf8.count < 30_000)
    }
}

private struct FailingRigFetcher: RigFetching {
    func fetchText(from url: URL, timeoutInterval: TimeInterval) async throws -> String {
        throw RigFetchError.unavailable("network down")
    }
}

private final class StubRigCache: RigCaching {
    private let stored: (text: String, date: Date)?

    init(stored: (text: String, date: Date)?) {
        self.stored = stored
    }

    func read() -> (text: String, date: Date)? { stored }
    func write(_ text: String) {}
}

@Suite("RigPedals")
struct RigPedalsTests {
    private let rig = """
    ## Pedalboard

    | Jack | Run |
    | ---- | --- |
    | A    | Rocksmith adapter |

    ### Pedals

    | Pedal | Designation | Jacks |
    | ----- | ----------- | ----- |
    | TC Electronic Polytune 3 | tuner | IN, OUT |
    | BOSS GE-7 | equalizer, 7 bands | INPUT, OUTPUT |
    | Donner ABY Box | source switch | A, B |
    | Mooer Cab X2 | IR cab sim, stereo | INPUT L |
    | NUX NMP-2 | dual footswitch | jack A |

    ## Cables
    | Cable | Run |
    | ----- | --- |
    | Long  | Guitar |
    """

    @Test("only the Pedals table's tone pedals are listed, without tuner and switches")
    func namesSkipTunerAndSwitches() {
        #expect(RigPedals.names(in: rig) == ["BOSS GE-7", "Mooer Cab X2"])
    }

    @Test("the state lists engaged pedals in table order, notes, and lands after the rig")
    func stateFollowsTheRig() throws {
        let state = try #require(RigPedals.state(pedals: ["BOSS GE-7", "Mooer Cab X2"],
                                                 engaged: ["Mooer Cab X2", "BOSS GE-7", "Gone Pedal"],
                                                 notes: " Cab X2 LC 80 Hz \n"))
        #expect(state.contains("Pedals engaged now: BOSS GE-7, Mooer Cab X2."))
        #expect(state.hasSuffix("Player notes: Cab X2 LC 80 Hz"))
        #expect(RigPedals.state(pedals: ["BOSS GE-7"], engaged: [], notes: "").map { $0.contains("All pedals") } == true)
        #expect(RigPedals.state(pedals: [], engaged: [], notes: "  ") == nil)

        let payload = Payload.render(mix: SourceBands(power: [Float](repeating: 0, count: 31), analyzedSeconds: 4),
                                     guitar: nil, rig: RigText(markdown: "rig text", cachedAt: nil), rigState: state)
        #expect(payload.hasSuffix("rig text\n\n" + state))
    }

    @Test("the previous round's bands and answer follow the rig state, and are absent without one")
    func previousRoundFollowsRigState() {
        let bands = SourceBands(power: [Float](repeating: 0.001, count: 31), analyzedSeconds: 4)
        let rig = RigText(markdown: "rig text", cachedAt: nil)
        let table = Payload.bandTable(mix: bands, guitar: bands)
        let previous = AdviceRound(date: Date(timeIntervalSince1970: 1_700_000_000), bands: table,
                                   answer: "**Current settings**\n- amp bass: 1 o'clock")

        let payload = Payload.render(mix: bands, guitar: bands, rig: rig, rigState: "state", previous: previous)
        #expect(payload.contains("rig text\n\nstate\n\nPrevious round ("))
        #expect(payload.contains(table + "\n\nPrevious recommendation:\n" + previous.answer))
        #expect(payload.hasSuffix(previous.answer))
        #expect(!Payload.render(mix: bands, guitar: bands, rig: rig).contains("Previous round"))
    }
}

@Suite("StartingPositions")
struct StartingPositionsTests {
    private let rig = RigText(markdown: "rig text", cachedAt: nil)
    private let bands = SourceBands(power: [Float](repeating: 0.001, count: 31), analyzedSeconds: 4)

    @Test("covers AE6: shipped defaults name the current rig and none of the removed pedals")
    func shippedDefaultsMatchRig() {
        let text = Payload.render(mix: bands, guitar: bands, rig: rig,
                                  instruction: AdviceSettings.defaultPrompt,
                                  startingPositions: AdviceSettings.defaultStartingPositions)
        for removed in ["GE-7", "Matcha", "Bad Horse"] { #expect(!text.contains(removed)) }
        for present in ["EQ2", "Timmy", "Fortin"] { #expect(text.contains(present)) }
    }

    @Test("covers AE6: the shipped prompt asks for whole-dB EQ2 changes")
    func promptAsksWholeDB() {
        #expect(AdviceSettings.defaultPrompt.contains("EQ2"))
        #expect(AdviceSettings.defaultPrompt.contains("whole dB"))
        #expect(!AdviceSettings.defaultPrompt.contains("2.5 dB"))
    }

    @Test("the shipped prompt carries no positions list")
    func promptHasNoPositions() {
        let prompt = AdviceSettings.defaultPrompt
        #expect(!prompt.contains("Default positions"))
        for name in ["Wampler", "Timmy", "Fortin", "Terraform", "Collider", "Plethora", "Spark", "Ravager"] {
            #expect(!prompt.contains(name))
        }
    }

    @Test("edited starting positions land under their heading after the rig state and before the previous round")
    func editedPositionsAreRendered() {
        let previous = AdviceRound(date: Date(timeIntervalSince1970: 1_700_000_000), bands: "table", answer: "answer")
        let text = Payload.render(mix: bands, guitar: bands, rig: rig, rigState: "state",
                                  startingPositions: "- **Amp** -- gain 3 o'clock.", previous: previous)
        #expect(text.contains("state\n\nStarting positions:\n- **Amp** -- gain 3 o'clock.\n\nPrevious round ("))
    }

    @Test("an emptied starting-positions field adds no section")
    func emptyPositionsAreOmitted() {
        let text = Payload.render(mix: bands, guitar: bands, rig: rig, startingPositions: " \n")
        #expect(!text.contains("Starting positions:"))
    }

    @Test("storing the default removes the key, a different value is stored and read back")
    func storeRoundTrip() {
        let key = "test.startingPositions.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        AdviceSettings.store("custom", key, default: "default")
        #expect(UserDefaults.standard.string(forKey: key) == "custom")
        #expect(AdviceSettings.load(key, default: "default") == "custom")
        AdviceSettings.store("default", key, default: "default")
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }
}

@Suite("PayloadThreshold")
struct PayloadThresholdTests {
    @Test("a threshold above the tone's RMS analyzes nothing, one below analyzes the tone's duration")
    func thresholdGatesAnalysis() {
        let ring = HistoryRing(capacity: 6 * rate)
        writeSine(ring, frequency: 500, amplitudeDBFS: -20, seconds: 4)
        #expect(Payload.analyze(ring: ring, thresholdDBFS: -10).analyzedSeconds == 0)
        #expect(abs(Payload.analyze(ring: ring, thresholdDBFS: -30).analyzedSeconds - 4) < 0.001)
    }
}
