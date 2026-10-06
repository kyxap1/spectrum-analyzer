import Testing
@testable import SpectrumAnalyzer

private let rate = HistoryRing.sampleRate

@Suite("LevelMeter")
struct LevelMeterTests {
    @Test("a full-scale sine reads about -3 dBFS RMS and 0 dBFS peak")
    func fullScaleSine() {
        let ring = HistoryRing(capacity: 4 * rate)
        writeSine(ring, frequency: 440, amplitudeDBFS: 0, seconds: 2)
        let reading = LevelMeter.read(ring: ring, head: ring.head)
        #expect(abs(reading.rmsDBFS - -3) < 0.2)
        #expect(abs(reading.peakDBFS) < 0.1)
    }

    @Test("a burst 0.8 s before the head shows in peak but not in the 300 ms RMS")
    func burstOutsideRMSWindow() {
        let ring = HistoryRing(capacity: 4 * rate)
        writeSine(ring, frequency: 440, amplitudeDBFS: -6, seconds: 0.1, startFrame: rate * 11 / 10)
        ring.write(at: 2 * rate - 1, [0, 0])
        let reading = LevelMeter.read(ring: ring, head: 2 * rate)
        #expect(reading.rmsDBFS == -.infinity)
        #expect(abs(reading.peakDBFS - -6) < 0.2)
    }

    @Test("silence reads minus infinity and renders as a minus sign and infinity")
    func silence() {
        let ring = HistoryRing(capacity: 4 * rate)
        ring.write(at: rate - 1, [0, 0])
        let reading = LevelMeter.read(ring: ring, head: rate)
        #expect(reading.rmsDBFS == -.infinity)
        #expect(reading.peakDBFS == -.infinity)
        #expect(LevelMeter.format(reading.rmsDBFS) == "\u{2212}\u{221E}")
        #expect(LevelMeter.format(-18.24) == "-18.2")
    }

    @Test("a head less than 1 s into history reads without crashing")
    func shortHistory() {
        let ring = HistoryRing(capacity: 4 * rate)
        writeSine(ring, frequency: 440, amplitudeDBFS: -6, seconds: 0.2)
        let reading = LevelMeter.read(ring: ring, head: rate / 5)
        #expect(reading.peakDBFS.isFinite)
        #expect(LevelMeter.read(ring: ring, head: 0).peakDBFS == -.infinity)
    }
}

@Suite("LevelReading")
struct LevelReadingTests {
    @Test("the peak is held while RMS falls at a limited rate")
    func releases() {
        let loud = LevelReading(rmsDBFS: -10, peakDBFS: -3)
        let quiet = LevelReading(rmsDBFS: -40, peakDBFS: -30)
        #expect(loud.shown(after: quiet, seconds: 0.1) == loud)
        let fallen = quiet.shown(after: loud, seconds: 0.5)
        #expect(abs(fallen.rmsDBFS - -22) < 0.001)
        #expect(fallen.peakDBFS == -3)
    }

    @Test("silence settles to minus infinity and the first reading is shown as is")
    func silenceAndFirst() {
        let silent = LevelReading(rmsDBFS: -.infinity, peakDBFS: -.infinity)
        #expect(silent.shown(after: nil, seconds: 0.1) == silent)
        let nearFloor = LevelReading(rmsDBFS: -119, peakDBFS: -119)
        let settled = silent.shown(after: nearFloor, seconds: 1)
        #expect(settled.rmsDBFS == -.infinity)
        #expect(settled.peakDBFS == -119)
    }
}
