import Foundation

/// KTD5: the 10 standard octave bands, which are the EQ2 factory bands. Each
/// is the power sum of the third-octave band at its centre and the two next to
/// it, one octave in all.
enum OctaveBands {
    static let centerFrequencies: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    static let thirdOctaveIndices: [ClosedRange<Int>] = centerFrequencies.map { centre in
        let i = ThirdOctaveBands.centerFrequencies.firstIndex(of: centre)!
        return (i - 1)...(i + 1)
    }

    static func power(fromBands bands: [Float]) -> [Float] {
        thirdOctaveIndices.map { group in group.reduce(0) { $0 + bands[$1] } }
    }
}

/// KTD7: the guitar's level and band powers averaged over the last N active
/// seconds before Set reference, with the mix's when it had active hops. Band
/// powers only, never audio. Lives outside `Session` and the logs, so Reset
/// never touches it.
///
/// KTD12: snapshots saved before average peak and crest existed decode with
/// them nil, and the held peak they stored is ignored. Loudness is never
/// stored; it comes from `guitarBands` (KTD1).
struct Reference: Codable, Equatable {
    var name: String?
    let windowSeconds: Int
    let activeSeconds: Double
    let guitarLevelDBFS: Float
    let guitarBands: [Float]
    let guitarDisplay: [Float]
    let mixLevelDBFS: Float?
    let mixBands: [Float]?
    var guitarAveragePeakDBFS: Float?
    var guitarCrestDB: Float?
    var guitarOctaveCrestDB: [Float]?

    /// Nil when the guitar window holds no active hop.
    static func make(guitar: ActiveWindow, mix: ActiveWindow, windowSeconds: Int, name: String? = nil) -> Reference? {
        guard !guitar.hops.isEmpty else { return nil }
        let mixActive = !mix.hops.isEmpty
        let averagePeak = guitar.averagePeakDBFS.flatMap { $0.isFinite ? $0 : nil }
        return Reference(name: name,
                         windowSeconds: windowSeconds,
                         activeSeconds: guitar.activeSeconds,
                         guitarLevelDBFS: guitar.levelDBFS,
                         guitarBands: guitar.bandPower,
                         guitarDisplay: guitar.displayPower,
                         mixLevelDBFS: mixActive ? mix.levelDBFS : nil,
                         mixBands: mixActive ? mix.bandPower : nil,
                         guitarAveragePeakDBFS: averagePeak,
                         guitarCrestDB: averagePeak == nil ? nil : guitar.crestDB,
                         guitarOctaveCrestDB: guitar.octaveCrestDB)
    }
}

/// The live guitar against a reference over the same kind of window (R8),
/// live minus reference throughout. The differences are nil until the window
/// holds an active hop, so a fresh press reads as dashes rather than 0 dB; the
/// crest and average-peak ones also stay nil for a reference without them.
struct Comparison: Equatable {
    let partial: Bool
    let windowHops: Int
    let activeSeconds: Double
    /// The window's newest hop, so the verdict advances once per hop (KTD5).
    let lastHopSequence: Int?
    /// Flat RMS level, for Details.
    let levelDifferenceDB: Float?
    /// K-weighted (KTD1); the unity figure.
    let loudnessDifferenceDB: Float?
    let averagePeakDifferenceDB: Float?
    /// Negative reads "squashed" (KTD3).
    let crestDifferenceDB: Float?
    let octaveCrestDifferencesDB: [Float]?
    /// Level-matched: each octave's difference minus the loudness difference (KTD4).
    let octaveDifferencesDB: [Float]?
    /// Absolute, for Details.
    let bandDifferencesDB: [Float]?
    /// Per active hop, oldest first, for the spread the export reports (KTD4).
    let hopLoudnessDifferencesDB: [Float]
    let hopToneDifferencesDB: [[Float]]
    let hopCrestDifferencesDB: [Float]

    static func make(reference: Reference, window: ActiveWindow, windowHops: Int) -> Comparison {
        let partial = window.hops.count < windowHops
        guard !window.hops.isEmpty else {
            return Comparison(partial: partial, windowHops: windowHops, activeSeconds: 0, lastHopSequence: nil, levelDifferenceDB: nil,
                              loudnessDifferenceDB: nil, averagePeakDifferenceDB: nil, crestDifferenceDB: nil,
                              octaveCrestDifferencesDB: nil, octaveDifferencesDB: nil, bandDifferencesDB: nil,
                              hopLoudnessDifferencesDB: [], hopToneDifferencesDB: [], hopCrestDifferencesDB: [])
        }
        let floor = Payload.floorDB
        let referenceLoudness = Loudness.db(bands: reference.guitarBands)
        let referenceOctaves = OctaveBands.power(fromBands: reference.guitarBands).map { dB($0, floor: floor) }
        // Each octave's difference minus the loudness difference of the same bands.
        func tone(_ bands: [Float]) -> (loudness: Float, octaves: [Float]) {
            let loudness = Loudness.db(bands: bands) - referenceLoudness
            let octaves = zip(OctaveBands.power(fromBands: bands), referenceOctaves).map { dB($0, floor: floor) - $1 - loudness }
            return (loudness, octaves)
        }
        let live = tone(window.bandPower)
        let hops = window.hops.map { tone($0.bands) }
        let averagePeak = zip2(window.averagePeakDBFS, reference.guitarAveragePeakDBFS).map { $0 - $1 }
        let crest = zip2(window.crestDB, reference.guitarCrestDB).map { $0 - $1 }
        let octaveCrest = window.octaveCrestDB.flatMap { live in
            reference.guitarOctaveCrestDB.map { zip(live, $0).map { $0 - $1 } }
        }
        return Comparison(
            partial: partial,
            windowHops: windowHops,
            activeSeconds: window.activeSeconds,
            lastHopSequence: window.hops.last?.sequence,
            levelDifferenceDB: window.levelDBFS - reference.guitarLevelDBFS,
            loudnessDifferenceDB: live.loudness,
            averagePeakDifferenceDB: averagePeak,
            crestDifferenceDB: crest,
            octaveCrestDifferencesDB: octaveCrest,
            octaveDifferencesDB: live.octaves,
            bandDifferencesDB: zip(window.bandPower, reference.guitarBands).map { dB($0, floor: floor) - dB($1, floor: floor) },
            hopLoudnessDifferencesDB: hops.map(\.loudness),
            hopToneDifferencesDB: hops.map(\.octaves),
            hopCrestDifferencesDB: reference.guitarCrestDB.map { referenceCrest in
                window.hops.map { $0.peakDBFS - $0.rmsDBFS - referenceCrest }
            } ?? [])
    }
}

private func zip2(_ a: Float?, _ b: Float?) -> (Float, Float)? {
    guard let a, let b, a.isFinite, b.isFinite else { return nil }
    return (a, b)
}
