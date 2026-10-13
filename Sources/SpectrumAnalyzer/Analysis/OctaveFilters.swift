import Accelerate

/// KTD2: 10 one-octave band-pass sections centred on the EQ2 factory bands.
/// Stateless: every call starts from rest and lets `primingFrames` of audio
/// settle the filters, so no state survives between hops and the 31.5 Hz
/// band's start transient stays out of the figures.
enum OctaveFilters {
    static let primingFrames = HistoryRing.sampleRate / 10

    /// RBJ cookbook band-pass, 0 dB at the centre, one octave between its
    /// -3 dB points, as vDSP's `[b0, b1, b2, a1, a2]`.
    static func coefficients(centerHz: Double) -> [Double] {
        let w0 = 2 * Double.pi * centerHz / Double(HistoryRing.sampleRate)
        let alpha = sin(w0) * sinh(log(2) / 2 * w0 / sin(w0))
        let a0 = 1 + alpha
        return [alpha / a0, 0, -alpha / a0, -2 * cos(w0) / a0, (1 - alpha) / a0]
    }

    // Built once and never mutated, so sharing across threads is safe.
    nonisolated(unsafe) private static let setups: [vDSP_biquad_SetupD] = OctaveBands.centerFrequencies.map {
        vDSP_biquad_CreateSetupD(coefficients(centerHz: $0), 1)!
    }

    /// Each band's peak amplitude and mean square over `mono` past its first
    /// `priming` samples.
    static func measure(_ mono: [Double], priming: Int) -> (peaks: [Double], meanSquares: [Double]) {
        let count = vDSP_Length(mono.count - priming)
        var output = [Double](repeating: 0, count: mono.count)
        var peaks: [Double] = []
        var meanSquares: [Double] = []
        for setup in setups {
            var delay = [Double](repeating: 0, count: 4)
            vDSP_biquadD(setup, &delay, mono, 1, &output, 1, vDSP_Length(mono.count))
            var peak = 0.0
            var meanSquare = 0.0
            output.withUnsafeBufferPointer { filtered in
                vDSP_maxmgvD(filtered.baseAddress! + priming, 1, &peak, count)
                vDSP_measqvD(filtered.baseAddress! + priming, 1, &meanSquare, count)
            }
            peaks.append(peak)
            meanSquares.append(meanSquare)
        }
        return (peaks, meanSquares)
    }
}
