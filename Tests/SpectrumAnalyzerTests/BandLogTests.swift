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
