import Testing
@testable import SpectrumAnalyzer

@Suite("PaneHeights")
struct PaneHeightsTests {
    @Test("a short window keeps the floors, which are the sizes tuned for a 1280x800 tablet")
    func smallWindowKeepsFloors() {
        #expect(PaneHeights(windowHeight: 650) == PaneHeights.floor)
        #expect(PaneHeights.floor.octave == 144 && PaneHeights.floor.difference == 137 && PaneHeights.floor.history == 98)
    }

    @Test("a 1080p tablet gives every pane more than its floor, and the loudness history the most growth")
    func tallWindowGrows() {
        let tall = PaneHeights(windowHeight: 1000)
        #expect(tall.octave == 180 && tall.difference == 150 && tall.history == 150)
        #expect(tall.history - PaneHeights.floor.history > tall.octave - PaneHeights.floor.octave)
    }
}
