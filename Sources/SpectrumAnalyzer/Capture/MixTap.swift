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
final class MixTap {
    let queue: SPSCQueue
    var onStatusChange: ((MixTapStatus) -> Void)?
    var onFormatChange: ((AVAudioFormat) -> Void)?

    private(set) var status: MixTapStatus = .stopped {
        didSet {
            guard status != oldValue else { return }
            onStatusChange?(status)
        }
    }

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

    init(queue: SPSCQueue, outputDeviceUID: @escaping () -> String?) {
        self.queue = queue
        self.outputDeviceUID = outputDeviceUID
    }

    deinit {
        teardown()
    }

    func start() {
        rebuild()
    }

    func stop() {
        teardown()
        status = .stopped
    }

    /// Call on a default-output-device change, and to retry after a failure.
    func rebuild() {
        teardown()
        if let failure = build() {
            teardown()
            status = .unavailable(failure)
        } else {
            status = .running
        }
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
        onFormatChange?(format)

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

        status = AudioDeviceStart(aggregate, ioProc)
        guard status == noErr else { return status }

        listenForFormatChanges()
        return nil
    }

    private func teardown() {
        if let listener = formatListener, tap != kAudioObjectUnknown {
            var address = AudioDevices.address(kAudioTapPropertyFormat)
            AudioObjectRemovePropertyListenerBlock(tap, &address, DispatchQueue.main, listener)
        }
        formatListener = nil
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = kAudioObjectUnknown
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = kAudioObjectUnknown
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
