import CoreAudio
import Foundation

struct AudioInputDevice: Equatable, Identifiable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let channels: Int
}

/// The system's current default output device and its capturable input
/// devices, re-read on every hardware change.
final class AudioDevices {
    /// Called on the main queue after the default output device or the device
    /// list changed. Consumers re-read the properties they care about.
    var onChange: (() -> Void)?

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        listen(kAudioHardwarePropertyDefaultOutputDevice)
        listen(kAudioHardwarePropertyDevices)
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
            guard channels > 0, let uid = uid(of: id) else { return nil }
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

    private func listen(_ selector: AudioObjectPropertySelector) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange?()
        }
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
