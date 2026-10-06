import Foundation

struct LevelReading: Equatable {
    let rmsDBFS: Float
    let peakDBFS: Float

    /// What the meter shows: RMS rises at once and falls at a limited rate;
    /// the peak is held, never falling, until the player clears it.
    func shown(after previous: LevelReading?, seconds: Double) -> LevelReading {
        guard let previous else { return self }
        return LevelReading(rmsDBFS: Self.fall(rmsDBFS, from: previous.rmsDBFS, rate: 24, seconds: seconds),
                            peakDBFS: max(peakDBFS, previous.peakDBFS))
    }

    private static let floorDBFS: Float = -120

    private static func fall(_ new: Float, from previous: Float, rate: Float, seconds: Double) -> Float {
        guard previous.isFinite else { return new }
        let released = previous - rate * Float(seconds)
        let shown = max(new, released)
        return shown < floorDBFS ? -.infinity : shown
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
