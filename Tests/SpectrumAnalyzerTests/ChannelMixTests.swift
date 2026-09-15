import Testing

@testable import SpectrumAnalyzer

/// One frame of a device with `channels` inputs, each channel carrying its own
/// value so a sum of channels is unambiguous.
private func frame(channels: Int) -> [Float] {
    (1...channels).map { Float($0) / 10 }
}

private final class FakeStore: KeyValueStore {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private func input(store: KeyValueStore, devices: [AudioInputDevice] = []) -> InterfaceInput {
    InterfaceInput(queue: SPSCQueue(slotCount: 2, slotCapacity: 16),
                   store: store,
                   inputDevices: { devices })
}

@Test func stereoTickSplitsTheTwoChannelsLeftAndRight() {
    let mixed = mixGuitarStereo(frame(channels: 4), channels: 4, ticks: [1, 2])
    #expect(mixed == [0.1, 0.2])
}

@Test func singleTickFeedsBothSides() {
    let mixed = mixGuitarStereo(frame(channels: 4), channels: 4, ticks: [3])
    #expect(mixed == [0.3, 0.3])
}

@Test func oddTickCountSumsIntoTheSideItLandsOn() {
    let channels = frame(channels: 6)
    let mixed = mixGuitarStereo(channels, channels: 6, ticks: [1, 2, 5])
    // Position 0 and 2 are left, position 1 is right.
    #expect(mixed == [channels[0] + channels[4], channels[1]])
}

@Test func mixesEveryFrameOfABlock() {
    let block = frame(channels: 4) + frame(channels: 4).map { $0 * 10 }
    let mixed = mixGuitarStereo(block, channels: 4, ticks: [1, 2])
    #expect(mixed == [0.1, 0.2, 1.0, 2.0])
}

@Test func writesNothingWithoutAnUsableTick() {
    #expect(mixGuitarStereo(frame(channels: 4), channels: 4, ticks: []) == nil)
    // Stale tick from a device with more inputs than the current one.
    #expect(mixGuitarStereo(frame(channels: 4), channels: 4, ticks: [7]) == nil)
}

@Test func selectionPersistsAndRestores() {
    let store = FakeStore()
    input(store: store).select(deviceUID: "UID-A", ticks: [1, 2, 5])

    let restored = input(store: store)
    #expect(restored.deviceUID == "UID-A")
    #expect(restored.ticks == [1, 2, 5])
}

@Test func restoredTicksBeyondTheDeviceChannelCountAreDropped() {
    let store = FakeStore()
    input(store: store).select(deviceUID: "UID-A", ticks: [1, 2, 5])

    let device = AudioInputDevice(id: 1, uid: "UID-A", name: "A", channels: 2)
    let sides = input(store: store, devices: [device]).activeChannelSides
    #expect(sides.left == [0])
    #expect(sides.right == [1])
}

@Test func absentDeviceLeavesNoChannelsActive() {
    let store = FakeStore()
    input(store: store).select(deviceUID: "UID-A", ticks: [1, 2])

    let sides = input(store: store).activeChannelSides
    #expect(sides.left.isEmpty)
    #expect(sides.right.isEmpty)
}
