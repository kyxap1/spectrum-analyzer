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

    @Test("a range maps its top to 0 and its bottom to the height, clamps outside it, and skips a point with no value")
    func dbBounds() {
        #expect(GraphScale.y(forDB: -10, range: -100 ... -10, height: 500) == 0)
        #expect(GraphScale.y(forDB: -100, range: -100 ... -10, height: 500) == 500)
        #expect(GraphScale.y(forDB: -55, range: -100 ... -10, height: 500) == 250)
        #expect(GraphScale.y(forDB: -130, range: -100 ... -10, height: 500) == 500)
        #expect(GraphScale.y(forDB: 3, range: -100 ... -10, height: 500) == 0)
        #expect(GraphScale.y(forDB: -.infinity, range: -100 ... -10, height: 500) == nil)
    }

    @Test("grid lines are the step multiples inside the range, top first")
    func gridLines() {
        #expect(GraphScale.gridLines(range: -100 ... -10, step: 20) == [-20, -40, -60, -80, -100])
        #expect(GraphScale.gridLines(range: -12 ... 12, step: 6) == [12, 6, 0, -6, -12])
    }

    @Test("dB labels keep both ends and drop those between that would touch a neighbour")
    func fittingLabels() {
        #expect(GraphScale.fittingLabels([0, 10, 20, 30, 40, 50, 60], labelHeight: 18) == [0, 2, 4, 6])
        #expect(GraphScale.fittingLabels([0, 10, 20], labelHeight: 18) == [0, 2])
        #expect(GraphScale.fittingLabels([0, 50, 100], labelHeight: 18) == [0, 1, 2])
        #expect(GraphScale.fittingLabels([5], labelHeight: 18) == [0])
    }

    @Test("grid labels follow the 10 octave bands, labelled as on the EQ2")
    func frequencyLabels() {
        #expect(GraphScale.frequencyGridLabels == ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"])
        #expect(GraphScale.frequencyGridLines.count == GraphScale.frequencyGridLabels.count)
    }

    @Test("a difference exists only where both curves are inside the range")
    func differenceCurve() {
        let guitar = [SpectrumPoint(frequencyHz: 100, db: -20), SpectrumPoint(frequencyHz: 200, db: -30),
                      SpectrumPoint(frequencyHz: 400, db: -95)]
        let reference = [SpectrumPoint(frequencyHz: 100, db: -26), SpectrumPoint(frequencyHz: 200, db: -24),
                         SpectrumPoint(frequencyHz: 400, db: -40)]
        #expect(GraphScale.difference(guitar, minus: reference, bottomDB: -90)
            == [SpectrumPoint(frequencyHz: 100, db: 6), SpectrumPoint(frequencyHz: 200, db: -6),
                SpectrumPoint(frequencyHz: 400, db: -.infinity)])
    }

    @Test("the frame difference is guitar minus the level-matched reference, and absent without a reference")
    func frameDifference() {
        let guitar = [SpectrumPoint(frequencyHz: 1_000, db: -20)]
        let mix = [SpectrumPoint(frequencyHz: 1_000, db: -26)]
        let reference = [SpectrumPoint(frequencyHz: 1_000, db: -25)]
        var frame = GraphFrame(guitar: guitar, mix: mix)
        #expect(frame.difference == nil)
        frame.reference = reference
        frame.referenceOffsetDB = 3
        #expect(frame.difference == [SpectrumPoint(frequencyHz: 1_000, db: 2)])
        frame.guitar = nil
        #expect(frame.difference == nil)
    }

    @Test("a curve at the analysis floor leaves no difference: it would show only the loudness offset")
    func floorDifference() {
        let floor = SpectrumAnalyzer.displayFloorDB
        var frame = GraphFrame(guitar: [SpectrumPoint(frequencyHz: 8_000, db: floor)], mix: [])
        frame.reference = [SpectrumPoint(frequencyHz: 8_000, db: floor)]
        frame.referenceOffsetDB = -8
        #expect(frame.difference?.first?.db == -.infinity)
    }

    @Test("scrubber labels seconds as m:ss")
    func mmss() {
        #expect(formatMMSS(seconds: 0) == "0:00")
        #expect(formatMMSS(seconds: 65) == "1:05")
        #expect(formatMMSS(seconds: 600) == "10:00")
    }
}
