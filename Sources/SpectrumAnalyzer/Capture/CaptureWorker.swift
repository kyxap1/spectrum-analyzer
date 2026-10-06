import AVFoundation

/// Holds the one buffer an `AVAudioConverter` input block may hand back.
private final class Pending: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Drains one capture source's queue into one history ring, resampling to the
/// ring's fixed 48 kHz 16-bit stereo format. Source-agnostic: the mix tap and
/// the guitar input each own an instance.
final class CaptureWorker {
    /// Format of the samples the producer pushes. The producer sets it before
    /// its first push and again whenever it rebuilds with a new format.
    var sourceFormat: AVAudioFormat?

    private let queue: SPSCQueue
    private let ring: HistoryRing
    private let clock: () -> HistoryClock
    private let isLive: () -> Bool
    private var converter: AVAudioConverter?

    private static let ringFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: Double(HistoryRing.sampleRate),
                                                  channels: AVAudioChannelCount(HistoryRing.channels),
                                                  interleaved: true)!

    init(queue: SPSCQueue,
         ring: HistoryRing,
         clock: @escaping () -> HistoryClock,
         isLive: @escaping () -> Bool) {
        self.queue = queue
        self.ring = ring
        self.clock = clock
        self.isLive = isLive
    }

    /// Always empties the queue, so a non-Live session does not back it up into
    /// drops, but writes nothing while not Live.
    func drain() {
        while let chunk = queue.pop() {
            guard isLive(), let format = sourceFormat else { continue }
            guard let frames = convert(chunk.samples, from: format), !frames.isEmpty else { continue }
            let at = ring.writePosition(clockFrame: clock().frame(at: chunk.hostTime))
            ring.write(at: at, frames)
        }
    }

    private func convert(_ samples: [Float], from format: AVAudioFormat) -> [Int16]? {
        if converter?.inputFormat != format {
            converter = AVAudioConverter(from: format, to: CaptureWorker.ringFormat)
        }
        guard let converter else { return nil }

        let inputFrames = AVAudioFrameCount(samples.count / Int(format.channelCount))
        guard inputFrames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: inputFrames)
        else { return nil }
        input.frameLength = inputFrames
        samples.withUnsafeBufferPointer {
            input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }

        let ratio = CaptureWorker.ringFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputFrames) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: CaptureWorker.ringFormat,
                                            frameCapacity: capacity)
        else { return nil }

        // The input block is @Sendable but is called synchronously on this
        // thread, so handing it the buffer through an unchecked box is safe.
        let pending = Pending(input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            let buffer = pending.take()
            status.pointee = buffer == nil ? .endOfStream : .haveData
            return buffer
        }
        // ponytail: each chunk converts as its own stream, so the frame count
        // always matches the rate ratio and lands at its own clock position.
        // Left cold across chunks it holds frames back and the write position
        // drifts away from the clock. Resampling therefore restarts per chunk;
        // if the boundary artifact ever shows, carry converter state and
        // compensate the position by its latency instead.
        converter.reset()
        guard error == nil else { return nil }

        let count = Int(output.frameLength) * HistoryRing.channels
        var frames = [Int16](repeating: 0, count: count)
        let source = output.floatChannelData![0]
        for i in 0..<count {
            frames[i] = Int16(min(max(source[i], -1), 1) * 32_767)
        }
        return frames
    }
}
