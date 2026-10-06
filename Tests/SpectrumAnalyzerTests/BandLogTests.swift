import Darwin
import Testing
@testable import SpectrumAnalyzer

private let rate = HistoryRing.sampleRate
private let hop = BandLog.hopFrames

/// A sine whose RMS is `rmsDBFS`, since a sine's RMS sits 3.01 dB under its peak.
private func writeTone(_ ring: HistoryRing, rmsDBFS: Double, seconds: Double, startFrame: Int = 0, frequency: Double = 1000) {
    writeSine(ring, frequency: frequency, amplitudeDBFS: rmsDBFS + 3.0103, seconds: seconds, startFrame: startFrame)
}

private func advanceHop(by hops: Int, log: BandLog, ring: HistoryRing, from: Int) {
    for i in 1...hops { log.advance(ring: ring, to: from + i * hop) }
}

@Suite("BandLog")
struct BandLogTests {
    @Test("12 s of tone, 20 s of silence: the 10 s window holds only tone hops")
    func windowSkipsRest() {
        let ring = HistoryRing(capacity: 40 * rate)
        writeTone(ring, rmsDBFS: -20, seconds: 12)
        ring.write(at: 32 * rate - 1, [0, 0])
        let log = BandLog()
        advanceHop(by: 64, log: log, ring: ring, from: 0)

        let window = log.window(threshold: -60, limit: 20)
        #expect(window.activeSeconds == 10)
        #expect(window.hops.allSatisfy { $0.endFrame <= 12 * rate })
        #expect(abs(window.levelDBFS - -20) < 0.5)
        let peak = window.bandPower.indices.max { window.bandPower[$0] < window.bandPower[$1] }!
        #expect(ThirdOctaveBands.centerFrequencies[peak] == 1000)
    }

    @Test("covers AE2: hiss at -62 dBFS learns -52, and 30 s more of it adds no active hops")
    func learnsNoiseFloor() {
        let ring = HistoryRing(capacity: 60 * rate)
        writeTone(ring, rmsDBFS: -62, seconds: 10)
        let log = BandLog()
        advanceHop(by: 20, log: log, ring: ring, from: 0)

        guard case .learned(let threshold) = log.learnNoise(isLive: true) else {
            Issue.record("expected a learned threshold")
            return
        }
        #expect(abs(threshold - -52) < 0.5)

        writeTone(ring, rmsDBFS: -62, seconds: 30, startFrame: 10 * rate)
        let before = log.activeCount(threshold: threshold)
        advanceHop(by: 60, log: log, ring: ring, from: 20 * hop)
        #expect(log.activeCount(threshold: threshold) == before)
        #expect(before == 0)
    }

    @Test("Learn noise over digital silence leaves the threshold alone")
    func silenceKeepsThreshold() {
        let ring = HistoryRing(capacity: 20 * rate)
        ring.write(at: 10 * rate - 1, [0, 0])
        let log = BandLog()
        advanceHop(by: 20, log: log, ring: ring, from: 0)
        #expect(log.learnNoise(isLive: true) == .silent)
    }

    @Test("Learn noise refuses while not Live, with fewer than 6 hops, and after a break")
    func learnRefusals() {
        let ring = HistoryRing(capacity: 20 * rate)
        writeTone(ring, rmsDBFS: -62, seconds: 10)
        let log = BandLog()
        advanceHop(by: 5, log: log, ring: ring, from: 0)
        guard case .refused = log.learnNoise(isLive: true) else { Issue.record("5 hops"); return }

        advanceHop(by: 5, log: log, ring: ring, from: 5 * hop)
        guard case .refused = log.learnNoise(isLive: false) else { Issue.record("paused"); return }
        guard case .learned = log.learnNoise(isLive: true) else { Issue.record("10 hops"); return }

        log.markBreak()
        guard case .refused = log.learnNoise(isLive: true) else { Issue.record("after break"); return }
    }

    @Test("lowering the threshold below the hiss makes skipped hops count without re-appending")
    func thresholdAppliesAtRead() {
        let ring = HistoryRing(capacity: 20 * rate)
        writeTone(ring, rmsDBFS: -62, seconds: 10)
        let log = BandLog()
        advanceHop(by: 20, log: log, ring: ring, from: 0)
        #expect(log.window(threshold: -60, limit: 20).activeSeconds == 0)
        #expect(log.window(threshold: -70, limit: 20).activeSeconds == 10)
    }

