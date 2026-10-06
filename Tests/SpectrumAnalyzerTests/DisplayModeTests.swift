import Testing
@testable import SpectrumAnalyzer

@Suite("DisplayMode")
struct DisplayModeTests {
    @Test("covers AE4: on for screen A, off on the built-in display, on again back on A")
    func followsRememberedScreen() {
        var memory = DisplayModeMemory()
        memory.screenChanged(to: "A")
        memory.setOn(true)
        #expect(memory.isOn)
        memory.screenChanged(to: "Built-in Retina Display")
        #expect(!memory.isOn)
        memory.screenChanged(to: "A")
        #expect(memory.isOn)
    }

    @Test("turning it off by hand forgets the screen, so moving away and back keeps it off")
    func manualOffForgets() {
        var memory = DisplayModeMemory()
        memory.screenChanged(to: "A")
        memory.setOn(true)
        memory.setOn(false)
        #expect(memory.remembered == nil)
        memory.screenChanged(to: "B")
        memory.screenChanged(to: "A")
        #expect(!memory.isOn)
    }

    @Test("turning it on before any screen is known stays on and remembers the first screen reported")
    func firstScreenIsRemembered() {
        var memory = DisplayModeMemory()
        memory.setOn(true)
        #expect(memory.isOn)
        memory.screenChanged(to: "A")
        #expect(memory.isOn)
        #expect(memory.remembered == "A")
        memory.screenChanged(to: "B")
        #expect(!memory.isOn)
    }

    @Test("a remembered screen from a previous launch switches it on when the window opens there")
    func restoredAcrossLaunches() {
        var memory = DisplayModeMemory(remembered: "A")
        #expect(!memory.isOn)
        memory.screenChanged(to: "A")
        #expect(memory.isOn)
    }
}
