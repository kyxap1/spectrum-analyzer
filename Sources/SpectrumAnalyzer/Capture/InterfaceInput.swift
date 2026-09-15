import AVFoundation
import CoreAudio
import Foundation

/// The persistence seam for the selected device and its ticked channels.
/// `UserDefaults` already implements it.
protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// One ticked channel routed to one side of the stereo history. A channel is
/// located by the buffer it arrives in plus its position inside that buffer's
/// interleaved frames, so both a single interleaved stream and one stream per
/// channel are read the same way.
struct ChannelSlot {
    let buffer: Int
    let offset: Int
    let stride: Int
    let side: Int
}

/// Ticked 1-based channels split by position: even positions go left, odd
/// positions go right, and a lone tick goes to both sides. Ticks the device
/// does not have — stale ones from a wider device — drop out first.
func guitarChannelSides(ticks: [Int], channels: Int) -> (left: [Int], right: [Int]) {
    let usable = ticks.filter { $0 >= 1 && $0 <= channels }.map { $0 - 1 }
    guard usable.count > 1 else { return (usable, usable) }
    var left: [Int] = []
    var right: [Int] = []
    for (position, channel) in usable.enumerated() {
        if position % 2 == 0 { left.append(channel) } else { right.append(channel) }
    }
    return (left, right)
}

func channelSlots(ticks: [Int], layout: [Int]) -> [ChannelSlot] {
    let sides = guitarChannelSides(ticks: ticks, channels: layout.reduce(0, +))
    var slots: [ChannelSlot] = []
    for (side, channels) in [sides.left, sides.right].enumerated() {
        for channel in channels {
            var first = 0
            for (buffer, width) in layout.enumerated() {
                if channel < first + width {
                    slots.append(ChannelSlot(buffer: buffer,
                                             offset: channel - first,
                                             stride: width,
                                             side: side))
                    break
                }
                first += width
            }
        }
    }
    return slots
}

/// Sums each slot's channel into its side of `out`, which holds `frames`
/// interleaved stereo frames. Runs on the IOProc thread: it only reads
/// preallocated storage and never allocates.
func mixSlots(_ slots: [ChannelSlot],
              bases: UnsafeBufferPointer<UnsafePointer<Float>?>,
              frames: Int,
              into out: UnsafeMutableBufferPointer<Float>) {
    for i in 0..<(frames * 2) { out[i] = 0 }
    for slot in slots {
        guard let base = bases[slot.buffer] else { continue }
        for frame in 0..<frames {
            out[frame * 2 + slot.side] += base[frame * slot.stride + slot.offset]
        }
    }
}

/// Mixes one interleaved block, nil when no ticked channel survives the
/// device's channel count. The IOProc path shares `mixSlots` with it.
func mixGuitarStereo(_ block: [Float], channels: Int, ticks: [Int]) -> [Float]? {
    let slots = channelSlots(ticks: ticks, layout: [channels])
    guard !slots.isEmpty else { return nil }
    let frames = block.count / channels
    var out = [Float](repeating: 0, count: frames * 2)
    block.withUnsafeBufferPointer { input in
        var base: UnsafePointer<Float>? = input.baseAddress
        withUnsafePointer(to: &base) { bases in
            out.withUnsafeMutableBufferPointer {
                mixSlots(slots,
                         bases: UnsafeBufferPointer(start: bases, count: 1),
                         frames: frames,
                         into: $0)
            }
        }
    }
    return out
}

/// Captures the ticked channels of one audio interface with a HAL IOProc on
/// that device, mixed down to the stereo stream the guitar history keeps.
///
/// `AVAudioEngine`'s input node follows the default input device, so the device
/// is opened directly. Selection and ticks persist, and the owner calls
/// `deviceListChanged()` from `AudioDevices.onDeviceListChange` so the capture
/// follows the interface across unplugging and replugging.
///
/// `@unchecked Sendable`: `device`/`ioProc`/`mixed`/`bases` are touched only on
/// `halQueue`, everything else only on the main queue — the two never share a
/// mutable property, so crossing threads to call `teardown()`/`build()` is safe.
final class InterfaceInput: @unchecked Sendable {
    let queue: SPSCQueue
    var onStatusChange: ((MixTapStatus) -> Void)?
    var onFormatChange: ((AVAudioFormat) -> Void)?

