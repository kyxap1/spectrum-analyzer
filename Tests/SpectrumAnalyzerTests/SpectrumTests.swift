import Darwin
import Testing
@testable import SpectrumAnalyzer

private let rate = HistoryRing.sampleRate

/// Writes a stereo sine (same on both channels) of `seconds` duration at `frequency`
/// and `amplitudeDBFS` peak amplitude, starting at frame 0.
private func writeSine(_ ring: HistoryRing, frequency: Double, amplitudeDBFS: Double, seconds: Double) {
    let count = Int(seconds * Double(rate))
    let amplitude = pow(10, amplitudeDBFS / 20)
    var frames = [Int16](repeating: 0, count: count * HistoryRing.channels)
    for n in 0..<count {
        let sample = amplitude * sin(2 * .pi * frequency * Double(n) / Double(rate))
        let quantized = Int16(clamping: Int((sample * 32767).rounded()))
        frames[n * 2] = quantized
        frames[n * 2 + 1] = quantized
    }
    ring.write(at: 0, frames)
}

private func nearestPoint(to frequency: Double, in points: [SpectrumPoint]) -> SpectrumPoint {
    points.min(by: { abs(log2($0.frequencyHz / frequency)) < abs(log2($1.frequencyHz / frequency)) })!
}

@Suite("Spectrum")
struct SpectrumTests {
    @Test("a 1 kHz sine at -12 dBFS peaks near -12 dB at the nearest display point")
    func sinePeakLevel() {
        let ring = HistoryRing(capacity: SpectrumAnalyzer.fftSize * 2)
        writeSine(ring, frequency: 1_000, amplitudeDBFS: -12, seconds: Double(SpectrumAnalyzer.fftSize) / Double(rate))

        let analyzer = SpectrumAnalyzer()
        let points = analyzer.advance(ring: ring, to: SpectrumAnalyzer.fftSize)

        let peak = points.max(by: { $0.db < $1.db })!
        #expect(abs(peak.frequencyHz - 1_000) / 1_000 < 0.1)
        #expect(abs(peak.db - (-12)) < 3)
    }

    @Test("20 Hz and 20 kHz map to the first and last display points, spacing is monotonic")
    func displayPointRange() {
        let frequencies = SpectrumAnalyzer.displayFrequencies
        #expect(frequencies.count == SpectrumAnalyzer.displayPointCount)
        #expect(abs(frequencies.first! - 20) < 0.001)
        #expect(abs(frequencies.last! - 20_000) < 0.001)
        for i in 1..<frequencies.count {
            #expect(frequencies[i] > frequencies[i - 1])
        }
    }

    @Test("silence yields the display floor, never NaN or -infinity")
    func silenceIsFloor() {
        let ring = HistoryRing(capacity: SpectrumAnalyzer.fftSize * 2)
        let analyzer = SpectrumAnalyzer()
        let points = analyzer.advance(ring: ring, to: SpectrumAnalyzer.fftSize)

        for point in points {
            #expect(point.db == SpectrumAnalyzer.displayFloorDB)
            #expect(!point.db.isNaN)
            #expect(point.db.isFinite)
        }
    }

    @Test("a step from silence to a tone reaches ~63% of the final power after one time constant")
    func stepResponseReachesOneMinusOverE() {
        let tau = 1.0
        let toneStart = SpectrumAnalyzer.fftSize
        let capacity = toneStart + Int(20 * tau * Double(rate))
        let ring = HistoryRing(capacity: capacity)
        // Ring starts zeroed (silence); write a continuous tone from toneStart on.
        let amplitude = pow(10, -6.0 / 20)
        let toneFrames = capacity - toneStart
        var frames = [Int16](repeating: 0, count: toneFrames * HistoryRing.channels)
        for n in 0..<toneFrames {
            let sample = amplitude * sin(2 * .pi * 1_000 * Double(n) / Double(rate))
            let quantized = Int16(clamping: Int((sample * 32767).rounded()))
            frames[n * 2] = quantized
            frames[n * 2 + 1] = quantized
        }
        ring.write(at: toneStart, frames)

        let steadyState = SpectrumAnalyzer(timeConstant: tau)
        // Warm at the very end, entirely within the tone, so smoothing has fully converged.
        let steadyPoints = steadyState.advance(ring: ring, to: capacity)
        let steadyPeak = nearestPoint(to: 1_000, in: steadyPoints)
        let steadyPower = pow(10, steadyPeak.db / 10)

        let stepping = SpectrumAnalyzer(timeConstant: tau)
        stepping.advance(ring: ring, to: toneStart) // warms on silence just before the step
        let hop = Int(SpectrumAnalyzer.liveHopSeconds * Double(rate))
        var head = toneStart
        var lastPoints: [SpectrumPoint] = []
        while head < toneStart + Int(tau * Double(rate)) {
            head += hop
            lastPoints = stepping.advance(ring: ring, to: head)
        }
        let steppedPeak = nearestPoint(to: 1_000, in: lastPoints)
        let steppedPower = pow(10, steppedPeak.db / 10)

        let ratio = steppedPower / steadyPower
        #expect(abs(ratio - (1 - exp(-1))) < 0.15)
    }

    @Test("jumping the head gives the same result as warming from scratch at that head")
    func jumpMatchesFreshWarm() {
        let ring = HistoryRing(capacity: SpectrumAnalyzer.fftSize * 8)
        writeSine(ring, frequency: 500, amplitudeDBFS: -9, seconds: Double(ring.capacity) / Double(rate))
        let jumpHead = ring.capacity - SpectrumAnalyzer.fftSize

        let warmedFromLive = SpectrumAnalyzer()
        let hop = Int(SpectrumAnalyzer.liveHopSeconds * Double(rate))
        var head = SpectrumAnalyzer.fftSize
        while head < jumpHead / 2 {
            head += hop
            warmedFromLive.advance(ring: ring, to: head)
        }
        // A jump larger than a couple of live hops re-warms from scratch.
        let afterJump = warmedFromLive.advance(ring: ring, to: jumpHead)

        let fresh = SpectrumAnalyzer()
        let freshResult = fresh.advance(ring: ring, to: jumpHead)

        #expect(afterJump == freshResult)
    }
}
