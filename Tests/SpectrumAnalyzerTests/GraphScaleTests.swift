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

    @Test("frequency grid labels use k above 1 kHz")
    func frequencyLabels() {
        #expect(GraphScale.frequencyGridLines.map(GraphScale.frequencyLabel)
            == ["20", "50", "100", "200", "500", "1k", "2k", "5k", "10k", "20k"])
    }

    @Test("scrubber labels seconds as m:ss")
    func mmss() {
        #expect(formatMMSS(seconds: 0) == "0:00")
        #expect(formatMMSS(seconds: 65) == "1:05")
        #expect(formatMMSS(seconds: 600) == "10:00")
    }
}