    @Test("beyond 1,200 hops the oldest drop and the window returns the newest")
    func capacityDropsOldest() {
        let ring = HistoryRing(capacity: 4 * rate)
        let log = BandLog()
        for i in 0..<1_300 {
            writeSine(ring, frequency: 440, amplitudeDBFS: -20, seconds: 0.5, startFrame: i * hop)
            log.advance(ring: ring, to: (i + 1) * hop)
        }
        #expect(log.hops.count == BandLog.capacity)
        #expect(log.hops.last?.endFrame == 1_300 * hop)
        #expect(log.window(threshold: -60, limit: 4).hops.last?.endFrame == 1_300 * hop)
    }

    @Test("Reset empties the log, and sequence numbers keep rising")
    func resetEmpties() {
        let ring = HistoryRing(capacity: 10 * rate)
        writeTone(ring, rmsDBFS: -20, seconds: 4)
        let log = BandLog()
        advanceHop(by: 8, log: log, ring: ring, from: 0)
        let sequence = log.nextSequence
        log.reset()
        #expect(log.hops.isEmpty)
        #expect(log.window(threshold: -60, limit: 20).activeSeconds == 0)
        #expect(log.nextSequence == sequence)
    }

    @Test("a head that has not moved appends nothing")
    func idleHeadAppendsNothing() {
        let ring = HistoryRing(capacity: 10 * rate)
        writeTone(ring, rmsDBFS: -20, seconds: 2)
        let log = BandLog()
        log.advance(ring: ring, to: 2 * rate)
        let count = log.hops.count
        log.advance(ring: ring, to: 2 * rate)
        #expect(log.hops.count == count)
    }

    @Test("a head minutes past the log appends at most two hops")
    func farHeadJumps() {
        let ring = HistoryRing(capacity: 10 * rate)
        let log = BandLog()
        log.advance(ring: ring, to: 300 * rate)
        #expect(log.hops.count <= 2)
        #expect(log.hops.last?.endFrame == 300 * rate)
    }
}

private func peakHop(_ sequence: Int, peak: Float, rms: Float = -20,
                     octavePeaks: [Float] = [], octaveMeanSquares: [Float] = []) -> LogHop {
    LogHop(sequence: sequence, endFrame: (sequence + 1) * hop, rmsDBFS: rms,
           bands: [Float](repeating: 0, count: ThirdOctaveBands.centerFrequencies.count),
           display: [Float](repeating: 0, count: SpectrumAnalyzer.displayPointCount),
           peakDBFS: peak, octavePeakDBFS: octavePeaks, octaveMeanSquare: octaveMeanSquares)
}

@Suite("BandLog peaks and crest")
struct BandLogCrestTests {
    @Test("three active hops peaking at -10, -10 and -4 dBFS average -8 dBFS")
    func averagePeakInDB() {
        let window = BandLog.average([peakHop(0, peak: -10), peakHop(1, peak: -10), peakHop(2, peak: -4)])
        #expect(window.averagePeakDBFS == -8)
    }

    @Test("crest is average peak minus full-hop RMS, and each octave's crest uses that octave's own figures")
    func crestFromOwnFigures() throws {
        let octaves = OctaveBands.centerFrequencies.count
        let msA = [Float](repeating: 0.001, count: octaves)
        let msB = [Float](repeating: 0.003, count: octaves)
        let peaksA = (0..<octaves).map { Float(-20 - $0) }
        let peaksB = (0..<octaves).map { Float(-10 - $0) }
        let window = BandLog.average([
            peakHop(0, peak: -6, rms: -20, octavePeaks: peaksA, octaveMeanSquares: msA),
            peakHop(1, peak: -2, rms: -20, octavePeaks: peaksB, octaveMeanSquares: msB),
        ])
        #expect(abs(try #require(window.crestDB) - (-4 - window.levelDBFS)) < 0.001)
        let crest = try #require(window.octaveCrestDB)
        let averagePeak = try #require(window.octaveAveragePeakDBFS)
        for i in 0..<octaves {
            #expect(abs(averagePeak[i] - Float(-15 - i)) < 0.001)
            #expect(abs(crest[i] - (Float(-15 - i) - 10 * log10(Float(0.002)))) < 0.01)
        }
    }

