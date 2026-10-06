import AVFoundation
import Testing

@testable import SpectrumAnalyzer

private func format(rate: Double, channels: AVAudioChannelCount = 2) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: rate,
                  channels: channels,
                  interleaved: true)!
}

private func push(_ queue: SPSCQueue, hostTime: Double, _ samples: [Float]) {
    samples.withUnsafeBufferPointer {
        #expect(queue.push(hostTime: hostTime, samples: $0))
    }
}

@Test func resamplesChunkToClockPosition() {
    let queue = SPSCQueue(slotCount: 4, slotCapacity: 96_000)
    let ring = HistoryRing(capacity: 10 * HistoryRing.sampleRate)
    let clock = HistoryClock(start: 0)
    let worker = CaptureWorker(queue: queue, ring: ring, clock: { clock }, isLive: { true })
    worker.sourceFormat = format(rate: 44_100)

    push(queue, hostTime: 1.0, [Float](repeating: 0.5, count: 44_100 * 2))
    worker.drain()

    let start = 48_000
    #expect(ring.head == start + 48_000)
    let middle = ring.read(from: start + 24_000, count: 1)
    #expect(abs(Int(middle[0]) - 16_383) < 8)
    #expect(ring.read(from: start - 1, count: 1)[0] == 0)
}

@Test func sourcesWriteOnlyToTheirOwnRing() {
    let rings = (HistoryRing(capacity: 10 * HistoryRing.sampleRate),
                 HistoryRing(capacity: 10 * HistoryRing.sampleRate))
    let queues = (SPSCQueue(slotCount: 4, slotCapacity: 96_000),
                  SPSCQueue(slotCount: 4, slotCapacity: 96_000))
    let clock = HistoryClock(start: 0)
    let mix = CaptureWorker(queue: queues.0, ring: rings.0, clock: { clock }, isLive: { true })
    let guitar = CaptureWorker(queue: queues.1, ring: rings.1, clock: { clock }, isLive: { true })
    mix.sourceFormat = format(rate: 48_000)
    guitar.sourceFormat = format(rate: 48_000)

    push(queues.0, hostTime: 1.0, [Float](repeating: 0.5, count: 4_800 * 2))
    push(queues.1, hostTime: 2.0, [Float](repeating: 0.25, count: 4_800 * 2))
    mix.drain()
    guitar.drain()

    #expect(rings.0.head == 48_000 + 4_800)
    #expect(rings.1.head == 96_000 + 4_800)
    #expect(rings.0.read(from: 48_000, count: 1)[0] == 16_383)
    #expect(rings.1.read(from: 96_000, count: 1)[0] == 8_191)
    // The mix source never wrote at the guitar's position, and vice versa.
    #expect(rings.0.read(from: 96_000, count: 1)[0] == 0)
    #expect(rings.1.read(from: 48_000, count: 1)[0] == 0)
}

@Test func discardsChunksWhileNotLive() {
    let queue = SPSCQueue(slotCount: 4, slotCapacity: 96_000)
    let ring = HistoryRing(capacity: 10 * HistoryRing.sampleRate)
    let clock = HistoryClock(start: 0)
    var live = false
    let worker = CaptureWorker(queue: queue, ring: ring, clock: { clock }, isLive: { live })
    worker.sourceFormat = format(rate: 48_000)

    push(queue, hostTime: 1.0, [Float](repeating: 0.5, count: 4_800 * 2))
    worker.drain()
    #expect(ring.head == 0)
    #expect(queue.pop() == nil)

    live = true
    push(queue, hostTime: 2.0, [Float](repeating: 0.5, count: 4_800 * 2))
    worker.drain()
    #expect(ring.head == 96_000 + 4_800)
}

@Test func clipsSamplesBeyondUnityInsteadOfWrapping() {
    let queue = SPSCQueue(slotCount: 4, slotCapacity: 96_000)
    let ring = HistoryRing(capacity: 10 * HistoryRing.sampleRate)
    let clock = HistoryClock(start: 0)
    let worker = CaptureWorker(queue: queue, ring: ring, clock: { clock }, isLive: { true })
    worker.sourceFormat = format(rate: 48_000)

    push(queue, hostTime: 1.0, [4.0, -4.0, 1.5, -1.5])
    worker.drain()

    #expect(ring.read(from: 48_000, count: 2) == [32_767, -32_767, 32_767, -32_767])
}
