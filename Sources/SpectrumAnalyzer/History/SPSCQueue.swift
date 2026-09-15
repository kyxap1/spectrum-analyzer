import Synchronization

/// Single-producer/single-consumer chunk queue over preallocated storage.
/// `push` is called from an IOProc thread, so it only copies samples and moves
/// atomic indices: no allocation, no locking, no reference counting, and it
/// never waits on the consumer — a chunk that does not fit is dropped.
final class SPSCQueue: @unchecked Sendable {
    private let slotCount: Int
    private let slotCapacity: Int
    private let samples: UnsafeMutableBufferPointer<Float>
    private let hostTimes: UnsafeMutableBufferPointer<Double>
    private let counts: UnsafeMutableBufferPointer<Int>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let drops = Atomic<Int>(0)

    init(slotCount: Int, slotCapacity: Int) {
        self.slotCount = slotCount
        self.slotCapacity = slotCapacity
        samples = .allocate(capacity: slotCount * slotCapacity)
        samples.initialize(repeating: 0)
        hostTimes = .allocate(capacity: slotCount)
        hostTimes.initialize(repeating: 0)
        counts = .allocate(capacity: slotCount)
        counts.initialize(repeating: 0)
    }

    deinit {
        samples.deallocate()
        hostTimes.deallocate()
        counts.deallocate()
    }

    var dropCount: Int { drops.load(ordering: .relaxed) }

    func push(hostTime: Double, samples chunk: UnsafeBufferPointer<Float>) -> Bool {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard chunk.count <= slotCapacity, write - read < slotCount else {
            drops.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        let slot = write % slotCount
        if let source = chunk.baseAddress {
            (samples.baseAddress! + slot * slotCapacity).update(from: source, count: chunk.count)
        }
        counts[slot] = chunk.count
        hostTimes[slot] = hostTime
        writeIndex.store(write + 1, ordering: .releasing)
        return true
    }

    func pop() -> (hostTime: Double, samples: [Float])? {
        let read = readIndex.load(ordering: .relaxed)
        guard read != writeIndex.load(ordering: .acquiring) else { return nil }
        let slot = read % slotCount
        let chunk = Array(UnsafeBufferPointer(start: samples.baseAddress! + slot * slotCapacity,
                                              count: counts[slot]))
        let hostTime = hostTimes[slot]
        readIndex.store(read + 1, ordering: .releasing)
        return (hostTime, chunk)
    }
}
