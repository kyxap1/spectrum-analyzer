import Foundation

struct LevelReading: Equatable {
    let rmsDBFS: Float
    let peakDBFS: Float
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
