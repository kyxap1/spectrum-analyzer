import Testing
@testable import SpectrumAnalyzer

private let hop = BandLog.hopFrames

private func point(_ i: Int, _ loudness: Float, active: Bool = true) -> HistoryPoint {
    HistoryPoint(endFrame: (i + 1) * hop, loudnessDB: loudness, isActive: active)
}

@Suite("HistoryStrip")
struct HistoryStripTests {
    @Test("the strip spans 5 minutes, fills from the left and plots hops left to right by end frame")
    func geometry() {
        #expect(HistoryScale.spanFrames == 300 * HistoryRing.sampleRate)
        let short = (0..<10).map { point($0, -20) }
        let xs = short.map { HistoryScale.x(endFrame: $0.endFrame, points: short, width: 600) }
        #expect(xs.first == 0)
        #expect(xs == xs.sorted())
        #expect(abs(xs[1] - 600 * Double(hop) / Double(HistoryScale.spanFrames)) < 0.001)

        let long = (0..<800).map { point($0, -20) }
        #expect(HistoryScale.x(endFrame: long.last!.endFrame, points: long, width: 600) == 600)
        #expect(HistoryScale.x(endFrame: long[199].endFrame, points: long, width: 600) == 0)
    }

    @Test("with a reference the axis spans its loudness +/-12 dB and clamps beyond; the line sits in the middle")
    func referenceAxis() {
        let range = HistoryScale.range(referenceLoudnessDB: -18)
        #expect(range == -30 ... -6)
        #expect(HistoryScale.y(loudnessDB: -18, range: range, height: 40) == 20)
        #expect(HistoryScale.y(loudnessDB: 0, range: range, height: 40) == 0)
        #expect(HistoryScale.y(loudnessDB: -60, range: range, height: 40) == 40)
    }

    @Test("without a reference the axis spans -48 to 0 dB, and no axis changes as hops arrive")
    func fixedAxis() {
        #expect(HistoryScale.range(referenceLoudnessDB: nil) == -48 ... 0)
        #expect(HistoryScale.y(loudnessDB: -24, range: -48 ... 0, height: 40) == 20)
    }

    @Test("Reset empties the strip with the log")
    func resetEmpties() {
        let ring = HistoryRing(capacity: 10 * HistoryRing.sampleRate)
        writeSine(ring, frequency: 440, amplitudeDBFS: -20, seconds: 3)
        let log = BandLog()
        for i in 1...6 { log.advance(ring: ring, to: i * hop) }
        #expect(HistoryScale.points(log: log, thresholdDBFS: -60).count == 6)
        log.reset()
        #expect(HistoryScale.points(log: log, thresholdDBFS: -60).isEmpty)
    }

    @Test("hops below the threshold plot as inactive, and points carry K-weighted loudness")
    func activity() {
        let ring = HistoryRing(capacity: 10 * HistoryRing.sampleRate)
        writeSine(ring, frequency: 440, amplitudeDBFS: -20, seconds: 1.5)
        writeSine(ring, frequency: 440, amplitudeDBFS: -70, seconds: 1.5, startFrame: 3 * hop)
        let log = BandLog()
        for i in 1...6 { log.advance(ring: ring, to: i * hop) }
        let points = HistoryScale.points(log: log, thresholdDBFS: -40)
        #expect(points.map(\.isActive) == [true, true, true, false, false, false])
        #expect(points[1].loudnessDB == Loudness.db(bands: log.hops[1].bands))
    }
}
