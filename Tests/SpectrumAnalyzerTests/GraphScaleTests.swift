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

    @Test("the spectrum pane sits above the difference pane, 60 / 40, covering the full height with no gap")
    func paneSplit() {
        let panes = GraphScale.panes(height: 500)
        #expect(panes.spectrum.top == 0)
        #expect(panes.spectrum.bottom == panes.difference.top)
        #expect(panes.difference.bottom == 500)
        #expect(panes.spectrum.height == 300)
        #expect(panes.difference.height == 200)
    }

    @Test("without a difference pane the spectrum pane takes the full height")
    func singlePane() {
        let panes = GraphScale.panes(height: 500, withDifference: false)
        #expect(panes.spectrum == GraphPane(top: 0, height: 500))
        #expect(panes.difference.height == 0)
    }

    @Test("the difference pane maps 0 dB to its middle, +/-12 dB to its edges, and clamps beyond")
    func differenceScale() {
        let pane = GraphScale.panes(height: 500).difference
        #expect(GraphScale.y(forDifferenceDB: 0, in: pane) == 400)
        #expect(GraphScale.y(forDifferenceDB: 12, in: pane) == 300)
        #expect(GraphScale.y(forDifferenceDB: -12, in: pane) == 500)
        #expect(GraphScale.y(forDifferenceDB: 40, in: pane) == 300)
        #expect(GraphScale.y(forDifferenceDB: -40, in: pane) == 500)
    }

    @Test("the spectrum pane keeps the dBFS scale inside its own height")
    func spectrumPaneScale() {
        let pane = GraphScale.panes(height: 500).spectrum
        #expect(GraphScale.y(forDB: 0, in: pane) == 0)
        #expect(GraphScale.y(forDB: SpectrumAnalyzer.displayFloorDB, in: pane) == 300)
    }

    @Test("corridor bounds are the reference plus its level offset, plus and minus the tone step, at every point")
    func corridorBounds() {
        let reference = [SpectrumPoint(frequencyHz: 100, db: -30), SpectrumPoint(frequencyHz: 200, db: -42)]
        let corridor = GraphScale.corridor(reference: reference, offsetDB: 3, stepDB: 1)
        #expect(corridor.upper == [SpectrumPoint(frequencyHz: 100, db: -26), SpectrumPoint(frequencyHz: 200, db: -38)])
        #expect(corridor.lower == [SpectrumPoint(frequencyHz: 100, db: -28), SpectrumPoint(frequencyHz: 200, db: -40)])
    }

    @Test("the difference curve is guitar minus mix per point")
    func differenceCurve() {
        let guitar = [SpectrumPoint(frequencyHz: 100, db: -20), SpectrumPoint(frequencyHz: 200, db: -30)]
        let mix = [SpectrumPoint(frequencyHz: 100, db: -26), SpectrumPoint(frequencyHz: 200, db: -24)]
        #expect(GraphScale.difference(guitar, minus: mix)
            == [SpectrumPoint(frequencyHz: 100, db: 6), SpectrumPoint(frequencyHz: 200, db: -6)])
    }

    @Test("the difference is guitar minus the level-matched reference, and absent without a reference")
    func frameDifference() {
        let guitar = [SpectrumPoint(frequencyHz: 100, db: -20)]
        let mix = [SpectrumPoint(frequencyHz: 100, db: -26)]
        let reference = [SpectrumPoint(frequencyHz: 100, db: -25)]
        var frame = GraphFrame(guitar: guitar, mix: mix)
        #expect(frame.difference == nil)
        frame.reference = reference
        frame.referenceOffsetDB = 3
        #expect(frame.difference == [SpectrumPoint(frequencyHz: 100, db: 2)])
        frame.guitar = nil
        #expect(frame.difference == nil)
    }

    @Test("scrubber labels seconds as m:ss")
    func mmss() {
        #expect(formatMMSS(seconds: 0) == "0:00")
        #expect(formatMMSS(seconds: 65) == "1:05")
        #expect(formatMMSS(seconds: 600) == "10:00")
    }
}
