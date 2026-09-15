import AVFoundation
import CoreAudio
import Foundation

enum MixTapStatus: Equatable {
    case stopped
    case running
    /// Some step of the build failed; the tap retries on the next device change.
    case unavailable(OSStatus)
}

/// Captures everything the Mac plays by putting a private global process tap
/// into a private aggregate device whose main sub-device is the current default
/// output device, and reading that aggregate with an IOProc.
///
/// A tap does not follow the default output device, so a device change or a tap
/// format change rebuilds IOProc, aggregate device and tap from scratch.
///
/// `@unchecked Sendable`: `tap`/`aggregate`/`ioProc`/`formatListener` are
/// touched only on `halQueue`, everything else only on the main queue — the
/// two never share a mutable property, so crossing threads to call
/// `teardown()`/`build()` is safe.
final class MixTap: @unchecked Sendable {
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

    /// `AudioDeviceStart`/`AudioHardwareCreateAggregateDevice`-class calls can
    /// block for a long time on HAL/driver contention; teardown()/build() run
    /// here, off the caller's thread, so a stall never freezes the UI. Shared
    /// with `InterfaceInput` so the two never issue aggregate-device create/
    /// destroy calls to the HAL concurrently — that concurrency wedged
    /// coreaudiod at launch.
    private let halQueue: DispatchQueue
    private let outputDeviceUID: () -> String?
    private var tap = kAudioObjectUnknown
    private var aggregate = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var formatListener: AudioObjectPropertyListenerBlock?

    /// mach absolute ticks to seconds, the unit `HistoryClock` works in.
    private static let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    init(queue: SPSCQueue, outputDeviceUID: @escaping () -> String?, halQueue: DispatchQueue) {
        self.queue = queue
        self.outputDeviceUID = outputDeviceUID
        self.halQueue = halQueue
    }

    deinit {
        // Snapshot the resources instead of capturing `self` in the closure:
        // self's refcount is already 0 here, and retaining it to call an
        // instance method from inside `sync` would trap.
        let tap = self.tap
        let aggregate = self.aggregate
        let ioProc = self.ioProc
        let formatListener = self.formatListener
        halQueue.sync {
            MixTap.releaseResources(tap: tap, aggregate: aggregate, ioProc: ioProc, formatListener: formatListener)
        }
    }

    func start() {
        rebuild()
    }

    func stop() {
        halQueue.async { [weak self] in
            self?.teardown()
            self?.setStatus(.stopped)
        }
    }

    /// Call on a default-output-device change, and to retry after a failure.
    func rebuild() {
        halQueue.async { [weak self] in self?.rebuildLocked() }
    }

    private func rebuildLocked() {
        teardown()
        if let failure = build() {
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
    private func build() -> OSStatus? {
        guard let outputUID = outputDeviceUID() else { return kAudioHardwareBadDeviceError }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Spectrum Analyzer Mix"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        let tapUID = description.uuid.uuidString

        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { return status }

        guard let format = tapFormat() else { return kAudioHardwareUnknownPropertyError }
        // Must land before AudioDeviceStart below, so the IOProc never pushes
        // samples the consumer would read with the previous device's format.
        DispatchQueue.main.sync { [weak self] in self?.onFormatChange?(format) }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Spectrum Analyzer Mix",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr else { return status }

        // The IOProc runs on a realtime thread: it captures only the queue and
        // the timebase scale, so it neither touches `self` nor allocates.
        let queue = queue
        let scale = MixTap.ticksToSeconds
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, inputTime, _, _ in
            let buffer = input.pointee.mBuffers
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return }
            let ticks = inputTime.pointee.mHostTime
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                              count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            _ = queue.push(hostTime: Double(ticks == 0 ? mach_absolute_time() : ticks) * scale,
                           samples: samples)
        }
        guard status == noErr else { return status }

        status = audioDeviceStart(aggregate, ioProc)
        guard status == noErr else { return status }

        listenForFormatChanges()
        return nil
    }

    private func teardown() {
        MixTap.releaseResources(tap: tap, aggregate: aggregate, ioProc: ioProc, formatListener: formatListener)
        formatListener = nil
        ioProc = nil
        aggregate = kAudioObjectUnknown
        tap = kAudioObjectUnknown
    }

    /// Free function so `deinit` can call it without capturing `self`.
    private static func releaseResources(tap: AudioObjectID,
                                         aggregate: AudioObjectID,
                                         ioProc: AudioDeviceIOProcID?,
                                         formatListener: AudioObjectPropertyListenerBlock?) {
        if let listener = formatListener, tap != kAudioObjectUnknown {
            var address = AudioDevices.address(kAudioTapPropertyFormat)
            AudioObjectRemovePropertyListenerBlock(tap, &address, DispatchQueue.main, listener)
        }
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    private func tapFormat() -> AVAudioFormat? {
        var address = AudioDevices.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    private func listenForFormatChanges() {
        var address = AudioDevices.address(kAudioTapPropertyFormat)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuild()
        }
        guard AudioObjectAddPropertyListenerBlock(tap, &address, DispatchQueue.main, listener) == noErr
        else { return }
        formatListener = listener
    }
}
