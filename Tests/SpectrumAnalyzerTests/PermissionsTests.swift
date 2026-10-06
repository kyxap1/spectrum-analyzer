import Testing
@testable import SpectrumAnalyzer

@Suite("Permissions")
struct PermissionsTests {
    @Test("not-determined microphone status requests access once")
    func notDeterminedRequestsAccessOnce() {
        var calls = 0
        Permissions.requestMicrophoneAccessIfNeeded(status: .notDetermined, requestAccess: { completion in
            calls += 1
            completion(true)
        })
        #expect(calls == 1)
    }

    @Test("authorized microphone status does not request access")
    func authorizedDoesNotRequest() {
        var calls = 0
        Permissions.requestMicrophoneAccessIfNeeded(status: .authorized, requestAccess: { _ in calls += 1 })
        #expect(calls == 0)
    }

    @Test("denied microphone status does not request access")
    func deniedDoesNotRequest() {
        var calls = 0
        Permissions.requestMicrophoneAccessIfNeeded(status: .denied, requestAccess: { _ in calls += 1 })
        #expect(calls == 0)
    }

    @Test("microphone denied with system audio authorized shows one banner naming Microphone")
    func microphoneDeniedBanner() {
        let banners = statusBanners(microphone: .denied, systemAudioRecording: .authorized, mix: .running)
        #expect(banners == [.microphoneDenied])
    }

    @Test("both denied shows two banners")
    func bothDeniedBanners() {
        let banners = statusBanners(microphone: .denied, systemAudioRecording: .denied, mix: .running)
        #expect(banners == [.microphoneDenied, .systemAudioDenied])
    }

    @Test("unavailable private check shows no system audio banner")
    func unknownSystemAudioShowsNoBanner() {
        let banners = statusBanners(microphone: .authorized, systemAudioRecording: .unknown, mix: .running)
        #expect(banners.isEmpty)
    }

    @Test("mix-unavailable status shows a banner with its OSStatus")
    func mixUnavailableBanner() {
        let banners = statusBanners(microphone: .authorized, systemAudioRecording: .authorized, mix: .unavailable(-1))
        #expect(banners == [.mixUnavailable(-1)])
    }
}
