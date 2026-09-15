import Foundation

/// Ring of interleaved 16-bit stereo frames addressed by absolute history
/// frame. Storage is preallocated once; anything older than `head - capacity`
/// is overwritten and reads back as zeros.
final class HistoryRing {
    static let sampleRate = 48_000
    static let channels = 2
    /// Device and host clocks drift by fractions of a millisecond per chunk;
    /// only a jump larger than this is a real gap rather than accumulated drift.
    static let driftTolerance = sampleRate / 100

    let capacity: Int
    private let storage: UnsafeMutableBufferPointer<Int16>
    private(set) var head = 0

    init(capacity: Int = 600 * HistoryRing.sampleRate) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity * HistoryRing.channels)
        storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    var range: Range<Int> { max(0, head - capacity)..<head }

    /// Where a chunk whose clock frame is `clockFrame` should be written.
    func writePosition(clockFrame: Int) -> Int {
        abs(clockFrame - head) < HistoryRing.driftTolerance ? head : clockFrame
    }

    /// Writes `chunk` at `frame`, zero-filling any gap left after the head.
    func write(at frame: Int, _ chunk: [Int16]) {
        let count = chunk.count / HistoryRing.channels
        guard count > 0 else { return }
        let newHead = max(head, frame + count)
        let oldest = newHead - capacity

        let gapStart = max(head, oldest)
        if gapStart < frame {
            store(nil, at: gapStart, count: frame - gapStart)
        }
        let start = max(frame, oldest)
        if start < frame + count {
            chunk.withUnsafeBufferPointer {
                store($0.baseAddress! + (start - frame) * HistoryRing.channels,
                      at: start,
                      count: frame + count - start)
            }
        }
        head = newHead
    }

    /// Frames outside the kept range read back as zeros.
    func read(from frame: Int, count: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: count * HistoryRing.channels)
        let kept = range
        let start = max(frame, kept.lowerBound)
        let end = min(frame + count, kept.upperBound)
        guard start < end else { return out }
        out.withUnsafeMutableBufferPointer { out in
            var position = start
            while position < end {
                let slot = position % capacity
                let n = min(end - position, capacity - slot)
                (out.baseAddress! + (position - frame) * HistoryRing.channels)
                    .update(from: storage.baseAddress! + slot * HistoryRing.channels,
                            count: n * HistoryRing.channels)
                position += n
            }
        }
        return out
    }

    func reset() {
        head = 0
        storage.update(repeating: 0)
    }

    /// Copies `count` frames from `source` (zeros when nil) at absolute `frame`,
    /// splitting the copy where it crosses the end of the ring.
    private func store(_ source: UnsafePointer<Int16>?, at frame: Int, count: Int) {
        var position = frame
        var remaining = count
        var offset = 0
        while remaining > 0 {
            let slot = position % capacity
            let n = min(remaining, capacity - slot)
            let destination = storage.baseAddress! + slot * HistoryRing.channels
            if let source {
                destination.update(from: source + offset, count: n * HistoryRing.channels)
            } else {
                destination.update(repeating: 0, count: n * HistoryRing.channels)
            }
            position += n
            remaining -= n
            offset += n * HistoryRing.channels
        }
    }
}
