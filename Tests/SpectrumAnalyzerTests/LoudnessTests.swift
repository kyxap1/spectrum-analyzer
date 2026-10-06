import Darwin
import Testing
@testable import SpectrumAnalyzer

private let rate = HistoryRing.sampleRate
private let hop = BandLog.hopFrames
private let bandCount = ThirdOctaveBands.centerFrequencies.count

private func band(_ hz: Double) -> Int { ThirdOctaveBands.centerFrequencies.firstIndex(of: hz)! }

private func sineBands(_ frequency: Double) -> [Float] {
    let ring = HistoryRing(capacity: 10 * rate)
    writeSine(ring, frequency: frequency, amplitudeDBFS: -20, seconds: 3)
    let log = BandLog()
    for i in 1...4 { log.advance(ring: ring, to: i * hop) }
    return log.hops[2].bands
}

@Suite("Loudness")
struct LoudnessTests {
    @Test("the weights follow BS.1770 K-weighting: about +0.7 dB at 1 kHz and below 0 dB at 31.5 Hz")
    func kWeighting() {
        #expect(abs(10 * log10(Loudness.weights[band(1000)]) - 0.69) < 0.1)
        #expect(10 * log10(Loudness.weights[band(31.5)]) < 0)
    }

    @Test("equal-level sines at 100 Hz and 3 kHz read at least 3 dB apart, the 3 kHz one louder")
    func trebleReadsLouder() {
        #expect(Loudness.db(bands: sineBands(3000)) - Loudness.db(bands: sineBands(100)) >= 3)
    }

    @Test("a window's loudness equals the power mean of its hops' loudness within 0.1 dB")
    func windowIsPowerMean() {
        let ring = HistoryRing(capacity: 20 * rate)
        writeSine(ring, frequency: 200, amplitudeDBFS: -10, seconds: 2)
        writeSine(ring, frequency: 2000, amplitudeDBFS: -30, seconds: 2, startFrame: 2 * rate)
        writeSine(ring, frequency: 500, amplitudeDBFS: -20, seconds: 2, startFrame: 4 * rate)
        let log = BandLog()
        for i in 1...12 { log.advance(ring: ring, to: i * hop) }
        let window = log.window(threshold: -60, limit: 12)
        let mean = window.hops.reduce(Float(0)) { $0 + pow(10, Loudness.db(bands: $1.bands) / 10) } / Float(window.hops.count)
        #expect(abs(Loudness.db(bands: window.bandPower) - 10 * log10(mean)) < 0.1)
    }

    @Test("cutting 125 Hz by 6 dB and lifting 2 kHz by 6 dB at equal flat RMS reads louder, while flat RMS stays put")
    func toneShiftChangesLoudness() {
        let lift = Float(pow(10, 0.6))
        var reference = [Float](repeating: 0, count: bandCount)
        reference[band(125)] = lift
        reference[band(2000)] = 1
        var live = reference
        live[band(125)] = lift / lift
        live[band(2000)] = lift
        let flat = 10 * log10(live.reduce(0, +) / reference.reduce(0, +))
        #expect(abs(flat) < 0.1)
        #expect(Loudness.db(bands: live) - Loudness.db(bands: reference) > 1)
    }
}