    @Test("a hop loud for 330 ms and quiet for 170 ms reads RMS and crest over the full hop, not the last 8192 frames")
    func crestCoversFullHop() throws {
        let ring = HistoryRing(capacity: 10 * rate)
        let loudFrames = Int(0.33 * Double(rate))
        writeSine(ring, frequency: 1000, amplitudeDBFS: -10, seconds: 0.33, startFrame: hop)
        writeSine(ring, frequency: 1000, amplitudeDBFS: -40, seconds: 0.17, startFrame: hop + loudFrames)
        let log = BandLog()
        log.advance(ring: ring, to: hop)
        log.advance(ring: ring, to: 2 * hop)
        let measured = log.hops[1]

        let loud = Float(pow(10, -10.0 / 10) / 2)
        let quiet = Float(pow(10, -40.0 / 10) / 2)
        let fullHop = 10 * log10((0.33 * loud + 0.17 * quiet) / 0.5)
        #expect(abs(measured.rmsDBFS - fullHop) < 0.2)
        let crest = try #require(BandLog.average([measured]).crestDB)
        #expect(abs(crest - (-10 - fullHop)) < 0.2)
    }

    @Test("a 200 Hz tone in a hop's first 330 ms, then silence, still shows in that hop's band powers and RMS")
    func earlyToneIsMeasured() {
        let ring = HistoryRing(capacity: 10 * rate)
        writeSine(ring, frequency: 200, amplitudeDBFS: -20, seconds: 0.33, startFrame: hop)
        ring.write(at: 3 * hop, [0, 0])
        let log = BandLog()
        log.advance(ring: ring, to: hop)
        log.advance(ring: ring, to: 2 * hop)
        let measured = log.hops[1]
        let loudest = measured.bands.indices.max { measured.bands[$0] < measured.bands[$1] }!
        #expect(ThirdOctaveBands.centerFrequencies[loudest] == 200)
        #expect(measured.rmsDBFS > -30)
    }

    @Test("a steady sine's hop band powers match a single 8192-frame FFT within 0.2 dB")
    func averagedBandsMatchSingleFFT() {
        let ring = HistoryRing(capacity: 10 * rate)
        writeSine(ring, frequency: 1000, amplitudeDBFS: -20, seconds: 3)
        let log = BandLog()
        for i in 1...4 { log.advance(ring: ring, to: i * hop) }
        let measured = log.hops[2]
        let (power, binHz) = fftPowerSpectrum(ring: ring, endFrame: measured.endFrame, fftSize: SpectrumAnalyzer.fftSize)
        let single = ThirdOctaveBands.aggregate(power: power, binHz: binHz)
        let band = ThirdOctaveBands.centerFrequencies.firstIndex(of: 1000)!
        #expect(abs(10 * log10(measured.bands[band] / single[band])) < 0.2)
    }

    @Test("hops below the threshold stay out of average peak and crest")
    func quietHopsExcluded() throws {
        let ring = HistoryRing(capacity: 20 * rate)
        writeSine(ring, frequency: 440, amplitudeDBFS: -10, seconds: 3)
        writeSine(ring, frequency: 440, amplitudeDBFS: -70, seconds: 3, startFrame: 3 * rate)
        let log = BandLog()
        for i in 1...12 { log.advance(ring: ring, to: i * hop) }
        let window = log.window(threshold: -40, limit: 20)
        #expect(abs(try #require(window.averagePeakDBFS) - -10) < 0.1)
        #expect(abs(try #require(window.crestDB) - 3.01) < 0.2)
    }

    @Test("a window with no active hop reports unknown average peak and crest, not zero")
    func emptyWindowUnknown() {
        let window = BandLog.average([])
        #expect(window.averagePeakDBFS == nil)
        #expect(window.crestDB == nil)
        #expect(window.octaveAveragePeakDBFS == nil)
        #expect(window.octaveCrestDB == nil)
    }
}
