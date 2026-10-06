import Darwin
import Testing
@testable import SpectrumAnalyzer

@Suite("GraphScale")
struct GraphScaleTests {
    @Test("20 Hz maps to x = 0 and 20 kHz maps to the full width")
    func frequencyBounds() {
        #expect(GraphScale.x(forHz: 20, width: 1_000) == 0)
        #expect(abs(GraphScale.x(forHz: 20_000, width: 1_000) - 1_000) < 0.001)
    }

    @Test("1 kHz maps to its log-scaled position")
    func logPosition() {
        let x = GraphScale.x(forHz: 1_000, width: 1_000)
        let expected = log2(1_000.0 / 20) / log2(20_000.0 / 20) * 1_000
        #expect(abs(x - expected) < 0.001)
    }

    @Test("0 dB maps to the top and the floor maps to the bottom")
    func dbBounds() {
        #expect(GraphScale.y(forDB: 0, height: 500) == 0)
        #expect(GraphScale.y(forDB: SpectrumAnalyzer.displayFloorDB, height: 500) == 500)
    }

    @Test("grid labels follow the 10 octave bands, labelled as on the EQ2")
    func frequencyLabels() {
        #expect(GraphScale.frequencyGridLabels == ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"])
        #expect(GraphScale.frequencyGridLines.count == GraphScale.frequencyGridLabels.count)
    }

    @Test("0 dB on the difference scale is mid-height, +/-30 dB the edges, beyond clamped")
    func differenceScale() {
        #expect(GraphScale.y(forDifferenceDB: 0, height: 500) == 250)
        #expect(GraphScale.y(forDifferenceDB: 30, height: 500) == 0)
        #expect(GraphScale.y(forDifferenceDB: -30, height: 500) == 500)
        #expect(GraphScale.y(forDifferenceDB: 80, height: 500) == 0)
        #expect(GraphScale.y(forDifferenceDB: -80, height: 500) == 500)
    }

    @Test("the difference curve is guitar minus mix per point")
    func differenceCurve() {
        let guitar = [SpectrumPoint(frequencyHz: 100, db: -20), SpectrumPoint(frequencyHz: 200, db: -30)]
        let mix = [SpectrumPoint(frequencyHz: 100, db: -26), SpectrumPoint(frequencyHz: 200, db: -24)]
        #expect(GraphScale.difference(guitar: guitar, mix: mix)
            == [SpectrumPoint(frequencyHz: 100, db: 6), SpectrumPoint(frequencyHz: 200, db: -6)])
    }

    @Test("scrubber labels seconds as m:ss")
    func mmss() {
        #expect(formatMMSS(seconds: 0) == "0:00")
        #expect(formatMMSS(seconds: 65) == "1:05")
        #expect(formatMMSS(seconds: 600) == "10:00")
    }
}
