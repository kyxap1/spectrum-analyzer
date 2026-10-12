import Testing
@testable import SpectrumAnalyzer

private let bandCount = ThirdOctaveBands.centerFrequencies.count

private func window(peaks: [Float], level: Float, band: Float = 0.01) -> ActiveWindow {
    let bands = [Float](repeating: band, count: bandCount)
    let hops = peaks.enumerated().map { i, peak in
        LogHop(sequence: i, endFrame: (i + 1) * BandLog.hopFrames, rmsDBFS: level, bands: bands,
               display: [Float](repeating: 1, count: SpectrumAnalyzer.displayPointCount), peakDBFS: peak)
    }
    return ActiveWindow(hops: hops, bandPower: hops.isEmpty ? [Float](repeating: 0, count: bandCount) : bands,
                        displayPower: [], levelDBFS: hops.isEmpty ? -.infinity : level)
}

@Suite("Levels table")
struct LevelsTableTests {
    @Test("rows read the windows, the reference, and the comparison's differences")
    func rows() throws {
        let guitar = window(peaks: [-6, -8], level: -14)
        let reference = try #require(Reference.make(guitar: window(peaks: [-5, -5], level: -13, band: 0.02),
                                                    mix: window(peaks: [], level: 0), windowSeconds: 1))
        let comparison = Comparison.make(reference: reference, window: guitar, windowHops: 2)

        let table = LevelsTable(guitar: guitar, mix: window(peaks: [], level: 0), reference: reference,
                                comparison: comparison, windowSeconds: 10)

        let row = try #require(table.guitar)
        #expect(row.loudnessDB == Loudness.db(bands: guitar.bandPower))
        #expect(row.averagePeakDBFS == -7)
        #expect(row.crestDB == 7)
        #expect(row.playing == "1.0 / 10 s")
        #expect(table.reference?.averagePeakDBFS == -5)
        #expect(table.reference?.playing == "1 s")
        #expect(table.difference?.loudnessDB == comparison.loudnessDifferenceDB)
        #expect(table.difference?.crestDB == comparison.crestDifferenceDB)
        #expect(table.mix == LevelsRow(loudnessDB: nil, averagePeakDBFS: nil, crestDB: nil, playing: "0.0 / 10 s"))
    }

    @Test("without a reference or a captured guitar those rows are absent")
    func absentRows() {
        let table = LevelsTable(guitar: nil, mix: window(peaks: [-10], level: -20), reference: nil, comparison: nil, windowSeconds: 5)
        #expect(table.guitar == nil)
        #expect(table.reference == nil)
        #expect(table.difference == nil)
        #expect(table.mix.playing == "0.5 / 5 s")
    }
}
