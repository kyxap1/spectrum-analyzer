import Testing
@testable import SpectrumAnalyzer

@Suite("LiveSink")
@MainActor
struct LiveSinkTests {
    private final class Target { var shown: [Int] = [] }

    @Test("an attached target sees the current value at once, then every sent one")
    func attachAndSend() {
        let sink = LiveSink(1)
        let target = Target()
        sink.attach(target) { $0.shown.append($1) }
        sink.send(2)
        sink.send(3)
        #expect(target.shown == [1, 2, 3])
        #expect(sink.value == 3)
    }

    @Test("a target that went away is dropped and never called")
    func dropsReleasedTargets() {
        let sink = LiveSink(0)
        var calls = 0
        var target: Target? = Target()
        sink.attach(target!) { _, _ in calls += 1 }
        target = nil
        sink.send(1)
        sink.send(2)
        #expect(calls == 1)
    }
}
