import Foundation

/// KTD1: K-weighted loudness summed from the 31 third-octave band powers.
/// Live hops, the live window and a stored reference all go through `db`, so
/// old snapshots compare on equal terms. Only differences are shown, so the
/// absolute offset does not matter.
enum Loudness {
    /// ITU-R BS.1770 pre-filter (shelf) and RLB high-pass at 48 kHz, which is
    /// `HistoryRing.sampleRate`, as `[b0, b1, b2, a1, a2]`.
    private static let stages: [[Double]] = [
        [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585],
        [1, -2, 1, -1.99004745483398, 0.99007225036621],
    ]

    /// The filter's power gain at each third-octave band centre.
    static let weights: [Float] = ThirdOctaveBands.centerFrequencies.map { Float(powerGain(hz: $0)) }

    static func db(bands: [Float]) -> Float {
        dB(zip(bands, weights).reduce(0) { $0 + $1.0 * $1.1 }, floor: Payload.floorDB)
    }

    private static func powerGain(hz: Double) -> Double {
        let w = 2 * Double.pi * hz / Double(HistoryRing.sampleRate)
        return stages.reduce(1) { gain, c in
            // |b0 + b1 z^-1 + b2 z^-2|^2 / |1 + a1 z^-1 + a2 z^-2|^2 at z = e^jw.
            func squared(_ x0: Double, _ x1: Double, _ x2: Double) -> Double {
                let re = x0 + x1 * cos(w) + x2 * cos(2 * w)
                let im = x1 * sin(w) + x2 * sin(2 * w)
                return re * re + im * im
            }
            return gain * squared(c[0], c[1], c[2]) / squared(1, c[3], c[4])
        }
    }
}
