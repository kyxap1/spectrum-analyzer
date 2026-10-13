import Darwin
import Testing
@testable import SpectrumAnalyzer

private let bandCount = ThirdOctaveBands.centerFrequencies.count
private let shaped = (0..<bandCount).map { Float(1 + $0 % 4) }

private func gate(_ differences: [Float], stepDB: Float) -> [Int] {
    var gate = StepGate()
    return differences.map { gate.update(differenceDB: $0, stepDB: stepDB) }
}

private func logHop(_ sequence: Int, gainDB: Float = 0, peak: Float = -6, rms: Float = -20) -> LogHop {
    LogHop(sequence: sequence, endFrame: (sequence + 1) * BandLog.hopFrames, rmsDBFS: rms,
           bands: shaped.map { $0 * pow(10, gainDB / 10) },
           display: [Float](repeating: 1, count: SpectrumAnalyzer.displayPointCount), peakDBFS: peak)
}

private let reference = Reference.make(guitar: BandLog.average((0..<20).map { logHop($0) }),
                                       mix: BandLog.average([]), windowSeconds: 10)!

/// A comparison of the newest 20 of `hops`, as the app makes it.
private func comparison(_ hops: [LogHop], against reference: Reference = reference) -> Comparison {
    Comparison.make(reference: reference, window: BandLog.average(Array(hops.suffix(20))), windowHops: 20)
}

@Suite("Verdict")
struct VerdictTests {
    @Test("covers AE1: at a 2 dB step, 0.6, 2.3, 1.4 and 0.9 dB read zero, +1, still +1, then zero")
    func unityGate() {
        #expect(gate([0.6, 2.3, 1.4, 0.9], stepDB: 2) == [0, 1, 1, 0])
    }

    @Test("covers AE2: at a 1 dB step, 1.2, 0.6 and 0.4 dB read +1, still +1, then zero")
    func toneGate() {
        #expect(gate([1.2, 0.6, 0.4], stepDB: 1) == [1, 1, 0])
    }

    @Test("a held +1 survives 2.9, 3.1, 2.9 and 3.4 dB, moves to +2 at 3.5, holds at 2.6 and returns to +1 at 2.4")
    func holdsBetweenCounts() {
        #expect(gate([2.3, 2.9, 3.1, 2.9, 3.4, 3.5, 2.6, 2.4], stepDB: 2) == [1, 1, 1, 1, 1, 2, 2, 1])
    }

    @Test("a held count leaves to zero only below half a step")
    func leavesBelowHalfStep() {
        #expect(gate([2.2, 1.1, 0.9], stepDB: 2) == [1, 1, 0])
    }

    @Test("a held +1 moves straight to -1 when the difference reaches -1 step")
    func flipsSign() {
        #expect(gate([2.2, -2], stepDB: 2) == [1, -1])
    }

    @Test("covers AE7: at N = 10 s and a 2 dB step, +6 dB reads louder from the 4th new hop and zero again from the 19th back; -6 dB reads quieter from the 10th and zero from the 15th")
    func windowLatency() {
        func firstHop(from start: [LogHop], adding gainDB: Float, until done: (Int) -> Bool) -> Int? {
            var tracker = VerdictTracker()
            var hops = start
            _ = tracker.update(comparison(hops))
            for n in 1...30 {
                hops.append(logHop(hops.count, gainDB: gainDB))
                if let steps = tracker.update(comparison(hops))?.unitySteps, done(steps) { return n }
            }
            return nil
        }
        let unity = (0..<20).map { logHop($0) }
        let louder = (0..<20).map { logHop($0, gainDB: 6) }
        let quieter = (0..<20).map { logHop($0, gainDB: -6) }
        #expect(firstHop(from: unity, adding: 6) { $0 > 0 } == 4)
        #expect(firstHop(from: louder, adding: 0) { $0 == 0 } == 19)
        #expect(firstHop(from: unity, adding: -6) { $0 < 0 } == 10)
        #expect(firstHop(from: quieter, adding: 0) { $0 == 0 } == 15)
    }

    @Test("until the window holds N active seconds every figure is unknown, whatever the difference")
    func unknownWhileFilling() throws {
        var tracker = VerdictTracker()
        let verdictUpdate = tracker.update(comparison((0..<8).map { logHop($0, gainDB: 6) }))
        let verdict = try #require(verdictUpdate)
        #expect(verdict.unitySteps == nil)
        #expect(verdict.toneSteps == nil)
        #expect(verdict.crestSteps == nil)
        #expect(verdict.activeSeconds == 4)
        #expect(verdict.windowSeconds == 10)
    }

