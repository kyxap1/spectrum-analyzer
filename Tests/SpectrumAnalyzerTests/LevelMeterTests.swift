import Darwin
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

/// Feeds `seconds` of a ring to the ballistics in ticks of 1/30 s from `start`.
private func feed(_ ballistics: inout MeterBallistics, _ ring: HistoryRing, from start: Int, seconds: Double) -> MeterDisplay? {
    let block = rate / 30
    var shown: MeterDisplay?
    for tick in 0..<Int(seconds * 30) {
        shown = ballistics.update(interleaved: ring.read(from: start + tick * block, count: block), seconds: 1.0 / 30)
    }
    return shown
}

@Suite("MeterBallistics")
struct MeterBallisticsTests {
    @Test("RMS reaches 65% of a step's power after 300 ms and settles on the true RMS")
    func rmsResponse() {
        let ring = HistoryRing(capacity: 4 * rate)
        writeSine(ring, frequency: 440, amplitudeDBFS: -6, seconds: 3)
        var ballistics = MeterBallistics()
        let early = feed(&ballistics, ring, from: 0, seconds: 0.3)!
        #expect(abs(early.rmsDBFS - (-9.03 + 10 * log10(0.65))) < 0.3)
        let settled = feed(&ballistics, ring, from: rate * 3 / 10, seconds: 2.4)!
        #expect(abs(settled.rmsDBFS - -9.03) < 0.1)
        #expect(abs(settled.peakDBFS - -6) < 0.1)
    }

    @Test("after a tone stops the peak falls at once and the marker holds 3 s, then drops to the fading RMS")
    func peakAndHold() {
        let ring = HistoryRing(capacity: 6 * rate)
        writeSine(ring, frequency: 440, amplitudeDBFS: 0, seconds: 1)
        ring.write(at: 6 * rate - 1, [0, 0])
        var ballistics = MeterBallistics()
        _ = feed(&ballistics, ring, from: 0, seconds: 1)
        let afterStop = feed(&ballistics, ring, from: rate, seconds: 0.2)!
        #expect(afterStop.peakDBFS < -25)
        #expect(abs(afterStop.heldPeakIEC - 1) < 0.01)
        let held = feed(&ballistics, ring, from: rate * 12 / 10, seconds: 1.7)!
        #expect(abs(held.heldPeakIEC - 1) < 0.01)
        let dropped = feed(&ballistics, ring, from: rate * 39 / 10, seconds: 2)!
        #expect(dropped.heldPeakIEC < 0.5)
    }

    @Test("a tone followed by long silence reads minus infinity, never a huge negative number")
    func silenceFloor() {
        let ring = HistoryRing(capacity: 40 * rate)
        writeSine(ring, frequency: 440, amplitudeDBFS: 0, seconds: 1)
        ring.write(at: 40 * rate - 1, [0, 0])
        var ballistics = MeterBallistics()
        let shown = feed(&ballistics, ring, from: 0, seconds: 39)!
        #expect(shown.rmsDBFS == -.infinity)
        #expect(shown.peakDBFS == -.infinity)
    }

    @Test("the IEC 60268-18 scale matches Friture's breakpoints")
    func iecScale() {
        #expect(MeterBallistics.iec(0) == 1)
        #expect(MeterBallistics.iec(-20) == 0.5)
        #expect(MeterBallistics.iec(-60) == 0.025)
        #expect(MeterBallistics.iec(-80) == 0)
        #expect(MeterBallistics.iec(-.infinity) == 0)
        #expect(MeterBallistics.iec(3) == 1)
    }
}
