import Foundation

/// Third-octave band power averaged over some span of kept history, and how
/// much of that span actually went into the average.
struct SourceBands {
    let power: [Float]
    let analyzedSeconds: Double
}

/// KTD14: builds the AI request text from third-octave averages over the
/// whole kept history, not the display curve. Pure logic over the rings, so
/// it needs no audio hardware to test.
enum Payload {
    /// One FFT every 0.5 s (KTD14) -- reuses `SpectrumAnalyzer`'s warm-up hop,
    /// which is the same coarse cadence.
    static let hopSeconds = SpectrumAnalyzer.warmHopSeconds
    /// Frames quieter than this RMS floor are left out of the average, so
    /// pauses and a disconnected interface do not drag it down.
    static let silenceFloorDBFS: Float = -70
    static let floorDB: Float = -100

    private static let instruction = """
    You are a guitar-tone assistant. Below are third-octave band levels (dB) \
    averaged over the analyzed window: the mix (everything the Mac played), \
    the guitar (the selected interface inputs), and their difference (guitar \
    minus mix). A large negative difference means the guitar is missing where \
    the mix is loud; a large positive difference means the guitar collides \
    with or covers the mix. Using the rig described below, suggest concrete \
    settings changes -- which device and control, and roughly how much -- so \
    the guitar fills the mix's gaps without fighting it.
    """

    /// Averages third-octave band power over `ring`'s whole kept history at
    /// the KTD14 hop, skipping hops whose RMS is below `silenceFloorDBFS`.
    static func analyze(ring: HistoryRing) -> SourceBands {
        let hopFrames = max(1, Int(hopSeconds * Double(HistoryRing.sampleRate)))
        let range = ring.range
        var sum = [Float](repeating: 0, count: ThirdOctaveBands.centerFrequencies.count)
        var included = 0

        var frame = range.lowerBound + hopFrames
        while frame <= range.upperBound {
            defer { frame += hopFrames }
            guard rmsDBFS(ring: ring, endFrame: frame) >= silenceFloorDBFS else { continue }
            let (power, binHz) = fftPowerSpectrum(ring: ring, endFrame: frame, fftSize: SpectrumAnalyzer.fftSize)
            let bands = ThirdOctaveBands.aggregate(power: power, binHz: binHz)
            for i in 0..<sum.count { sum[i] += bands[i] }
            included += 1
        }

        guard included > 0 else { return SourceBands(power: sum, analyzedSeconds: 0) }
        for i in 0..<sum.count { sum[i] /= Float(included) }
        return SourceBands(power: sum, analyzedSeconds: Double(included) * hopSeconds)
    }

    /// Renders the fixed instruction, the band table and the rig text.
    /// `guitar` is omitted from the table when nothing was captured.
    static func render(mix: SourceBands, guitar: SourceBands?, rig: RigText) -> String {
        var lines = [instruction, ""]
        lines.append("Mix analyzed: \(Int(mix.analyzedSeconds)) s")
        if let guitar, guitar.analyzedSeconds > 0 {
            lines.append("Guitar analyzed: \(Int(guitar.analyzedSeconds)) s")
            lines.append("")
            lines.append("Band (Hz)\tMix (dB)\tGuitar (dB)\tGuitar - Mix (dB)")
            for i in ThirdOctaveBands.centerFrequencies.indices {
                let mixDB = dB(mix.power[i])
                let guitarDB = dB(guitar.power[i])
                lines.append("\(formatHz(i))\t\(format(mixDB))\t\(format(guitarDB))\t\(format(guitarDB - mixDB))")
            }
        } else {
            lines.append("Guitar was not captured.")
            lines.append("")
            lines.append("Band (Hz)\tMix (dB)")
            for i in ThirdOctaveBands.centerFrequencies.indices {
                lines.append("\(formatHz(i))\t\(format(dB(mix.power[i])))")
            }
        }
        lines.append("")
        if let cachedAt = rig.cachedAt {
            lines.append("Rig (cached copy from \(DateFormatter.rigCache.string(from: cachedAt))):")
        } else {
            lines.append("Rig:")
        }
        lines.append(rig.markdown)
        return lines.joined(separator: "\n")
    }

    /// RMS in dBFS over the same window `fftPowerSpectrum` would analyze at
    /// `endFrame`, used only to decide whether the hop is silent.
    private static func rmsDBFS(ring: HistoryRing, endFrame: Int) -> Float {
        let n = SpectrumAnalyzer.fftSize
        let interleaved = ring.read(from: endFrame - n, count: n)
        var sumSquares: Float = 0
        for sample in interleaved {
            let normalized = Float(sample) / 32768
            sumSquares += normalized * normalized
        }
        let rms = (sumSquares / Float(interleaved.count)).squareRoot()
        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }

    private static func dB(_ power: Float) -> Float {
        power > 0 ? max(10 * log10(power), floorDB) : floorDB
    }

    private static func format(_ db: Float) -> String {
        String(format: "%.1f", db)
    }

    private static func formatHz(_ index: Int) -> String {
        let hz = ThirdOctaveBands.centerFrequencies[index]
        return hz == hz.rounded() ? "\(Int(hz))" : String(format: "%g", hz)
    }
}

private extension DateFormatter {
    static let rigCache: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()
}
