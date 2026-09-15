import Foundation

enum SessionState: Equatable {
    case live
    case paused
    case replaying
}

/// The one state machine gating capture writes and driving playback (KTD6).
/// Live, Paused and Replaying follow F1; Reset returns to Live from any state.
@MainActor
final class Session {
    private(set) var state: SessionState = .live
    private(set) var scrubPosition = 0
    var onStateChange: (() -> Void)?

    private let mixRing: HistoryRing
    private let guitarRing: HistoryRing
    private let player: ReplayPlayer
    private let now: () -> Double
    private(set) var clock: HistoryClock

    /// The capture worker writes only while this is true (KTD6).
    var isLive: Bool { state == .live }

    /// The frame that feeds the analyzer: the live edge, the scrub point, or
    /// the player's position, depending on state. Live and replay share the
    /// analyzer path; only this head differs (KTD5, KTD7).
    var currentHead: Int {
        switch state {
        case .live: clock.frame(at: now())
        case .paused: scrubPosition
        case .replaying: player.position
        }
    }

    init(mixRing: HistoryRing,
         guitarRing: HistoryRing,
         player: ReplayPlayer,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.mixRing = mixRing
        self.guitarRing = guitarRing
        self.player = player
        self.now = now
        clock = HistoryClock(start: now())
        player.onReachedEnd = { [weak self] in self?.reachedEndOfHistory() }
    }

    /// Pauses from Live (freezing at the live edge) or from Replaying (freezing
    /// at the playback position). A no-op while already Paused.
    func pause() {
        guard state != .paused else { return }
        if state == .replaying {
            scrubPosition = player.position
            player.stop()
        } else {
            scrubPosition = clock.frame(at: now())
        }
        clock.pause(at: now())
        state = .paused
        onStateChange?()
    }

    /// Starts replay from the scrub point. Ignored while Live or already
    /// Replaying (scrubbing is how a running replay changes position).
    func play() {
        guard state == .paused else { return }
        state = .replaying
        player.play(from: scrubPosition, until: mixRing.head)
        onStateChange?()
    }

    /// Returns to Live from Paused or Replaying, stopping playback first so
    /// writes only resume once nothing is being replayed (KTD6).
    func resumeLive() {
        guard state != .live else { return }
        if state == .replaying { player.stop() }
        clock.resume(at: now())
        state = .live
        onStateChange?()
    }

    /// Moves the analyzer head while Paused, or seeks the running player while
    /// Replaying. Ignored while Live.
    func scrub(to frame: Int) {
        switch state {
        case .live:
            return
        case .paused:
            scrubPosition = frame
        case .replaying:
            scrubPosition = frame
            player.play(from: frame, until: mixRing.head)
        }
        onStateChange?()
    }

    /// Discards both rings' history and returns to Live from any state (R15).
    func reset() {
        if state == .replaying { player.stop() }
        mixRing.reset()
        guitarRing.reset()
        clock.reset(start: now())
        scrubPosition = 0
        state = .live
        onStateChange?()
    }

    private func reachedEndOfHistory() {
        scrubPosition = mixRing.head
        state = .paused
        onStateChange?()
    }
}
