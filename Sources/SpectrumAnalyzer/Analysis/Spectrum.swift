import Accelerate

/// One point of a displayed spectrum curve.
struct SpectrumPoint: Equatable {
    let frequencyHz: Double
    let db: Float
}

/// Smoothed log-frequency spectrum for one audio source, following a moving
/// head into a `HistoryRing`. KTD5: an 8192-point Hann-windowed FFT mapped to
/// ~240 log-spaced points, exponentially smoothed. A small forward step folds
/// into the running average; a jump (scrub, replay start, Reset) re-warms from
/// scratch using only the `timeConstant` seconds before the new head, so nothing
/// carries over from the previous position. Live and replay share this path;
/// only the head passed to `advance` differs.
final class SpectrumAnalyzer {
    static let fftSize = 8192
    static let displayPointCount = 240
    static let minFrequency = 20.0
    static let maxFrequency = 20_000.0
    static let displayFloorDB: Float = -100
    static let liveHopSeconds = 1.0 / 30
    static let warmHopSeconds = 0.5

    static let displayFrequencies: [Double] = {
        let log2Min = log2(minFrequency)
        let log2Max = log2(maxFrequency)
        return (0..<displayPointCount).map { i in
            exp2(log2Min + (log2Max - log2Min) * Double(i) / Double(displayPointCount - 1))
        }
    }()

    let timeConstant: Double
    private var lastHead: Int?
    private var smoothedPower: [Float]

    init(timeConstant: Double = 3) {
        self.timeConstant = timeConstant
        smoothedPower = [Float](repeating: 0, count: Self.displayPointCount)
    }

    func reset() {
        lastHead = nil
        smoothedPower = [Float](repeating: 0, count: Self.displayPointCount)
    }

    /// Advances to `head` in `ring` and returns the smoothed display curve.
    @discardableResult
    func advance(ring: HistoryRing, to head: Int) -> [SpectrumPoint] {
        defer { lastHead = head }
        let hopFrames = Int(Self.liveHopSeconds * Double(HistoryRing.sampleRate))
        if let lastHead, (0..<(2 * max(hopFrames, 1))).contains(head - lastHead) {
            let elapsed = Double(head - lastHead) / Double(HistoryRing.sampleRate)
            blend(powerSpectrum(ring: ring, at: head), reset: false, elapsedSeconds: elapsed)
        } else {
            warm(ring: ring, to: head)
        }
        return points()
    }

    /// Rebuilds the average from only the `timeConstant` seconds before `head`,
    /// discarding whatever state preceded the jump. The last hop always lands
    /// exactly on `head`, so the curve always reflects the head itself even when
    /// the coarse hop is larger than the window being warmed from.
    private func warm(ring: HistoryRing, to head: Int) {
        let hopFrames = Int(Self.warmHopSeconds * Double(HistoryRing.sampleRate))
        let start = max(0, head - Int(timeConstant * Double(HistoryRing.sampleRate)))
        var t = start
        var first = true
        while t < head {
            let hopEnd = min(t + max(hopFrames, 1), head)
            let elapsed = Double(hopEnd - t) / Double(HistoryRing.sampleRate)
            blend(powerSpectrum(ring: ring, at: hopEnd), reset: first, elapsedSeconds: elapsed)
            first = false
            t = hopEnd
        }
        if first {
            blend(powerSpectrum(ring: ring, at: head), reset: true, elapsedSeconds: 0)
        }
    }

    private func blend(_ power: [Float], reset: Bool, elapsedSeconds: Double) {
        guard !reset else {
            smoothedPower = power
            return
        }
        let alpha = Float(1 - exp(-elapsedSeconds / timeConstant))
        for i in 0..<smoothedPower.count {
            smoothedPower[i] += alpha * (power[i] - smoothedPower[i])
        }
    }

    private func points() -> [SpectrumPoint] {
        zip(Self.displayFrequencies, smoothedPower).map { SpectrumPoint(frequencyHz: $0, db: dB($1)) }
    }

    private func dB(_ power: Float) -> Float {
        guard power > 0 else { return Self.displayFloorDB }
        return max(10 * log10(power), Self.displayFloorDB)
    }

    /// Runs the FFT over the `fftSize` frames ending at absolute frame
    /// `endFrame` and maps power onto the log-spaced display points. Frames
    /// before frame 0 read back as silence (`HistoryRing.read` already zero-fills
    /// out-of-range reads).
    private func powerSpectrum(ring: HistoryRing, at endFrame: Int) -> [Float] {
        let n = Self.fftSize
        let interleaved = ring.read(from: endFrame - n, count: n)

        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n {
            mono[i] = (Float(interleaved[i * 2]) + Float(interleaved[i * 2 + 1])) / 2 / 32768
        }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP.multiply(mono, window, result: &mono)

        var magnitudes = [Float](repeating: 0, count: n / 2)
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return mapToDisplayPoints(magnitudes: magnitudes)
        }
        defer { vDSP_destroy_fftsetup(setup) }

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
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        return mapToDisplayPoints(magnitudes: magnitudes)
    }

    /// Maps FFT bins onto the log-spaced display points by taking the loudest
    /// bin in each point's bucket (bounded by the geometric midpoints to its
    /// neighbors). Above a few hundred Hz a bucket spans several bins, so a
    /// plain nearest-bin lookup would skip narrow peaks between display
    /// points; below that a bucket is narrower than one bin, so it falls back
    /// to the single nearest bin.
    private func mapToDisplayPoints(magnitudes: [Float]) -> [Float] {
        let binHz = Double(HistoryRing.sampleRate) / Double(Self.fftSize)
        let frequencies = Self.displayFrequencies
        let nyquist = Double(HistoryRing.sampleRate) / 2
        return frequencies.indices.map { i in
            let low = i == 0 ? 0 : (frequencies[i - 1] * frequencies[i]).squareRoot()
            let high = i == frequencies.count - 1 ? nyquist : (frequencies[i] * frequencies[i + 1]).squareRoot()
            let lowBin = max(0, Int((low / binHz).rounded(.up)))
            let highBin = min(magnitudes.count - 1, Int((high / binHz).rounded(.down)))
            guard lowBin <= highBin else {
                let bin = min(max(Int((frequencies[i] / binHz).rounded()), 0), magnitudes.count - 1)
                return magnitudes[bin]
            }
            return magnitudes[lowBin...highBin].max() ?? 0
        }
    }
}
