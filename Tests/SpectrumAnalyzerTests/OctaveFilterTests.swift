import Darwin
import Testing
@testable import SpectrumAnalyzer

private let rate = HistoryRing.sampleRate
private let hop = BandLog.hopFrames
private let octave1k = OctaveBands.centerFrequencies.firstIndex(of: 1000)!

private func logged(_ ring: HistoryRing, hops: Int) -> BandLog {
    let log = BandLog()
    for i in 1...hops { log.advance(ring: ring, to: i * hop) }
    return log
}

@Suite("OctaveFilters")
struct OctaveFilterTests {
    @Test("a 1 kHz sine at -20 dBFS peaks near -20 dBFS overall and in the 1k octave, with 500 and 2k at least 6 dB lower")
    func sineLandsInItsOctave() {
        let ring = HistoryRing(capacity: 10 * rate)
        writeSine(ring, frequency: 1000, amplitudeDBFS: -20, seconds: 3)
        let hop = logged(ring, hops: 4).hops[2]
        #expect(abs(hop.peakDBFS - -20) < 0.1)
        #expect(abs(hop.octavePeakDBFS[octave1k] - -20) < 1)
        #expect(hop.octavePeakDBFS[octave1k - 1] <= -26)
        #expect(hop.octavePeakDBFS[octave1k + 1] <= -26)
    }

    @Test("a steady sine's crest reads about 3 dB; one full-scale click per hop lifts it to 12 dB or more")
    func crestOfSineAndClicks() throws {
        let ring = HistoryRing(capacity: 10 * rate)
        writeSine(ring, frequency: 440, amplitudeDBFS: -20, seconds: 5)
        let steady = try #require(logged(ring, hops: 8).window(threshold: -60, limit: 6).crestDB)
        #expect(abs(steady - 3.01) < 0.2)

        for i in 0..<10 { ring.write(at: i * hop + hop / 2, [32767, 32767]) }
        let clicked = try #require(logged(ring, hops: 8).window(threshold: -60, limit: 6).crestDB)
        #expect(clicked >= 12)
    }

    @Test("two successive hops of a steady 31.5 Hz sine give the same octave peak, at the sine's level: priming leaves no transient")
    func primingSettlesLowBand() {
        let ring = HistoryRing(capacity: 10 * rate)
        writeSine(ring, frequency: 31.5, amplitudeDBFS: -20, seconds: 3)
        let hops = logged(ring, hops: 4).hops
        #expect(abs(hops[1].octavePeakDBFS[0] - hops[2].octavePeakDBFS[0]) < 0.5)
        #expect(abs(hops[2].octavePeakDBFS[0] - -20) < 0.5)
    }

    @Test("a click 0.4 s before the hop end counts in that hop's peak")
    func lateClickCounts() {
        let ring = HistoryRing(capacity: 10 * rate)
        writeSine(ring, frequency: 440, amplitudeDBFS: -40, seconds: 2)
        ring.write(at: 2 * hop - Int(0.4 * Double(rate)), [16384, 16384])
        let hops = logged(ring, hops: 3).hops
        #expect(abs(hops[1].peakDBFS - -6.02) < 0.1)
        #expect(hops[2].peakDBFS < -39)
    }
}
