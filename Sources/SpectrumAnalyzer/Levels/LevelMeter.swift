import Foundation

/// The unsmoothed reading the export and the clip warning use.
struct LevelReading: Equatable {
    let rmsDBFS: Float
    let peakDBFS: Float
}

/// What a meter draws, as in Friture's level meter.
struct MeterDisplay: Equatable {
    let rmsDBFS: Float
    let peakDBFS: Float
    /// The held peak marker, on the IEC 60268-18 scale.
    let heldPeakIEC: Float
}

/// Friture's level meter ballistics, fed the frames since the previous call:
/// RMS smoothed in power with a 300 ms response, a peak that follows a rise at
/// once and releases with a 25 ms response, and a marker that holds the top
/// for 3 s, as the graphs' peaks do, then falls ever faster.
struct MeterBallistics {
    static let rmsResponseSeconds = 0.3
    static let peakResponseSeconds = 0.025
    static let holdSeconds = 3.0
    /// Friture: the samples within one response time carry 65% of the output.
    private static let weight = 0.65
    private static let initialDecay = 1 - 3e-6 / 500
    /// Smoothing only approaches zero; below this, silence reads minus infinity.
    private static let floorDBFS: Float = -120

    private var power = 0.0
    private var peak = 0.0
    private var held: Float = 0
    private var holdAge = 0.0
    private var decay = initialDecay

    /// `seconds` is the time since the previous call.
    mutating func update(interleaved: [Int16], seconds: Double) -> MeterDisplay {
        let n = Self.rmsResponseSeconds * Double(HistoryRing.sampleRate)
        let keep = pow(1 - Self.weight, 1 / (n + 1))
        var blockMax = 0.0
        for frame in stride(from: 0, to: interleaved.count - 1, by: HistoryRing.channels) {
            let left = Double(interleaved[frame]) / 32768
            let right = Double(interleaved[frame + 1]) / 32768
            power = keep * power + (1 - keep) * (left * left + right * right) / 2
            blockMax = max(blockMax, abs(left), abs(right))
        }
        if !interleaved.isEmpty {
            let release = pow(1 - Self.weight, 1 / (Self.peakResponseSeconds / seconds + 1))
            peak = blockMax > peak * release ? blockMax : peak * release
        }
        var rmsDBFS = power > 0 ? Float(10 * log10(power)) : -.infinity
        var peakDBFS = peak > 0 ? Float(20 * log10(peak)) : -.infinity
        if rmsDBFS < Self.floorDBFS { (power, rmsDBFS) = (0, -.infinity) }
        if peakDBFS < Self.floorDBFS { (peak, peakDBFS) = (0, -.infinity) }
        let level = Self.iec(max(rmsDBFS, peakDBFS))
        if level > held {
            follow(level)
        } else if holdAge + seconds <= Self.holdSeconds + 1e-6 {
            holdAge += seconds
        } else if Float(decay) * held < level {
            follow(level)
        } else {
            held *= Float(decay)
            decay *= decay
        }
        return MeterDisplay(rmsDBFS: rmsDBFS, peakDBFS: peakDBFS, heldPeakIEC: held)
    }

    private mutating func follow(_ level: Float) {
        held = level
        holdAge = 0
        decay = Self.initialDecay
    }

    /// IEC 60268-18 meter deflection, 0 at -70 dB and below, 1 at 0 dB.
    static func iec(_ dB: Float) -> Float {
        switch dB {
        case ..<(-70): 0
        case ..<(-60): (dB + 70) * 0.0025
        case ..<(-50): (dB + 60) * 0.005 + 0.025
        case ..<(-40): (dB + 50) * 0.0075 + 0.075
        case ..<(-30): (dB + 40) * 0.015 + 0.15
        case ..<(-20): (dB + 30) * 0.02 + 0.3
        default: min((dB + 20) * 0.025 + 0.5, 1)
        }
    }
}

/// KTD6: RMS over the last 300 ms and peak over the last 1 s of a ring at a
/// head, both in dBFS. Frames before 0 read back as silence.
enum LevelMeter {
    static let rmsSeconds = 0.3
    static let peakSeconds = 1.0

    static func read(ring: HistoryRing, head: Int) -> LevelReading {
        let peakFrames = Int(peakSeconds * Double(HistoryRing.sampleRate))
        let rmsFrames = Int(rmsSeconds * Double(HistoryRing.sampleRate))
        let samples = ring.read(from: head - peakFrames, count: peakFrames)
        let peak = samples.reduce(0) { max($0, abs(Int($1))) }
        let recent = Array(samples.suffix(rmsFrames * HistoryRing.channels))
        return LevelReading(rmsDBFS: Payload.rmsDBFS(interleaved: recent),
                            peakDBFS: peak > 0 ? 20 * log10(Float(peak) / 32768) : -.infinity)
    }

    /// One decimal place, with a true minus sign and infinity for silence.
    static func format(_ dBFS: Float) -> String {
        dBFS.isFinite ? String(format: "%.1f", dBFS) : "\u{2212}\u{221E}"
    }
}
