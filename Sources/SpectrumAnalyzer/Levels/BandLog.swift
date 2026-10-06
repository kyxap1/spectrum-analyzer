import Foundation

/// One half-second measurement of a source: the 8192-frame window ending at
/// `endFrame`, which is always a multiple of the hop length so two sources'
/// hops at the same frame are the same moment.
struct LogHop {
    let sequence: Int
    let endFrame: Int
    let rmsDBFS: Float
    /// Power per third-octave band (31) and per display point (240).
    let bands: [Float]
    let display: [Float]
}

/// The newest active hops of a log, averaged in power.
struct ActiveWindow {
    let hops: [LogHop]
    let bandPower: [Float]
    let displayPower: [Float]
    /// Mean RMS power of the hops, in dBFS; `-infinity` when there are none.
    let levelDBFS: Float

    var activeSeconds: Double { Double(hops.count) * Payload.hopSeconds }
}

enum NoiseResult: Equatable {
    case learned(Float)
    /// Every hop was digital silence, so the threshold keeps its value.
    case silent
    case refused(String)
}

/// KTD2/KTD3/KTD4: half-second level and band measurements of one ring, kept
/// for the ring's 10 minutes and gated by a threshold only when read. Holds no
/// reference to `Session`; the caller advances it while Live.
final class BandLog {
    static let capacity = 1_200
    static let hopFrames = max(1, Int(Payload.hopSeconds * Double(HistoryRing.sampleRate)))
    static let noiseHops = 6
    static let noiseMarginDB: Float = 10

    private(set) var hops: [LogHop] = []
    /// Numbers the next appended hop; never goes back, not even on Reset.
    private(set) var nextSequence = 0
    private var lastFrame = 0
    private var contiguousHops = 0

    /// Appends the hops between the log's position and `head`'s hop boundary.
    /// A head more than two hops ahead means the source started or came back
    /// after an idle spell: jump to it rather than back-filling.
    func advance(ring: HistoryRing, to head: Int) {
        let target = head / Self.hopFrames * Self.hopFrames
        if target - lastFrame > 2 * Self.hopFrames {
            lastFrame = target - Self.hopFrames
            contiguousHops = 0
        }
        while lastFrame + Self.hopFrames <= target {
            lastFrame += Self.hopFrames
            append(ring: ring, endFrame: lastFrame)
        }
    }

    func reset() {
        hops.removeAll(keepingCapacity: true)
        lastFrame = 0
        contiguousHops = 0
    }

    /// Called on return to Live, so Learn noise never reaches back over a pause.
    func markBreak() {
        contiguousHops = 0
    }

    /// The newest `limit` hops at or above `threshold`, optionally only those
    /// logged at or after sequence `since`.
    func window(threshold: Float, limit: Int, since: Int = 0) -> ActiveWindow {
        var picked: [LogHop] = []
        for hop in hops.reversed() {
            if hop.sequence < since { break }
            if hop.rmsDBFS >= threshold {
                picked.append(hop)
                if picked.count == limit { break }
            }
        }
        picked.reverse()
        return Self.average(picked)
    }

    /// Active hops since the last Reset, for the export's turnover marker.
    func activeCount(threshold: Float) -> Int {
        hops.reduce(0) { $0 + ($1.rmsDBFS >= threshold ? 1 : 0) }
    }

    /// Mean power of the last 3 s, active or not, plus the margin.
    func learnNoise(isLive: Bool) -> NoiseResult {
        guard isLive else { return .refused("Learn noise works only while Live.") }
        guard contiguousHops >= Self.noiseHops else {
            return .refused("Wait \(Double(Self.noiseHops) * Payload.hopSeconds) s of live audio before Learn noise.")
        }
        let power = hops.suffix(Self.noiseHops).reduce(Float(0)) { $0 + Self.power(fromDBFS: $1.rmsDBFS) } / Float(Self.noiseHops)
        guard power > 0 else { return .silent }
        return .learned(10 * log10(power) + Self.noiseMarginDB)
    }

    static func average(_ hops: [LogHop]) -> ActiveWindow {
        let bandCount = ThirdOctaveBands.centerFrequencies.count
        var bands = [Float](repeating: 0, count: bandCount)
        var display = [Float](repeating: 0, count: SpectrumAnalyzer.displayPointCount)
        var level: Float = 0
        for hop in hops {
            for i in 0..<bandCount { bands[i] += hop.bands[i] }
            for i in 0..<display.count { display[i] += hop.display[i] }
            level += power(fromDBFS: hop.rmsDBFS)
        }
        guard !hops.isEmpty else {
            return ActiveWindow(hops: [], bandPower: bands, displayPower: display, levelDBFS: -.infinity)
        }
        let n = Float(hops.count)
        return ActiveWindow(hops: hops,
                            bandPower: bands.map { $0 / n },
                            displayPower: display.map { $0 / n },
                            levelDBFS: level > 0 ? 10 * log10(level / n) : -.infinity)
    }

    private func append(ring: HistoryRing, endFrame: Int) {
        let interleaved = ring.read(from: endFrame - SpectrumAnalyzer.fftSize, count: SpectrumAnalyzer.fftSize)
        let (power, binHz) = fftPowerSpectrum(interleaved: interleaved, fftSize: SpectrumAnalyzer.fftSize)
        hops.append(LogHop(sequence: nextSequence,
                           endFrame: endFrame,
                           rmsDBFS: Payload.rmsDBFS(interleaved: interleaved),
                           bands: ThirdOctaveBands.aggregate(power: power, binHz: binHz),
                           display: SpectrumAnalyzer.mapToDisplayPoints(magnitudes: power, binHz: binHz)))
        nextSequence += 1
        contiguousHops += 1
        if hops.count > Self.capacity { hops.removeFirst(hops.count - Self.capacity) }
    }

    private static func power(fromDBFS db: Float) -> Float {
        db.isFinite ? pow(10, db / 10) : 0
    }
}
