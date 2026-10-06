import Foundation

/// Maps host time in seconds to history frames: elapsed time minus time spent
/// paused, at the fixed history rate.
struct HistoryClock {
    private var start: Double
    private var paused: Double = 0
    private var pausedSince: Double?

    init(start: Double) {
        self.start = start
    }

    var isPaused: Bool { pausedSince != nil }

    mutating func pause(at hostTime: Double) {
        guard pausedSince == nil else { return }
        pausedSince = hostTime
    }

    mutating func resume(at hostTime: Double) {
        guard let pausedSince else { return }
        paused += hostTime - pausedSince
        self.pausedSince = nil
    }

    mutating func reset(start: Double) {
        self.start = start
        paused = 0
        pausedSince = nil
    }

    func frame(at hostTime: Double) -> Int {
        let now = min(hostTime, pausedSince ?? hostTime)
        return Int((now - start - paused) * Double(HistoryRing.sampleRate))
    }
}
