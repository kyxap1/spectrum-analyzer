import Testing
@testable import SpectrumAnalyzer

private let rate = HistoryRing.sampleRate

private func ramp(from first: Int16, count: Int) -> [Int16] {
    (0..<(count * HistoryRing.channels)).map { Int16(truncatingIfNeeded: Int(first) + $0) }
}

@Suite("History")
struct HistoryTests {
    @Test("kept range is the last 10 minutes after 25 minutes of audio (AE4)")
    func keepsTenMinutes() {
        let ring = HistoryRing()
        let chunk = [Int16](repeating: 1, count: rate * HistoryRing.channels)
        for second in 0..<(25 * 60) {
            ring.write(at: second * rate, chunk)
        }
        #expect(ring.head == 25 * 60 * rate)
        #expect(ring.range == (15 * 60 * rate)..<(25 * 60 * rate))
        #expect(ring.range.count == 600 * rate)
    }

    @Test("a write crossing the end of the ring reads back identically")
    func wrapsWithoutCorruption() {
        let ring = HistoryRing(capacity: 10)
        ring.write(at: 0, ramp(from: 0, count: 6))
        let crossing = ramp(from: 100, count: 6)
        ring.write(at: 6, crossing)
        #expect(ring.read(from: 6, count: 6) == crossing)
        #expect(ring.read(from: 2, count: 4) == ramp(from: 4, count: 4))
    }

    @Test("a gap between chunks reads back as zeros")
    func zeroFillsGaps() {
        let ring = HistoryRing(capacity: 5 * rate)
        ring.write(at: 0, ramp(from: 1, count: rate))
        ring.write(at: 3 * rate, ramp(from: 1, count: rate))
        #expect(ring.read(from: rate, count: 2 * rate).allSatisfy { $0 == 0 })
        #expect(ring.read(from: 3 * rate, count: rate) == ramp(from: 1, count: rate))
        #expect(ring.head == 4 * rate)
    }

    @Test("small drift is appended contiguously, a real jump lands at its clock frame")
    func absorbsDrift() {
        let ring = HistoryRing(capacity: 5 * rate)
        ring.write(at: 0, ramp(from: 1, count: rate))
        let near = ring.head + rate * 3 / 1000
        #expect(ring.writePosition(clockFrame: near) == ring.head)
        let far = ring.head + rate * 50 / 1000
        #expect(ring.writePosition(clockFrame: far) == far)
        let behind = ring.head - rate * 50 / 1000
        #expect(ring.writePosition(clockFrame: behind) == behind)
    }

    @Test("reset empties the range and restarts at frame 0 (AE5)")
    func resetRestarts() {
        let ring = HistoryRing(capacity: 10 * 60 * rate)
        for second in 0..<(6 * 60) {
            ring.write(at: second * rate, [Int16](repeating: 7, count: rate * HistoryRing.channels))
        }
        ring.reset()
        #expect(ring.head == 0)
        #expect(ring.range.isEmpty)
        #expect(ring.read(from: 0, count: 128).allSatisfy { $0 == 0 })
        ring.write(at: 0, ramp(from: 1, count: 4))
        #expect(ring.head == 4)
        #expect(ring.read(from: 0, count: 4) == ramp(from: 1, count: 4))
    }

    @Test("a chunk straddling frame 0 keeps only its non-negative part")
    func writeBeforeZeroDropsNegativePart() {
        let ring = HistoryRing(capacity: 8)
        ring.write(at: -2, ramp(from: 1, count: 4))
        #expect(ring.head == 2)
        #expect(ring.read(from: 0, count: 2) == Array(ramp(from: 1, count: 4).suffix(4)))
        ring.write(at: -10, ramp(from: 1, count: 4))
        #expect(ring.head == 2)
    }

    @Test("a read reaching before the kept range returns zeros for the discarded part")
    func readsBeforeRangeAsZeros() {
        let ring = HistoryRing(capacity: 8)
        ring.write(at: 0, ramp(from: 1, count: 12))
        #expect(ring.range == 4..<12)
        let out = ring.read(from: 2, count: 6)
        #expect(Array(out.prefix(4)) == [0, 0, 0, 0])
        #expect(Array(out.suffix(8)) == Array(ramp(from: 1, count: 12)[8..<16]))
        #expect(ring.read(from: 100, count: 2).allSatisfy { $0 == 0 })
    }

    @Test("the clock excludes paused time")
    func clockExcludesPauses() {
        var clock = HistoryClock(start: 1_000)
        #expect(clock.frame(at: 1_030) == 30 * rate)
        clock.pause(at: 1_030)
        #expect(clock.frame(at: 1_045) == 30 * rate)
        clock.resume(at: 1_050)
        #expect(clock.frame(at: 1_060) == 40 * rate)
        clock.reset(start: 1_060)
        #expect(clock.frame(at: 1_061) == rate)
    }

    @Test("the queue delivers chunks in order and counts dropped ones when full")
    func queueOrdersAndDrops() {
        let queue = SPSCQueue(slotCount: 2, slotCapacity: 4)
        for value in 0..<4 {
            let chunk = [Float(value), Float(value) + 0.5]
            let pushed = chunk.withUnsafeBufferPointer {
                queue.push(hostTime: Double(value), samples: $0)
            }
            #expect(pushed == (value < 2))
        }
        #expect(queue.dropCount == 2)

        let first = queue.pop()
        #expect(first?.hostTime == 0)
        #expect(first?.samples == [0, 0.5])
        let second = queue.pop()
        #expect(second?.hostTime == 1)
        #expect(second?.samples == [1, 1.5])
        #expect(queue.pop() == nil)

        let long = [Float](repeating: 1, count: 5)
        #expect(long.withUnsafeBufferPointer { queue.push(hostTime: 9, samples: $0) } == false)
        #expect(queue.dropCount == 3)
    }
}
