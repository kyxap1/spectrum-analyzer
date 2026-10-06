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
    /// Threshold until the player learns one for a source.
    static let defaultThresholdDBFS: Float = -60
    static let floorDB: Float = -100

    /// Averages third-octave band power over `ring`'s whole kept history at
    /// the KTD14 hop, skipping hops whose RMS is below `thresholdDBFS`, so
    /// pauses and a disconnected interface do not drag it down.
    static func analyze(ring: HistoryRing, thresholdDBFS: Float) -> SourceBands {
        let hopFrames = max(1, Int(hopSeconds * Double(HistoryRing.sampleRate)))
        let range = ring.range
        var sum = [Float](repeating: 0, count: ThirdOctaveBands.centerFrequencies.count)
        var included = 0

        var frame = range.lowerBound + hopFrames
        while frame <= range.upperBound {
            defer { frame += hopFrames }
            let interleaved = ring.read(from: frame - SpectrumAnalyzer.fftSize, count: SpectrumAnalyzer.fftSize)
            guard rmsDBFS(interleaved: interleaved) >= thresholdDBFS else { continue }
            let (power, binHz) = fftPowerSpectrum(interleaved: interleaved, fftSize: SpectrumAnalyzer.fftSize)
            let bands = ThirdOctaveBands.aggregate(power: power, binHz: binHz)
            for i in 0..<sum.count { sum[i] += bands[i] }
            included += 1
        }

        guard included > 0 else { return SourceBands(power: sum, analyzedSeconds: 0) }
        for i in 0..<sum.count { sum[i] /= Float(included) }
        return SourceBands(power: sum, analyzedSeconds: Double(included) * hopSeconds)
    }

    /// Renders the instruction, the band table, the rig text, the current rig
    /// state, the starting positions and the previous round, if any.
    static func render(mix: SourceBands, guitar: SourceBands?, rig: RigText,
                       instruction: String = AdviceSettings.defaultPrompt, rigState: String? = nil,
                       startingPositions: String? = nil, previous: AdviceRound? = nil) -> String {
        var lines = [instruction, "", bandTable(mix: mix, guitar: guitar), ""]
        if let cachedAt = rig.cachedAt {
            lines.append("Rig (cached copy from \(DateFormatter.rigCache.string(from: cachedAt))):")
        } else {
            lines.append("Rig:")
        }
        lines.append(rig.markdown)
        if let rigState {
            lines.append("")
            lines.append(rigState)
        }
        if let startingPositions, !startingPositions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("Starting positions:")
            lines.append(startingPositions)
        }
        if let previous {
            lines.append("")
            lines.append("Previous round (\(DateFormatter.round.string(from: previous.date))), measured before its recommendation was applied:")
            lines.append(previous.bands)
            lines.append("")
            lines.append("Previous recommendation:")
            lines.append(previous.answer)
        }
        return lines.joined(separator: "\n")
    }

    /// The analyzed durations and band rows; `guitar` is omitted when nothing
    /// was captured.
    static func bandTable(mix: SourceBands, guitar: SourceBands?) -> String {
        var lines = ["Mix analyzed: \(Int(mix.analyzedSeconds)) s"]
        if let guitar, guitar.analyzedSeconds > 0 {
            lines.append("Guitar analyzed: \(Int(guitar.analyzedSeconds)) s")
            lines.append("")
            lines.append("Band (Hz)\tMix (dB)\tGuitar (dB)\tGuitar - Mix (dB)")
            for i in ThirdOctaveBands.centerFrequencies.indices {
                let mixDB = dB(mix.power[i], floor: floorDB)
                let guitarDB = dB(guitar.power[i], floor: floorDB)
                lines.append("\(formatHz(i))\t\(format(mixDB))\t\(format(guitarDB))\t\(format(guitarDB - mixDB))")
            }
        } else {
            lines.append("Guitar was not captured.")
            lines.append("")
            lines.append("Band (Hz)\tMix (dB)")
            for i in ThirdOctaveBands.centerFrequencies.indices {
                lines.append("\(formatHz(i))\t\(format(dB(mix.power[i], floor: floorDB)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// RMS in dBFS of an already-read interleaved window.
    static func rmsDBFS(interleaved: [Int16]) -> Float {
        var sumSquares: Float = 0
        for sample in interleaved {
            let normalized = Float(sample) / 32768
            sumSquares += normalized * normalized
        }
        let rms = (sumSquares / Float(interleaved.count)).squareRoot()
        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }

    private static func format(_ db: Float) -> String {
        String(format: "%.1f", db)
    }

    private static func formatHz(_ index: Int) -> String {
        let hz = ThirdOctaveBands.centerFrequencies[index]
        return hz == hz.rounded() ? "\(Int(hz))" : String(format: "%g", hz)
    }
}

/// The last successful request's band table and answer. Its answer ends with
/// the settings snapshot the next request starts from, so one round is enough.
struct AdviceRound: Codable, Equatable {
    let date: Date
    let bands: String
    let answer: String
}

private extension DateFormatter {
    static let rigCache: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    static let round: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