    /// Only ever set via `setStatus(_:)` on the main queue, so `didSet` can
    /// call `onStatusChange` directly without crossing actors.
    private(set) var status: MixTapStatus = .stopped {
        didSet {
            guard status != oldValue else { return }
            onStatusChange?(status)
        }
    }

    private(set) var deviceUID: String?
    private(set) var ticks: [Int]

    /// `AudioDeviceStart`-class calls can block for a long time on HAL/driver
    /// contention; teardown()/build() run here, off the caller's thread, so a
    /// stall never freezes the UI. Only this queue touches
    /// `device`/`ioProc`/`mixed`/`bases`. Shared with `MixTap` so the two
    /// never issue HAL device create/destroy calls concurrently — that
    /// concurrency wedged coreaudiod at launch.
    private let halQueue: DispatchQueue
    private let store: KeyValueStore
    private let inputDevices: () -> [AudioInputDevice]
    private var device = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var mixed: UnsafeMutableBufferPointer<Float>?
    private var bases: UnsafeMutableBufferPointer<UnsafePointer<Float>?>?

    private static let deviceKey = "guitar.deviceUID"
    private static let ticksKey = "guitar.ticks"

    /// Blocks larger than this are dropped rather than sized for at runtime; no
    /// HAL device asks for anywhere near it.
    private static let maxFrames = 16_384

    /// mach absolute ticks to seconds, the unit `HistoryClock` works in.
    private static let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    init(queue: SPSCQueue,
         store: KeyValueStore = UserDefaults.standard,
         inputDevices: @escaping () -> [AudioInputDevice],
         halQueue: DispatchQueue) {
        self.queue = queue
        self.store = store
        self.inputDevices = inputDevices
        self.halQueue = halQueue
        deviceUID = store.object(forKey: InterfaceInput.deviceKey) as? String
        ticks = store.object(forKey: InterfaceInput.ticksKey) as? [Int] ?? []
    }

    deinit {
        // Snapshot the resources instead of capturing `self` in the closure:
        // self's refcount is already 0 here, and retaining it to call an
        // instance method from inside `sync` would trap.
        let device = self.device
        let ioProc = self.ioProc
        let mixed = self.mixed
        let bases = self.bases
        halQueue.sync {
            InterfaceInput.releaseResources(device: device, ioProc: ioProc, mixed: mixed, bases: bases)
        }
    }

    var selectedDevice: AudioInputDevice? {
        deviceUID.flatMap { uid in inputDevices().first { $0.uid == uid } }
    }

    /// The ticked channels as they map onto the connected device, empty while
    /// the device is gone or nothing usable is ticked.
    var activeChannelSides: (left: [Int], right: [Int]) {
        guitarChannelSides(ticks: ticks, channels: selectedDevice?.channels ?? 0)
    }

    func select(deviceUID: String?, ticks: [Int]) {
        self.deviceUID = deviceUID
        self.ticks = ticks
        store.set(deviceUID, forKey: InterfaceInput.deviceKey)
        store.set(ticks, forKey: InterfaceInput.ticksKey)
        scheduleRebuild(deviceUID: deviceUID, ticks: ticks)
    }

    func start() {
        scheduleRebuild(deviceUID: deviceUID, ticks: ticks)
    }

    func stop() {
        halQueue.async { [weak self] in
            self?.teardown()
            self?.setStatus(.stopped)
        }
    }

    /// Call on a device-list change: starts capture once the selected device is
    /// back and stops it when it is gone, leaving the mix source untouched.
    func deviceListChanged() {
        scheduleRebuild(deviceUID: deviceUID, ticks: ticks)
    }

    /// Snapshots the selection on the caller's (main) thread so `rebuild()`
    /// never reads `deviceUID`/`ticks` from `halQueue` while `select()` can
    /// be writing them on main.
    private func scheduleRebuild(deviceUID: String?, ticks: [Int]) {
        halQueue.async { [weak self] in self?.rebuild(deviceUID: deviceUID, ticks: ticks) }
    }