    @Test("updating twice with the same last hop changes nothing; a new hop advances the gate")
    func advancesPerHop() {
        var tracker = VerdictTracker()
        var hops = (0..<20).map { logHop($0) }
        #expect(tracker.update(comparison(hops))?.unitySteps == 0)
        // The same last hop with a different difference: the gate does not move.
        var same = hops
        same[19] = logHop(19, gainDB: 20)
        #expect(tracker.update(comparison(same))?.unitySteps == 0)
        hops.append(logHop(20, gainDB: 20))
        #expect(tracker.update(comparison(hops))?.unitySteps ?? 0 > 0)
    }

    @Test("replaying the same hop series after a clear gives the same figures")
    func replayIsDeterministic() {
        let gains: [Float] = [0, 1, 2.5, 3, 2, 4, 1, 0.5, -2, -3, 0, 2.2]
        var hops = (0..<20).map { logHop($0) }
        for gain in gains { hops.append(logHop(hops.count, gainDB: gain)) }
        func run(_ tracker: inout VerdictTracker) -> [Verdict?] {
            (20...hops.count).map { tracker.update(comparison(Array(hops.prefix($0)))) }
        }
        var tracker = VerdictTracker()
        let first = run(&tracker)
        tracker.clear()
        #expect(run(&tracker) == first)
    }

    @Test("changing a step size or clearing drops the held counts")
    func settingsClear() {
        var tracker = VerdictTracker()
        let hops = (0..<20).map { logHop($0, gainDB: 2.2) }
        #expect(tracker.update(comparison(hops))?.unitySteps == 1)
        tracker.unityStepDB = 4
        #expect(tracker.update(comparison(hops))?.unitySteps == 0)
        tracker.unityStepDB = 2
        #expect(tracker.update(comparison(hops))?.unitySteps == 1)
        tracker.clear()
        #expect(tracker.verdict == nil)
    }

    @Test("the tone count is the number of non-zero columns; a level change alone leaves every column at zero")
    func toneCount() throws {
        var tracker = VerdictTracker()
        let louderUpdate = tracker.update(comparison((0..<20).map { logHop($0, gainDB: 3) }))
        let louder = try #require(louderUpdate)
        #expect(louder.toneSteps == [Int](repeating: 0, count: 10))
        #expect(louder.toneCount == 0)

        var tilted = shaped
        for i in OctaveBands.thirdOctaveIndices[2] { tilted[i] *= 4 }
        for i in OctaveBands.thirdOctaveIndices[7] { tilted[i] *= 4 }
        let hops = (0..<20).map {
            LogHop(sequence: $0, endFrame: ($0 + 1) * BandLog.hopFrames, rmsDBFS: -20, bands: tilted,
                   display: [Float](repeating: 1, count: SpectrumAnalyzer.displayPointCount), peakDBFS: -6)
        }
        tracker.clear()
        let shiftedUpdate = tracker.update(comparison(hops))
        let shifted = try #require(shiftedUpdate)
        #expect(shifted.toneCount == shifted.toneSteps?.filter { $0 != 0 }.count)
        #expect(shifted.toneSteps?[2] != 0)
        #expect(shifted.toneSteps?[7] != 0)
    }

    @Test("covers AE3: with no reference the verdict is absent")
    func noReference() {
        var tracker = VerdictTracker()
        #expect(tracker.update(nil) == nil)
    }

    @Test("the crest figure shows at a change of 2 dB or more, holds until it falls below 1 dB, and is unknown without crest data")
    func crestFigure() throws {
        var tracker = VerdictTracker()
        func crest(_ peak: Float, _ sequence: Int) -> Int? {
            tracker.update(comparison((sequence..<sequence + 20).map { logHop($0, peak: peak) }))?.crestSteps
        }
        #expect(crest(-7.5, 0) == 0)
        #expect(crest(-8, 1) == -1)
        #expect(crest(-7.1, 2) == -1)
        #expect(crest(-6.5, 3) == 0)

        var noCrest = reference
        noCrest.guitarAveragePeakDBFS = nil
        noCrest.guitarCrestDB = nil
        var fresh = VerdictTracker()
        let verdictUpdate = fresh.update(comparison((0..<20).map { logHop($0, peak: -12) }, against: noCrest))
        let verdict = try #require(verdictUpdate)
        #expect(verdict.crestSteps == nil)
        #expect(verdict.unitySteps == 0)
    }

    @Test("each figure carries its spread, the sample standard deviation of its per-hop differences")
    func spreads() throws {
        var tracker = VerdictTracker()
        let hops = (0..<20).map { logHop($0, gainDB: $0 % 2 == 0 ? 1 : -1) }
        let verdictUpdate = tracker.update(comparison(hops))
        let verdict = try #require(verdictUpdate)
        let spread = try #require(verdict.unitySpreadDB)
        #expect(abs(spread - 1.026) < 0.01)
        #expect(verdict.toneSpreadDB?.count == 10)
    }
}
