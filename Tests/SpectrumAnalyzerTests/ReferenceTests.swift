import Testing
@testable import SpectrumAnalyzer

private let rate = HistoryRing.sampleRate
private let hop = BandLog.hopFrames
private let bandCount = ThirdOctaveBands.centerFrequencies.count

private func steps(_ log: BandLog, _ ring: HistoryRing, from: Int, hops: Int) {
    for i in 1...hops { log.advance(ring: ring, to: from + i * hop) }
}

private func hop(sequence: Int, level: Float = -20, bands: [Float]) -> LogHop {
    LogHop(sequence: sequence, endFrame: (sequence + 1) * hop, rmsDBFS: level, bands: bands,
           display: [Float](repeating: 1, count: SpectrumAnalyzer.displayPointCount))
}

@Suite("Reference")
struct ReferenceTests {
    @Test("covers AE1: after 12 s of tone and 20 s of rest, Set reference holds 10 active seconds of the tone")
    func referenceIgnoresRest() throws {
        let ring = HistoryRing(capacity: 60 * rate)
        writeSine(ring, frequency: 1000, amplitudeDBFS: -17, seconds: 12)
        ring.write(at: 32 * rate - 1, [0, 0])
        let log = BandLog()
        steps(log, ring, from: 0, hops: 64)

        let reference = try #require(Reference.make(guitar: log.window(threshold: -60, limit: 20),
                                                    mix: log.window(threshold: -60, limit: 20),
                                                    windowSeconds: 10))
        #expect(reference.activeSeconds == 10)
        #expect(abs(reference.guitarLevelDBFS - -20) < 0.5)
    }

    @Test("covers AE1: 4 s of a 6 dB louder tone is partial near +6 dB, 10 s is not")
    func partialUntilWindowFills() throws {
        let ring = HistoryRing(capacity: 60 * rate)
        writeSine(ring, frequency: 1000, amplitudeDBFS: -17, seconds: 12)
        let log = BandLog()
        steps(log, ring, from: 0, hops: 24)
        let reference = try #require(Reference.make(guitar: log.window(threshold: -60, limit: 20),
                                                    mix: log.window(threshold: -60, limit: 20), windowSeconds: 10))
        let mark = log.nextSequence

        writeSine(ring, frequency: 1000, amplitudeDBFS: -11, seconds: 4, startFrame: 24 * hop)
        steps(log, ring, from: 24 * hop, hops: 8)
        var comparison = Comparison.make(reference: reference, window: log.window(threshold: -60, limit: 20, since: mark), windowHops: 20)
        #expect(comparison.partial)
        #expect(comparison.activeSeconds == 4)
        #expect(abs((comparison.levelDifferenceDB ?? 0) - 6) < 0.5)

        writeSine(ring, frequency: 1000, amplitudeDBFS: -11, seconds: 6, startFrame: 32 * hop)
        steps(log, ring, from: 32 * hop, hops: 12)
        comparison = Comparison.make(reference: reference, window: log.window(threshold: -60, limit: 20, since: mark), windowHops: 20)
        #expect(!comparison.partial)
    }

    @Test("covers AE3: Reset leaves the reference and restarts the comparison at 0 active seconds")
    func resetKeepsReference() throws {
        let ring = HistoryRing(capacity: 20 * rate)
        writeSine(ring, frequency: 1000, amplitudeDBFS: -17, seconds: 6)
        let log = BandLog()
        steps(log, ring, from: 0, hops: 12)
        let reference = try #require(Reference.make(guitar: log.window(threshold: -60, limit: 20),
                                                    mix: log.window(threshold: -60, limit: 20), windowSeconds: 10))
        log.reset()
        let comparison = Comparison.make(reference: reference, window: log.window(threshold: -60, limit: 20, since: log.nextSequence), windowHops: 20)
        #expect(comparison.partial)
        #expect(comparison.activeSeconds == 0)
        #expect(comparison.levelDifferenceDB == nil)
        #expect(comparison.octaveDifferencesDB == nil)
        #expect(reference.activeSeconds == 6)
    }

    @Test("a 6 dB rise at 1 kHz shows as +3 dB in the 1 kHz octave band and 0 dB elsewhere")
    func octaveBandDifference() throws {
        let flat = [Float](repeating: 1, count: bandCount)
        var louder = flat
        louder[ThirdOctaveBands.centerFrequencies.firstIndex(of: 1000)!] = 4
        let reference = try #require(Reference.make(guitar: BandLog.average([hop(sequence: 0, bands: flat)]),
                                                    mix: BandLog.average([]), windowSeconds: 10))
        let comparison = Comparison.make(reference: reference, window: BandLog.average([hop(sequence: 1, bands: louder)]), windowHops: 20)
        let octaves = try #require(comparison.octaveDifferencesDB)
        #expect(octaves.count == 10)
        #expect(abs(octaves[5] - 3.01) < 0.05)
        #expect(octaves.enumerated().allSatisfy { $0.offset == 5 || abs($0.element) < 0.001 })
    }

    @Test("octave bands sum their third-octave neighbours, including the edges")
    func octaveGrouping() {
        let centres = ThirdOctaveBands.centerFrequencies
        func group(_ centre: Double) -> [Double] {
            return OctaveBands.thirdOctaveIndices[OctaveBands.centerFrequencies.firstIndex(of: centre)!].map { centres[$0] }
        }
        #expect(OctaveBands.centerFrequencies.count == 10)
        #expect(group(31.5) == [25, 31.5, 40])
        #expect(group(16000) == [12500, 16000, 20000])
        #expect(OctaveBands.labels == ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"])
    }

    @Test("Set reference with no active guitar hops returns no reference")
    func noActiveHops() {
        #expect(Reference.make(guitar: BandLog.average([]), mix: BandLog.average([]), windowSeconds: 10) == nil)
    }

    @Test("Set reference with 6 of 10 s active stores 6 active seconds, and the mix is kept only when active")
    func partialReference() throws {
        let flat = [Float](repeating: 1, count: bandCount)
        let guitar = BandLog.average((0..<12).map { hop(sequence: $0, bands: flat) })
        let reference = try #require(Reference.make(guitar: guitar, mix: BandLog.average([]), windowSeconds: 10))
        #expect(reference.activeSeconds == 6)
        #expect(reference.mixBands == nil)
    }
}