    private func rebuild(deviceUID: String?, ticks: [Int]) {
        teardown()
        guard let device = deviceUID.flatMap({ uid in inputDevices().first { $0.uid == uid } }) else {
            setStatus(.stopped)
            return
        }
        let slots = channelSlots(ticks: ticks, layout: streamLayout(of: device.id))
        // Nothing ticked: the guitar curve stays hidden and the mix keeps going.
        guard !slots.isEmpty else {
            setStatus(.stopped)
            return
        }
        if let failure = build(device: device, slots: slots) {
            teardown()
            setStatus(.unavailable(failure))
        } else {
            setStatus(.running)
        }
    }

    /// Hops to the main queue so `status`'s `didSet` (and the `onStatusChange`
    /// it calls) never runs on `halQueue`.
    private func setStatus(_ newStatus: MixTapStatus) {
        DispatchQueue.main.async { [weak self] in self?.status = newStatus }
    }

    /// Returns the `OSStatus` of the first step that failed, nil on success.
    private func build(device: AudioInputDevice, slots: [ChannelSlot]) -> OSStatus? {
        self.device = device.id

        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioDevices.address(kAudioDevicePropertyNominalSampleRate)
        let rateStatus = AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &rate)
        guard rateStatus == noErr else { return rateStatus }
        guard rate > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: rate,
                                         channels: 2,
                                         interleaved: true)
        else { return kAudioHardwareUnknownPropertyError }
        // Must land before AudioDeviceStart below, so the IOProc never pushes
        // samples the consumer would read with the previous device's format.
        DispatchQueue.main.sync { [weak self] in self?.onFormatChange?(format) }

        let mixed = UnsafeMutableBufferPointer<Float>.allocate(capacity: InterfaceInput.maxFrames * 2)
        mixed.initialize(repeating: 0)
        self.mixed = mixed
        let bases = UnsafeMutableBufferPointer<UnsafePointer<Float>?>
            .allocate(capacity: max(slots.map { $0.buffer }.max()! + 1, 1))
        bases.initialize(repeating: nil)
        self.bases = bases

        // The IOProc runs on a realtime thread: it captures only preallocated
        // storage and plain values, so it neither touches `self` nor allocates.
        let queue = queue
        let scale = InterfaceInput.ticksToSeconds
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, device.id, nil) { _, input, inputTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var frames = 0
            for index in 0..<bases.count {
                guard index < list.count else { break }
                let buffer = list[index]
                let channels = Int(buffer.mNumberChannels)
                guard let data = buffer.mData, channels > 0 else { continue }
                bases[index] = UnsafePointer(data.assumingMemoryBound(to: Float.self))
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                frames = frames == 0 ? count : min(frames, count)
            }
            guard frames > 0, frames <= InterfaceInput.maxFrames else { return }
            mixSlots(slots, bases: UnsafeBufferPointer(bases), frames: frames, into: mixed)
            let ticks = inputTime.pointee.mHostTime
            _ = queue.push(hostTime: Double(ticks == 0 ? mach_absolute_time() : ticks) * scale,
                           samples: UnsafeBufferPointer(start: mixed.baseAddress, count: frames * 2))
        }
        guard status == noErr else { return status }

        let startStatus = audioDeviceStart(device.id, ioProc)
        return startStatus == noErr ? nil : startStatus
    }

    private func teardown() {
        InterfaceInput.releaseResources(device: device, ioProc: ioProc, mixed: mixed, bases: bases)
        ioProc = nil
        device = kAudioObjectUnknown
        mixed = nil
        bases = nil
    }

    /// Free function so `deinit` can call it without capturing `self`.
    private static func releaseResources(device: AudioObjectID,
                                         ioProc: AudioDeviceIOProcID?,
                                         mixed: UnsafeMutableBufferPointer<Float>?,
                                         bases: UnsafeMutableBufferPointer<UnsafePointer<Float>?>?) {
        if let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
        }
        mixed?.deallocate()
        bases?.deallocate()
    }

    /// Channels per input buffer, which is how the IOProc's buffer list is laid
    /// out: one interleaved stream, or one buffer per channel.
    private func streamLayout(of device: AudioObjectID) -> [Int] {
        var address = AudioDevices.address(kAudioDevicePropertyStreamConfiguration,
                                           scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                  alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }
}
