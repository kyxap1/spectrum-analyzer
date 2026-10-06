import Testing
@testable import SpectrumAnalyzer

@Suite("ClipLatch")
struct ClipLatchTests {
    @Test("a 1 s peak at -0.5 dBFS latches the warning, which clears 3 s after the last such peak")
    func latchesAndClears() {
        var latch = ClipLatch()
        #expect(latch.update(guitarPeakDBFS: -0.5, mixPeakDBFS: -20, seconds: 0.1) == [.guitar])
        for _ in 0..<29 { _ = latch.update(guitarPeakDBFS: -20, mixPeakDBFS: -20, seconds: 0.1) }
        #expect(latch.clipping == [.guitar])
        #expect(latch.update(guitarPeakDBFS: -20, mixPeakDBFS: -20, seconds: 0.1).isEmpty)
    }

    @Test("a peak at -2 dBFS never latches")
    func belowNeverLatches() {
        var latch = ClipLatch()
        #expect(latch.update(guitarPeakDBFS: -2, mixPeakDBFS: -2, seconds: 0.1).isEmpty)
    }

    @Test("the warning names the input that clipped, and both can warn at once")
    func namesInputs() {
        var latch = ClipLatch()
        #expect(latch.update(guitarPeakDBFS: nil, mixPeakDBFS: -0.2, seconds: 0.1) == [.mix])
        #expect(latch.update(guitarPeakDBFS: 0, mixPeakDBFS: -30, seconds: 0.1) == [.guitar, .mix])
        #expect(ClipLatch.warning([.guitar, .mix]) == "Clipping: guitar, mix")
        #expect(ClipLatch.warning([.mix]) == "Clipping: mix")
        #expect(ClipLatch.warning([]) == nil)
    }
}
