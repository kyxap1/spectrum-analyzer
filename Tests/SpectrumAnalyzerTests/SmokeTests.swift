import Testing

@Suite("Smoke")
struct SmokeTests {
    @Test("test target builds and runs")
    func testTargetRuns() {
        #expect(1 + 1 == 2)
    }
}
