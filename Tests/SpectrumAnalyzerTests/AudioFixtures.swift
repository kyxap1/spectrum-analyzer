import Darwin
@testable import SpectrumAnalyzer

/// Writes a stereo sine (same on both channels) of `seconds` duration at
/// `frequency` and `amplitudeDBFS` peak amplitude, starting at frame 0.
func writeSine(_ ring: HistoryRing, frequency: Double, amplitudeDBFS: Double, seconds: Double) {
    let rate = HistoryRing.sampleRate
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
