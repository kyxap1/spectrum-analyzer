import AVFoundation

/// What `Session` needs from a replay player. Lets tests substitute a fake
/// instead of driving real `AVAudioEngine` playback.
@MainActor
protocol ReplayPlayer: AnyObject {
    var position: Int { get }
    var onReachedEnd: (() -> Void)? { get set }
    func play(from frame: Int, until head: Int)
    func stop()
}

/// Schedules kept audio from both rings onto two player nodes feeding the main
/// mixer, and reports playback position as an absolute history frame (KTD7).
/// There is no per-source mute: mix and guitar always play together (R11).
final class Player: ReplayPlayer, @unchecked Sendable {
    var onReachedEnd: (() -> Void)?

    private let engine = AVAudioEngine()
    private let mixNode = AVAudioPlayerNode()
    private let guitarNode = AVAudioPlayerNode()
    private let mixRing: HistoryRing
    private let guitarRing: HistoryRing
    private var startFrame = 0
    /// Bumped on every `play`/`stop` so a completion handler from a superseded
    /// buffer can tell it is stale and must not report end-of-history itself.
    private var generation = 0

    private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: Double(HistoryRing.sampleRate),
                                              channels: AVAudioChannelCount(HistoryRing.channels),
                                              interleaved: true)!

    init(mixRing: HistoryRing, guitarRing: HistoryRing) {
        self.mixRing = mixRing
        self.guitarRing = guitarRing
        engine.attach(mixNode)
        engine.attach(guitarNode)
        engine.connect(mixNode, to: engine.mainMixerNode, format: Player.format)
        engine.connect(guitarNode, to: engine.mainMixerNode, format: Player.format)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(engineConfigurationChanged),
                                               name: .AVAudioEngineConfigurationChange,
                                               object: engine)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var position: Int {
        Player.computePosition(startFrame: startFrame, renderedFrames: renderedFrames())
    }

    /// Pure so it can be exercised with a synthetic rendered-frame count,
    /// without a real audio engine.
    nonisolated static func computePosition(startFrame: Int, renderedFrames: Int) -> Int {
        startFrame + renderedFrames
    }

    private func renderedFrames() -> Int {
        guard mixNode.isPlaying,
              let nodeTime = mixNode.lastRenderTime,
              let playerTime = mixNode.playerTime(forNodeTime: nodeTime)
        else { return 0 }
        return Int(playerTime.sampleTime)
    }

    func play(from frame: Int, until head: Int) {
        stop()
        generation += 1
        startFrame = frame
        let count = head - frame
        guard count > 0 else {
            signalEndOfHistory(generation: generation)
            return
        }
        schedule(ring: mixRing, node: mixNode, from: frame, count: count, generation: generation)
        schedule(ring: guitarRing, node: guitarNode, from: frame, count: count, generation: nil)
        try? engine.start()
        mixNode.play()
        guitarNode.play()
    }

    func stop() {
        generation += 1
        mixNode.stop()
        guitarNode.stop()
        engine.stop()
    }

    /// Only the mix node's completion reports end-of-history, so a simultaneous
    /// finish on both nodes doesn't fire the callback twice.
    private func schedule(ring: HistoryRing, node: AVAudioPlayerNode, from: Int, count: Int, generation: Int?) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Player.format, frameCapacity: AVAudioFrameCount(count))
        else { return }
        let frames = ring.read(from: from, count: count)
        buffer.frameLength = AVAudioFrameCount(count)
        frames.withUnsafeBufferPointer { source in
            buffer.int16ChannelData![0].update(from: source.baseAddress!, count: frames.count)
        }
        guard let generation else {
            node.scheduleBuffer(buffer)
            return
        }
        node.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async { self?.signalEndOfHistory(generation: generation) }
        }
    }

    private func signalEndOfHistory(generation: Int) {
        guard generation == self.generation else { return }
        onReachedEnd?()
    }

    /// AVAudioEngine posts this on a background queue; the player lives on main.
    @objc nonisolated private func engineConfigurationChanged() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // An output device switch invalidates the engine's connections; restart
                // playback at the position already reached (KTD7).
                guard self.mixNode.isPlaying else { return }
                self.play(from: self.position, until: self.mixRing.head)
            }
        }
    }
}
