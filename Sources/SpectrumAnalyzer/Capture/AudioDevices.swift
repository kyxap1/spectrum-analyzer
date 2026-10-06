import CoreAudio
import Foundation

/// `AudioDeviceStart` can block forever if the driver's IO thread never
/// reports "running" (observed: a misbehaving mic driver wedges it
/// indefinitely). Running it on its own thread and waiting with a deadline
/// means one stuck device fails fast instead of permanently blocking
/// `halQueue` — and every rebuild queued behind it — for the rest of the
/// app's life. On timeout the call is abandoned (CoreAudio gives no way to
/// cancel it) to run out on its own thread; the deadline only bounds how
/// long the caller waits for it.
func audioDeviceStart(_ device: AudioObjectID,
                      _ ioProc: AudioDeviceIOProcID?,
                      timeout: TimeInterval = 5) -> OSStatus {
    final class ResultBox: @unchecked Sendable {
        // Written once on the detached thread, read only after `semaphore`
        // signals — that ordering is the synchronization.
        var status: OSStatus = noErr
    }
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox()
    DispatchQueue.global(qos: .userInitiated).async {
        box.status = AudioDeviceStart(device, ioProc)
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        return kAudioHardwareUnspecifiedError
    }
    return box.status
}

struct AudioInputDevice: Equatable, Identifiable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let channels: Int
}

/// The system's current default output device and its capturable input
/// devices, re-read on every hardware change.
///
/// `@unchecked Sendable`: `listeners` is touched only on the main queue
/// (init/deinit); every other method only makes CoreAudio HAL calls and
/// touches no shared mutable state, so calling them from `audioHALQueue` is
/// safe.
final class AudioDevices: @unchecked Sendable {
    /// Called on the main queue after the default output device changed.
    var onDefaultOutputChange: (() -> Void)?
    /// Called on the main queue after the device list changed. MixTap's own
    /// aggregate device create/destroy is itself a device-list change, so
    /// this must stay separate from `onDefaultOutputChange` — routing it
    /// there would have MixTap's rebuild retrigger itself forever.
    var onDeviceListChange: (() -> Void)?

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        listen(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.onDefaultOutputChange?() }
        listen(kAudioHardwarePropertyDevices) { [weak self] in self?.onDeviceListChange?() }
    }

    deinit {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address,
                                                   DispatchQueue.main,
                                                   block)
        }
    }

    var defaultOutputDevice: AudioObjectID? {
        let id: AudioObjectID? = value(AudioObjectID(kAudioObjectSystemObject),
                                       kAudioHardwarePropertyDefaultOutputDevice)
        return id == kAudioObjectUnknown ? nil : id
    }

    var defaultOutputDeviceUID: String? {
        defaultOutputDevice.flatMap { uid(of: $0) }
    }

    var inputDevices: [AudioInputDevice] {
        deviceIDs.compactMap { id in
            let channels = channelCount(of: id, scope: kAudioObjectPropertyScopeInput)
            guard channels > 0, !isPrivateAggregate(id), let uid = uid(of: id) else { return nil }
            let name: CFString? = value(id, kAudioObjectPropertyName)
            return AudioInputDevice(id: id,
                                    uid: uid,
                                    name: name as String? ?? uid,
                                    channels: channels)
        }
    }

    private var deviceIDs: [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown,
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty,
              AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private func uid(of device: AudioObjectID) -> String? {
        let uid: CFString? = value(device, kAudioDevicePropertyDeviceUID)
        return uid as String?
    }

    /// Private aggregates — `MixTap`'s own device and the per-process one the
    /// HAL creates — are visible only to this process and get a new UID every
    /// launch, so a saved selection of one never matches again.
    private func isPrivateAggregate(_ device: AudioObjectID) -> Bool {
        let composition: CFDictionary? = value(device, kAudioAggregateDevicePropertyComposition)
        return (composition as? [String: Any])?[kAudioAggregateDeviceIsPrivateKey] as? Int == 1
    }

    private func channelCount(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                  alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func value<T>(_ object: AudioObjectID,
                          _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = Self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let result = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { result.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, result) == noErr else { return nil }
        return result.move()
    }

    private func listen(_ selector: AudioObjectPropertySelector, handler: @escaping () -> Void) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                  &address,
                                                  DispatchQueue.main,
                                                  block) == noErr
        else { return }
        listeners.append((address, block))
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
