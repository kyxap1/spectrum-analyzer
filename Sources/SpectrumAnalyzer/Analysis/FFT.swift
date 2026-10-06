import Accelerate
import Synchronization

/// The FFT setup and Hann window for one size, built once: creating a setup
/// per call was most of an FFT's cost. A setup is read-only while a transform
/// runs, so any thread may share it; it lives for the whole process.
private struct FFTPlan: @unchecked Sendable {
    let setup: FFTSetup
    let window: [Float]
}

private enum FFTPlans {
    private static let plans = Mutex<[Int: FFTPlan]>([:])

    static func plan(size n: Int) -> FFTPlan? {
        plans.withLock { plans in
            if let plan = plans[n] { return plan }
            guard let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(n))), FFTRadix(kFFTRadix2)) else { return nil }
            var window = [Float](repeating: 0, count: n)
            vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
            let plan = FFTPlan(setup: setup, window: window)
            plans[n] = plan
            return plan
        }
    }
}

/// Runs a Hann-windowed real FFT over `fftSize` frames of `ring` ending at
/// absolute frame `endFrame`, summing stereo to mono first, and returns power
/// per bin (`fftSize / 2` bins) plus the bin width in Hz. Frames before frame
/// 0 read back as silence (`HistoryRing.read` already zero-fills out-of-range
/// reads). Shared by `SpectrumAnalyzer` (mapped to log-spaced display points)
/// and `ThirdOctaveBands` (summed into third-octave bands).
func fftPowerSpectrum(ring: HistoryRing, endFrame: Int, fftSize: Int) -> (power: [Float], binHz: Double) {
    fftPowerSpectrum(interleaved: ring.read(from: endFrame - fftSize, count: fftSize), fftSize: fftSize)
}

/// As above, over an already-read interleaved stereo buffer (`fftSize` frames)
/// -- lets a caller that also needs the raw samples, such as `Payload`'s RMS
/// silence gate, read the window once.
func fftPowerSpectrum(interleaved: [Int16], fftSize: Int) -> (power: [Float], binHz: Double) {
    let n = fftSize
    let binHz = Double(HistoryRing.sampleRate) / Double(n)

    var mono = [Float](repeating: 0, count: n)
    for i in 0..<n {
        mono[i] = (Float(interleaved[i * 2]) + Float(interleaved[i * 2 + 1])) / 2 / 32768
    }

    var power = [Float](repeating: 0, count: n / 2)
    let log2n = vDSP_Length(log2(Double(n)))
    guard let plan = FFTPlans.plan(size: n) else {
        return (power, binHz)
    }
    let setup = plan.setup
    vDSP.multiply(mono, plan.window, result: &mono)

    var realp = [Float](repeating: 0, count: n / 2)
    var imagp = [Float](repeating: 0, count: n / 2)
    realp.withUnsafeMutableBufferPointer { realBuf in
        imagp.withUnsafeMutableBufferPointer { imagBuf in
            var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
            mono.withUnsafeBufferPointer { monoBuf in
                monoBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

            // vDSP's real-FFT packing already doubles the true DFT magnitude
            // (it runs an N/2-point complex FFT under the hood), and a Hann
            // window has a coherent gain of 0.5, so a peak bin's magnitude
            // needs dividing by (N * 0.5 * 2) = N to read back the true
            // amplitude of a windowed sinusoid.
            var scale = Float(1) / Float(n)
            vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, vDSP_Length(n / 2))
            vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, vDSP_Length(n / 2))
            vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
        }
    }

    return (power, binHz)
}

/// Power in dB, clamped to `floor` (power at or below zero reads as `floor`).
func dB(_ power: Float, floor: Float) -> Float {
    power > 0 ? max(10 * log10(power), floor) : floor
}

/// FFT bin ranges for a set of ascending `centerFrequencies`, each bucket
/// bounded by the geometric midpoint to its neighbors (the first starts at 0
/// Hz, the last extends to `nyquist`). Above a few hundred Hz a bucket spans
/// several bins; below that a bucket is narrower than one bin, so it falls
/// back to the single nearest bin. Shared by `SpectrumAnalyzer` (folds each
/// bucket to its loudest bin) and `ThirdOctaveBands` (sums each bucket's power).
func frequencyBuckets(centerFrequencies: [Double], binHz: Double, binCount: Int, nyquist: Double) -> [ClosedRange<Int>] {
    centerFrequencies.indices.map { i in
        let low = i == 0 ? 0 : (centerFrequencies[i - 1] * centerFrequencies[i]).squareRoot()
        let high = i == centerFrequencies.count - 1 ? nyquist : (centerFrequencies[i] * centerFrequencies[i + 1]).squareRoot()
        let lowBin = max(0, Int((low / binHz).rounded(.up)))
        let highBin = min(binCount - 1, Int((high / binHz).rounded(.down)))
        guard lowBin <= highBin else {
            let bin = min(max(Int((centerFrequencies[i] / binHz).rounded()), 0), binCount - 1)
            return bin...bin
        }
        return lowBin...highBin
    }
}
