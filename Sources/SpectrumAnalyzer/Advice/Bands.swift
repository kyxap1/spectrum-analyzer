import Foundation

/// The 31 ISO preferred third-octave center frequencies from 20 Hz to 20 kHz
/// that the AI payload reports power over (KTD14).
enum ThirdOctaveBands {
    static let centerFrequencies: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160,
        200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
        2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
    ]

    /// Sums `power` (FFT bins spaced `binHz` apart, as returned by
    /// `fftPowerSpectrum`) into each third-octave band.
    static func aggregate(power: [Float], binHz: Double) -> [Float] {
        let nyquist = Double(HistoryRing.sampleRate) / 2
        return frequencyBuckets(centerFrequencies: centerFrequencies,
                                binHz: binHz,
                                binCount: power.count,
                                nyquist: nyquist)
            .map { power[$0].reduce(0, +) }
    }
}
