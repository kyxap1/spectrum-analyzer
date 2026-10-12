import Testing
@testable import SpectrumAnalyzer

@Suite("PeakHold")
struct PeakHoldTests {
    private static func curve(_ db: Float) -> [SpectrumPoint] {
        [SpectrumPoint(frequencyHz: 100, db: db), SpectrumPoint(frequencyHz: 200, db: db - 10)]
    }

    /// Feeds `curve` for `seconds` in 1/30 s frames and returns the held dB of the first point.
    private static func run(_ hold: inout PeakHold, _ db: Float, seconds: Double) -> Float {
        for _ in 0..<Int((seconds * 30).rounded()) { hold.update(with: curve(db), elapsedSeconds: 1.0 / 30) }
        return hold.points[0].db
    }

    @Test("a rising curve is followed at once")
    func followsUp() {
        var hold = PeakHold()
        hold.update(with: Self.curve(-40), elapsedSeconds: 1.0 / 30)
        hold.update(with: Self.curve(-20), elapsedSeconds: 1.0 / 30)
        #expect(hold.points == Self.curve(-20))
    }

    @Test("a falling curve is held for 3 s, then falls 20 dB per second, never below the curve")
    func holdsThenFalls() {
        var hold = PeakHold()
        hold.update(with: Self.curve(-20), elapsedSeconds: 1.0 / 30)
        #expect(Self.run(&hold, -60, seconds: 2.9) == -20)
        let afterHalfSecondOfFall = Self.run(&hold, -60, seconds: 0.6)
        #expect(abs(afterHalfSecondOfFall - -30) < 1)
        #expect(Self.run(&hold, -60, seconds: 5) == -60)
    }

    @Test("a new peak during the fall restarts the hold")
    func newPeakRestartsHold() {
        var hold = PeakHold()
        hold.update(with: Self.curve(-20), elapsedSeconds: 1.0 / 30)
        _ = Self.run(&hold, -60, seconds: 4)
        hold.update(with: Self.curve(-25), elapsedSeconds: 1.0 / 30)
        #expect(Self.run(&hold, -60, seconds: 2.9) == -25)
    }

    @Test("after a reset, as after a scrub or Reset, the hold restarts from the live curve")
    func resetRestarts() {
        var hold = PeakHold()
        hold.update(with: Self.curve(-10), elapsedSeconds: 1.0 / 30)
        hold.reset()
        hold.update(with: Self.curve(-50), elapsedSeconds: 1.0 / 30)
        #expect(hold.points == Self.curve(-50))
    }
}
