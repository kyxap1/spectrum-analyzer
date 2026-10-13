import AppKit
import Testing
@testable import SpectrumAnalyzer

@Suite("AdviceWindowPlacer")
struct AdviceWindowTests {
    let screen = NSRect(x: 0, y: 0, width: 1800, height: 1100)

    @Test("the advice docks right of the main window, else left, at its top and height")
    func beside() {
        let left = NSRect(x: 0, y: 100, width: 1100, height: 900)
        #expect(AdviceWindowPlacer.docked(advice: 640, main: left, in: screen)
            == (left, NSRect(x: 1100, y: 100, width: 640, height: 900)))
        let right = NSRect(x: 700, y: 100, width: 1100, height: 900)
        #expect(AdviceWindowPlacer.docked(advice: 640, main: right, in: screen)
            == (right, NSRect(x: 60, y: 100, width: 640, height: 900)))
    }

    @Test("without room on either side the main window shifts left and the advice narrows to fit")
    func noRoom() {
        let main = NSRect(x: 386, y: 133, width: 1112, height: 926)
        #expect(AdviceWindowPlacer.docked(advice: 900, main: main, in: screen)
            == (NSRect(x: 0, y: 133, width: 1112, height: 926), NSRect(x: 1112, y: 133, width: 688, height: 926)))
    }
}
