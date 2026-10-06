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
struct Reference: Codable, Equatable {
    var name: String?
    let windowSeconds: Int
    let activeSeconds: Double
    let guitarLevelDBFS: Float
    /// The guitar's held peak when the reference was set, for matching unity by peak.
    var guitarPeakDBFS: Float?
    let guitarBands: [Float]
    let guitarDisplay: [Float]
    let mixLevelDBFS: Float?
    let mixBands: [Float]?

    /// Nil when the guitar window holds no active hop.
    static func make(guitar: ActiveWindow, mix: ActiveWindow, windowSeconds: Int, name: String? = nil,
                     guitarPeakDBFS: Float? = nil) -> Reference? {
        guard !guitar.hops.isEmpty else { return nil }
        let mixActive = !mix.hops.isEmpty
        return Reference(name: name,
                         windowSeconds: windowSeconds,
                         activeSeconds: guitar.activeSeconds,
                         guitarLevelDBFS: guitar.levelDBFS,
                         guitarPeakDBFS: guitarPeakDBFS?.isFinite == true ? guitarPeakDBFS : nil,
                         guitarBands: guitar.bandPower,
                         guitarDisplay: guitar.displayPower,
                         mixLevelDBFS: mixActive ? mix.levelDBFS : nil,
                         mixBands: mixActive ? mix.bandPower : nil)
    }
}

/// The live guitar against a reference over the same kind of window (R8).
/// The differences are nil until the window holds an active hop, so a fresh
/// press reads as dashes rather than 0 dB.
struct Comparison: Equatable {
    let partial: Bool
    let windowHops: Int
    let activeSeconds: Double
    let levelDifferenceDB: Float?
    /// Held live peak minus the reference's peak; nil when either is unknown.
    let peakDifferenceDB: Float?
    let octaveDifferencesDB: [Float]?
    let bandDifferencesDB: [Float]?

    static func make(reference: Reference, window: ActiveWindow, windowHops: Int, livePeakDBFS: Float? = nil) -> Comparison {
        let partial = window.hops.count < windowHops
        let peakDifference = zip2(livePeakDBFS, reference.guitarPeakDBFS).map { $0 - $1 }
        guard !window.hops.isEmpty else {
            return Comparison(partial: partial, windowHops: windowHops, activeSeconds: 0, levelDifferenceDB: nil,
                              peakDifferenceDB: peakDifference, octaveDifferencesDB: nil, bandDifferencesDB: nil)
        }
        let floor = Payload.floorDB
        let liveOctaves = OctaveBands.power(fromBands: window.bandPower)
        let referenceOctaves = OctaveBands.power(fromBands: reference.guitarBands)
        return Comparison(
            partial: partial,
            windowHops: windowHops,
            activeSeconds: window.activeSeconds,
            levelDifferenceDB: window.levelDBFS - reference.guitarLevelDBFS,
            peakDifferenceDB: peakDifference,
            octaveDifferencesDB: zip(liveOctaves, referenceOctaves).map { dB($0, floor: floor) - dB($1, floor: floor) },
            bandDifferencesDB: zip(window.bandPower, reference.guitarBands).map { dB($0, floor: floor) - dB($1, floor: floor) })
    }
}

private func zip2(_ a: Float?, _ b: Float?) -> (Float, Float)? {
    guard let a, let b, a.isFinite, b.isFinite else { return nil }
    return (a, b)
}
