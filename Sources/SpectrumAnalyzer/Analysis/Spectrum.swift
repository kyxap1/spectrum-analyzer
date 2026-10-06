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
        zip(Self.displayFrequencies, smoothedPower).map { SpectrumPoint(frequencyHz: $0, db: dB($1, floor: Self.displayFloorDB)) }
    }

    /// Runs the FFT over the `fftSize` frames ending at absolute frame
    /// `endFrame` and maps power onto the log-spaced display points.
    private func powerSpectrum(ring: HistoryRing, at endFrame: Int) -> [Float] {
        let (power, binHz) = fftPowerSpectrum(ring: ring, endFrame: endFrame, fftSize: Self.fftSize)
        return Self.mapToDisplayPoints(magnitudes: power, binHz: binHz)
    }

    /// Maps FFT bins onto the log-spaced display points by taking the loudest
    /// bin in each point's bucket.
    static func mapToDisplayPoints(magnitudes: [Float], binHz: Double) -> [Float] {
        let nyquist = Double(HistoryRing.sampleRate) / 2
        return frequencyBuckets(centerFrequencies: displayFrequencies,
                                binHz: binHz,
                                binCount: magnitudes.count,
                                nyquist: nyquist)
            .map { magnitudes[$0].max() ?? 0 }
    }
}
