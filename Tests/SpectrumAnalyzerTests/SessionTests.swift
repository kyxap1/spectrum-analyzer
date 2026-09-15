import Testing
@testable import SpectrumAnalyzer

/// Drives `Session` without a real audio engine: `play`/`stop` just record
/// calls, `position` and end-of-history are set directly by the test.
@MainActor
private final class FakePlayer: ReplayPlayer {
    var position = 0
    var onReachedEnd: (() -> Void)?
    private(set) var playCalls: [(from: Int, until: Int)] = []
    private(set) var stopCount = 0

    func play(from frame: Int, until head: Int) {
        playCalls.append((frame, head))
        position = frame
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private func makeSession(startTime: Double = 0) -> (Session, FakePlayer, mix: HistoryRing, guitar: HistoryRing, time: TimeBox) {
    let mix = HistoryRing(capacity: 10 * HistoryRing.sampleRate)
    let guitar = HistoryRing(capacity: 10 * HistoryRing.sampleRate)
    let player = FakePlayer()
    let time = TimeBox(startTime)
    let session = Session(mixRing: mix, guitarRing: guitar, player: player, now: { time.value })
    return (session, player, mix, guitar, time)
}

/// A mutable box so tests can advance the injected clock deterministically.
@MainActor
private final class TimeBox {
    var value: Double
    init(_ value: Double) { self.value = value }
}

@Suite("Session")
struct SessionTests {
    @Test("F1: pause, play from scrub point, pause, resume live from Paused")
    @MainActor
    func f1PauseReplayPauseResumeFromPaused() {
        let (session, player, mix, _, time) = makeSession()
        mix.write(at: 0, [Int16](repeating: 1, count: 100 * HistoryRing.channels))
        time.value = 2

        session.pause()
        #expect(session.state == .paused)
        #expect(session.scrubPosition == 2 * HistoryRing.sampleRate)

        session.scrub(to: 50)
        session.play()
        #expect(session.state == .replaying)
        #expect(player.playCalls.last?.from == 50)
        #expect(player.playCalls.last?.until == mix.head)

        session.pause()
        #expect(session.state == .paused)
        #expect(player.stopCount == 1)

        session.resumeLive()
        #expect(session.state == .live)
    }

    @Test("F1: resume live directly from Replaying")
    @MainActor
    func resumeLiveFromReplaying() {
        let (session, player, _, _, _) = makeSession()
        session.pause()
        session.play()
        #expect(session.state == .replaying)

        session.resumeLive()
        #expect(session.state == .live)
        #expect(player.stopCount == 1)
    }

    @Test("play is ignored while Live")
    @MainActor
    func playIgnoredWhileLive() {
        let (session, player, _, _, _) = makeSession()
        #expect(session.state == .live)
        session.play()
        #expect(session.state == .live)
        #expect(player.playCalls.isEmpty)
    }

    @Test("covers AE3: replaying does not move the history head, and resuming live continues from the paused clock")
    @MainActor
    func replayDoesNotAdvanceHistoryAndClockExcludesPause() {
        let (session, _, mix, _, time) = makeSession()
        time.value = 30
        session.pause() // scrub position = 30s live
        #expect(session.isLive == false)

        session.play()
        let headBefore = mix.head
        time.value = 35 // 5 s of "replay" elapsed
        #expect(mix.head == headBefore) // nothing writes to history while not Live
        #expect(session.isLive == false)

        session.resumeLive()
        // 30 s live, then paused from t=30 to t=35 (5 s), so the clock should
        // read 30 s again right after resuming, excluding the paused interval.
        #expect(session.currentHead == 30 * HistoryRing.sampleRate)
    }

    @Test("scrubbing while Paused moves the head; scrubbing while Replaying seeks the player")
    @MainActor
    func scrubBehaviorDependsOnState() {
        let (session, player, mix, _, _) = makeSession()
        session.pause()
        session.scrub(to: 123)
        #expect(session.currentHead == 123)
        #expect(player.playCalls.isEmpty)

        session.play()
        session.scrub(to: 456)
        #expect(player.playCalls.last?.from == 456)
        #expect(player.playCalls.last?.until == mix.head)
    }

    @Test("replay reaching the history head switches to Paused at the end")
    @MainActor
    func reachingEndOfHistorySwitchesToPaused() {
        let (session, player, mix, _, _) = makeSession()
        mix.write(at: 0, [Int16](repeating: 1, count: 100 * HistoryRing.channels))
        session.pause()
        session.play()
        #expect(session.state == .replaying)

        player.onReachedEnd?()

        #expect(session.state == .paused)
        #expect(session.scrubPosition == mix.head)
    }

    @Test("covers AE5: Reset during replay stops the player, empties history, and leaves the session Live")
    @MainActor
    func resetDuringReplay() {
        let (session, player, mix, guitar, _) = makeSession()
        mix.write(at: 0, [Int16](repeating: 1, count: HistoryRing.sampleRate * HistoryRing.channels))
        session.pause()
        session.play()

        session.reset()

        #expect(session.state == .live)
        #expect(player.stopCount >= 1)
        #expect(mix.head == 0)
        #expect(mix.range.isEmpty)
        #expect(guitar.head == 0)
        #expect(session.scrubPosition == 0)
    }

    @Test("the player's position is the start frame plus rendered frames")
    func playerPositionIsStartPlusRendered() {
        #expect(Player.computePosition(startFrame: 1_000, renderedFrames: 0) == 1_000)
        #expect(Player.computePosition(startFrame: 1_000, renderedFrames: 4_800) == 5_800)
        #expect(Player.computePosition(startFrame: 0, renderedFrames: 48_000) == 48_000)
    }
}
