import Testing
@testable import SpectrumAnalyzer

private let hop = BandLog.hopFrames

private func point(_ i: Int, _ loudness: Float) -> HistoryPoint {
    HistoryPoint(endFrame: (i + 1) * hop, loudnessDB: loudness)
}

@Suite("HistoryStrip")
struct HistoryStripTests {
    @Test("the strip spans 10 minutes, as much as the band log holds, with the newest hop at the right edge")
    func geometry() {
        #expect(HistoryScale.spanFrames == 600 * HistoryRing.sampleRate)
        #expect(HistoryScale.spanFrames == BandLog.capacity * hop)
        let short = (0..<10).map { point($0, -20) }
        let newest = short.last!.endFrame
        let xs = short.map { HistoryScale.x(endFrame: $0.endFrame, newestFrame: newest, width: 600) }
        #expect(xs.last == 600)
        #expect(xs == xs.sorted())
        #expect(abs(xs[9] - xs[8] - 600 * Double(hop) / Double(HistoryScale.spanFrames)) < 0.001)
        let spanAgo = newest - HistoryScale.spanFrames
        #expect(HistoryScale.x(endFrame: spanAgo, newestFrame: newest, width: 600) == 0)
    }

    @Test("Friture's fixed axis: -70 to -20 dB with a line every 10 dB, clamped beyond")
    func fixedAxis() {
        #expect(HistoryScale.gridLines == [-20, -30, -40, -50, -60, -70])
        #expect(HistoryScale.y(loudnessDB: -45, height: 40) == 20)
        #expect(HistoryScale.y(loudnessDB: 0, height: 40) == 0)
        #expect(HistoryScale.y(loudnessDB: -.infinity, height: 40) == 40)
    }

    @Test("Reset empties the strip with the log")
    func resetEmpties() {
        let ring = HistoryRing(capacity: 10 * HistoryRing.sampleRate)
        writeSine(ring, frequency: 440, amplitudeDBFS: -20, seconds: 3)
        let log = BandLog()
        for i in 1...6 { log.advance(ring: ring, to: i * hop) }
        #expect(HistoryScale.points(log: log).count == 6)
        log.reset()
        #expect(HistoryScale.points(log: log).isEmpty)
    }

    @Test("every hop is plotted, quiet ones too, smoothed in power over 20 s from the first hop's loudness")
    func smoothing() {
        let ring = HistoryRing(capacity: 10 * HistoryRing.sampleRate)
        writeSine(ring, frequency: 440, amplitudeDBFS: -20, seconds: 1.5)
        writeSine(ring, frequency: 440, amplitudeDBFS: -70, seconds: 1.5, startFrame: 3 * hop)
        let log = BandLog()
        for i in 1...6 { log.advance(ring: ring, to: i * hop) }
        let points = HistoryScale.points(log: log)
        #expect(points.count == 6)
        #expect(points[0].loudnessDB == Loudness.db(bands: log.hops[0].bands))
        // A 20 s response keeps 1.5 s of near-silence within 1 dB of the tone.
        #expect(points[5].loudnessDB < points[2].loudnessDB)
        #expect(points[2].loudnessDB - points[5].loudnessDB < 1)
    }

    @Test("Tune fills 5 minutes from the left without moving, then scrolls")
    func tuneGeometry() {
        let early = (0..<10).map { point($0, -20) }
        let xs = early.map { HistoryScale.tuneX(endFrame: $0.endFrame, points: early, width: 600) }
        #expect(xs.first == 600 * Double(hop) / Double(HistoryScale.tuneSpanFrames))
        let more = (0..<20).map { point($0, -20) }
        #expect(HistoryScale.tuneX(endFrame: more[3].endFrame, points: more, width: 600) == xs[3])
        let full = (0..<700).map { point($0, -20) }
        #expect(HistoryScale.tuneX(endFrame: full.last!.endFrame, points: full, width: 600) == 600)
    }

    @Test("Tune's axis spans the reference ±12 dB, or real-time's range without one")
    func tuneRange() {
        #expect(HistoryScale.tuneRange(referenceLoudnessDB: -30) == -42 ... -18)
        #expect(HistoryScale.tuneRange(referenceLoudnessDB: nil) == -70 ... -20)
    }

    @Test("Tune groups playing into takes: a pause over 2 s splits them, a stray note under 2 s is dropped, each at its power-mean loudness")
    func tuneTakes() {
        // 6 hops at -20/-10 with a 1 s gap, a 3 s pause, 4 hops, a 3 s pause, one stray hop.
        let first: [(Bool, Float)] = [(true, -20), (true, -20), (true, -20), (false, -60), (false, -60), (true, -10), (true, -10), (true, -10)]
        let pause: [(Bool, Float)] = Array(repeating: (false, -60), count: 6)
        let second: [(Bool, Float)] = Array(repeating: (true, -30), count: 4)
        let pattern = first + pause + second + pause + [(true, -5)]
        let points = pattern.enumerated().map { HistoryPoint(endFrame: ($0.offset + 1) * hop, loudnessDB: $0.element.1, isActive: $0.element.0) }
        let takes = HistoryScale.takes(points)
        #expect(takes.count == 2)
        #expect(takes[0].startFrame == 0)
        #expect(takes[0].endFrame == 8 * hop)
        // Power mean of 0.01 and 0.1.
        #expect(abs(takes[0].loudnessDB - -12.596) < 0.01)
        #expect(takes[1].startFrame == 14 * hop)
        #expect(abs(takes[1].loudnessDB + 30) < 0.001)
    }
}
