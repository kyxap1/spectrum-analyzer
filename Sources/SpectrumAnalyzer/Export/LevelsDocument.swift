import Foundation

/// One source's log with the settings that gate it and its live meter.
struct ExportSource {
    let log: BandLog
    let thresholdDBFS: Float
    let reading: LevelReading?
}

/// KTD12: the versioned export document. Built as a JSON object so absent
/// values read as `null` rather than missing keys. A field rename or removal
/// needs a version bump; added fields keep the version.
struct LevelsDocument {
    static let format = "spectrum-analyzer.levels"
    static let version = 1

    let object: [String: Any]

    func encoded() -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func make(state: SessionState, windowSeconds: Int, guitar: ExportSource?, mix: ExportSource,
                     reference: Reference?, comparison: Comparison?, now: Date) -> LevelsDocument {
        let limit = Int(Double(windowSeconds) / Payload.hopSeconds)
        let guitarWindow = guitar.map { $0.log.window(threshold: $0.thresholdDBFS, limit: limit) }
        let mixWindow = mix.log.window(threshold: mix.thresholdDBFS, limit: limit)

        var object: [String: Any] = [
            "format": format,
            "version": version,
            "timestamp": ISO8601DateFormatter().string(from: now),
            "state": name(of: state),
            "windowSeconds": windowSeconds,
            "units": ["level": "dBFS", "band": "dB re full scale, power summed per band"],
            "bands": ["centersHz": ThirdOctaveBands.centerFrequencies, "octaveCentersHz": OctaveBands.centerFrequencies],
            "mix": section(mix, window: mixWindow),
        ]
        object["guitar"] = guitar.flatMap { source in guitarWindow.map { section(source, window: $0) } } ?? NSNull()
        object["difference"] = guitar.flatMap { source in
            guitarWindow.flatMap { pairedDifferenceDB(guitarHops: $0.hops, mixHops: mix.log.hops) }
                .map { ["bandsDB": $0.map(round)] }
        } ?? NSNull()
        object["reference"] = reference.map { referenceSection($0, comparison: comparison) } ?? NSNull()
        return LevelsDocument(object: object)
    }

    /// Guitar minus mix per third-octave band over the moments both were
    /// captured: each active guitar hop pairs with the mix hop ending on the
    /// same frame, and guitar hops with no such mix hop are skipped. Nil when
    /// nothing pairs.
    static func pairedDifferenceDB(guitarHops: [LogHop], mixHops: [LogHop]) -> [Float]? {
        let mixByFrame = Dictionary(mixHops.map { ($0.endFrame, $0) }, uniquingKeysWith: { first, _ in first })
        let pairs = guitarHops.compactMap { hop in mixByFrame[hop.endFrame].map { (hop, $0) } }
        guard !pairs.isEmpty else { return nil }
        let guitar = BandLog.average(pairs.map(\.0)).bandPower
        let mix = BandLog.average(pairs.map(\.1)).bandPower
        return zip(guitar, mix).map { dB($0, floor: Payload.floorDB) - dB($1, floor: Payload.floorDB) }
    }

    private static func section(_ source: ExportSource, window: ActiveWindow) -> [String: Any] {
        let newest = window.hops.last.map { Double(source.log.position - $0.endFrame) / Double(HistoryRing.sampleRate) }
        return [
            "thresholdDBFS": round(source.thresholdDBFS),
            "activeSeconds": window.activeSeconds,
            "activeHopsTotal": source.log.activeCount(threshold: source.thresholdDBFS),
            "newestActiveAgeSeconds": newest.map { round(Float($0)) } ?? NSNull(),
            "rmsDBFS": source.reading.map { round($0.rmsDBFS) } ?? NSNull(),
            "peakDBFS": source.reading.map { round($0.peakDBFS) } ?? NSNull(),
            "bandsDB": window.bandPower.map { round(dB($0, floor: Payload.floorDB)) },
        ]
    }

    private static func referenceSection(_ reference: Reference, comparison: Comparison?) -> [String: Any] {
        var differences: Any = NSNull()
        if let comparison, let level = comparison.levelDifferenceDB,
           let octaves = comparison.octaveDifferencesDB, let bands = comparison.bandDifferencesDB {
            differences = ["levelDB": round(level), "octaveBandsDB": octaves.map(round), "bandsDB": bands.map(round)]
        }
        return [
            "name": reference.name ?? NSNull(),
            "windowSeconds": reference.windowSeconds,
            "activeSeconds": reference.activeSeconds,
            "partial": comparison?.partial ?? true,
            "levelDBFS": round(reference.guitarLevelDBFS),
            "bandsDB": reference.guitarBands.map { round(dB($0, floor: Payload.floorDB)) },
            "octaveBandsDB": OctaveBands.power(fromBands: reference.guitarBands).map { round(dB($0, floor: Payload.floorDB)) },
            "differences": differences,
        ]
    }

    private static func name(of state: SessionState) -> String {
        switch state {
        case .live: "live"
        case .paused: "paused"
        case .replaying: "replaying"
        }
    }

    /// Two decimals, and `null` for the infinities JSON cannot hold.
    private static func round(_ value: Float) -> Any {
        value.isFinite ? (Double(value) * 100).rounded() / 100 : NSNull()
    }
}
