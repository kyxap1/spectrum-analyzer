import AVFoundation
import Foundation

enum PermissionStatus: Equatable {
    case authorized
    case denied
    case notDetermined
    /// The private check is unavailable; the app relies on the OS prompt instead (KTD9).
    case unknown
}

/// One banner shown in the main window: a missing permission naming where to
/// grant it, or a capture failure with its `OSStatus` (R14).
enum StatusBanner: Equatable, Identifiable {
    case microphoneDenied
    case systemAudioDenied
    case mixUnavailable(OSStatus)

    var id: String {
        switch self {
        case .microphoneDenied: "microphone"
        case .systemAudioDenied: "systemAudio"
        case .mixUnavailable: "mixUnavailable"
        }
    }

    var title: String {
        switch self {
        case .microphoneDenied: "Microphone access is needed"
        case .systemAudioDenied: "System Audio Recording access is needed"
        case .mixUnavailable(let status): "Mix capture unavailable (OSStatus \(status))"
        }
    }

    /// The System Settings pane anchor to open for this banner, nil when there is none.
    var settingsURL: URL? {
        switch self {
        case .microphoneDenied:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .systemAudioDenied:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
        case .mixUnavailable:
            nil
        }
    }
}

/// Maps live permission and capture statuses to the banners the window shows
/// (KTD9, R14). Pure so it is testable without touching real permission APIs.
func statusBanners(microphone: PermissionStatus,
                   systemAudioRecording: PermissionStatus,
                   mix: MixTapStatus) -> [StatusBanner] {
    var banners: [StatusBanner] = []
    if microphone == .denied { banners.append(.microphoneDenied) }
    if systemAudioRecording == .denied { banners.append(.systemAudioDenied) }
    if case .unavailable(let status) = mix { banners.append(.mixUnavailable(status)) }
    return banners
}

enum Permissions {
    static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    /// Requests microphone access once when not yet determined, so the prompt
    /// appears at launch instead of the input silently returning zeros (R14).
    /// `status` and `requestAccess` are injectable seams for testing.
    static func requestMicrophoneAccessIfNeeded(
        status: PermissionStatus? = nil,
        requestAccess: (@escaping @Sendable (Bool) -> Void) -> Void = { completion in
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        },
        completion: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        guard (status ?? microphoneStatus()) == .notDetermined else { return }
        requestAccess(completion)
    }

    /// System audio recording status via the private `TCCAccessPreflight`
    /// (KTD9). The status-code mapping below follows TCC's known preflight
    /// values; unverified against a live TCC grant and expected to need
    /// adjustment if a later macOS changes them, in which case this falls
    /// back to `.unknown` and the app relies on the `AudioDeviceStart` prompt.
    static func systemAudioRecordingStatus() -> PermissionStatus {
        typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
              let symbol = dlsym(handle, "TCCAccessPreflight")
        else { return .unknown }
        let preflight = unsafeBitCast(symbol, to: PreflightFn.self)
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }
}
