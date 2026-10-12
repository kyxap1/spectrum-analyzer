import Darwin
import Testing
@testable import SpectrumAnalyzer

private let rate = HistoryRing.sampleRate

@Suite("OctaveLevels")
struct OctaveLevelsTests {
    @Test("a -6 dBFS 1 kHz sine reaches 65% of its power in the 1k octave after 1 s, settles at its -9 dB mean square and stays out of other octaves")
    func responseAndLevel() {
        let ring = HistoryRing(capacity: 6 * rate)
        writeSine(ring, frequency: 1_000, amplitudeDBFS: -6, seconds: 6)
        var levels = OctaveLevels()
        var bands: [SpectrumPoint] = []
        var head = SpectrumAnalyzer.fftSize
        // Starts from silence, as the live bars do.
        _ = levels.update(ring: HistoryRing(capacity: rate), head: rate, seconds: 0)
        let feed = { (seconds: Double) in
            for _ in 0..<Int(seconds * 30) {
                head += rate / 30
                bands = levels.update(ring: ring, head: head, seconds: 1.0 / 30)
            }
        }
        feed(1)
        let k = OctaveBands.centerFrequencies.firstIndex(of: 1_000)!
        #expect(abs(bands[k].db - (-9.03 + 10 * log10(0.65))) < 0.3)
        feed(4)
        #expect(abs(bands[k].db - -9.03) < 0.2)
        #expect(bands[k - 2].db < bands[k].db - 40)
    }
}
