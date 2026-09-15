import AppKit
import SwiftUI

@main
struct SpectrumAnalyzerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowLevel(model.pinned ? .floating : .normal)
    }
}

/// Wires capture, history, analysis and replay into the published state the
/// window renders, redrawing at 30 fps (KTD5).
@MainActor
final class AppModel: ObservableObject {
    @Published var mixPoints: [SpectrumPoint] = []
    @Published var guitarPoints: [SpectrumPoint]?
    @Published var banners: [StatusBanner] = []
    @Published var pinned = false
    @Published var timeConstant = 3.0 { didSet { resetAnalyzers() } }
    @Published var state: SessionState = .live
    @Published var scrubSeconds = 0
    @Published var scrubRangeSeconds: ClosedRange<Int> = 0...0
    @Published var devices: [AudioInputDevice] = []
    @Published var selectedDeviceUID: String?
    @Published var ticks: Set<Int> = []
    @Published var adviceState: AdviceState = .idle
    @Published var adviceModel = "sonnet"
    @Published var adviceAvailable = false

    private let audioDevices = AudioDevices()
    private let mixQueue = SPSCQueue(slotCount: 64, slotCapacity: 16_384)
    private let guitarQueue = SPSCQueue(slotCount: 64, slotCapacity: 16_384)
    private let mixRing = HistoryRing()
    private let guitarRing = HistoryRing()
    private let mixTap: MixTap
    private let interfaceInput: InterfaceInput
    private let player: Player
    private let session: Session
    private let mixWorker: CaptureWorker
    private let guitarWorker: CaptureWorker
    private var mixAnalyzer: SpectrumAnalyzer
    private var guitarAnalyzer: SpectrumAnalyzer
    private var timer: Timer?

    private let adviceRunner = AdviceRunner()
    private let cliPath = UserDefaults.standard.string(forKey: "advice.cliPath") ?? "~/bin/claude-private"
    private let rigURL = UserDefaults.standard.string(forKey: "advice.rigURL").flatMap(URL.init(string:)) ?? RigSource.defaultURL
    private var adviceTask: Task<Void, Never>?

    init() {
        mixTap = MixTap(queue: mixQueue, outputDeviceUID: { [audioDevices] in audioDevices.defaultOutputDeviceUID })
        interfaceInput = InterfaceInput(queue: guitarQueue, inputDevices: { [audioDevices] in audioDevices.inputDevices })
        player = Player(mixRing: mixRing, guitarRing: guitarRing)
        session = Session(mixRing: mixRing, guitarRing: guitarRing, player: player)
        mixWorker = CaptureWorker(queue: mixQueue, ring: mixRing, clock: { [session] in session.clock }, isLive: { [session] in session.isLive })
        guitarWorker = CaptureWorker(queue: guitarQueue, ring: guitarRing, clock: { [session] in session.clock }, isLive: { [session] in session.isLive })
        mixAnalyzer = SpectrumAnalyzer(timeConstant: 3.0)
        guitarAnalyzer = SpectrumAnalyzer(timeConstant: 3.0)

        mixTap.onFormatChange = { [mixWorker] format in mixWorker.sourceFormat = format }
        interfaceInput.onFormatChange = { [guitarWorker] format in guitarWorker.sourceFormat = format }
        interfaceInput.onStatusChange = { [weak self] _ in self?.tick() }
        mixTap.onStatusChange = { [weak self] _ in self?.tick() }
        audioDevices.onChange = { [mixTap, interfaceInput] in
            mixTap.rebuild()
            interfaceInput.deviceListChanged()
        }
        session.onStateChange = { [weak self] in self?.syncSessionState() }

        Permissions.requestMicrophoneAccessIfNeeded()
        mixTap.start()
        interfaceInput.start()
        refreshDeviceList()
        syncSessionState()

        timer = Timer.scheduledTimer(withTimeInterval: SpectrumAnalyzer.liveHopSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() { session.pause() }
    func play() { session.play() }
    func resumeLive() { session.resumeLive() }
    func reset() { session.reset() }

    func scrub(toSeconds seconds: Int) {
        session.scrub(to: seconds * HistoryRing.sampleRate)
    }

    /// F2: builds the payload from both rings' whole kept history and runs
    /// the CLI. Replacing `adviceState` on cancel discards a late result.
    func requestAdvice() {
        guard adviceAvailable, adviceState != .running else { return }
        let model = adviceModel
        adviceState = .running

        let mix = Payload.analyze(ring: mixRing)
        let guitarBands = Payload.analyze(ring: guitarRing)
        let guitar = guitarBands.analyzedSeconds > 0 ? guitarBands : nil

        adviceTask = Task { [adviceRunner, cliPath, rigURL] in
            let rigResult = await RigSource.fetch(url: rigURL)
            let outcome: AdviceOutcome
            switch rigResult {
            case .failure(.unavailable(let reason)):
                outcome = .failure(reason)
            case .success(let rig):
                let payload = Payload.render(mix: mix, guitar: guitar, rig: rig)
                outcome = await adviceRunner.run(cliPath: cliPath, model: model, payload: payload)
            }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let answer, let usage): self.adviceState = .answer(text: answer, usage: usage, model: model)
            case .failure(let message): self.adviceState = .error(message)
            }
        }
    }

    func cancelAdvice() {
        adviceTask?.cancel()
        adviceTask = nil
        adviceState = .idle
        Task { [adviceRunner] in await adviceRunner.cancel() }
    }

    func selectInput(deviceUID: String?, ticks: Set<Int>) {
        self.selectedDeviceUID = deviceUID
        self.ticks = ticks
        interfaceInput.select(deviceUID: deviceUID, ticks: ticks.sorted())
    }

    private func refreshDeviceList() {
        devices = audioDevices.inputDevices
        selectedDeviceUID = interfaceInput.deviceUID
        ticks = Set(interfaceInput.ticks)
    }

    private func resetAnalyzers() {
        mixAnalyzer = SpectrumAnalyzer(timeConstant: timeConstant)
        guitarAnalyzer = SpectrumAnalyzer(timeConstant: timeConstant)
    }

    private func syncSessionState() {
        state = session.state
        scrubSeconds = session.scrubPosition / HistoryRing.sampleRate
        let upper = max(mixRing.head, HistoryRing.sampleRate) / HistoryRing.sampleRate
        let lower = mixRing.range.lowerBound / HistoryRing.sampleRate
        scrubRangeSeconds = lower...max(lower, upper)
        adviceAvailable = AdviceAvailability.isAvailable(historyRange: mixRing.range)
    }

    private func tick() {
        mixWorker.drain()
        guitarWorker.drain()
        refreshDeviceList()
        syncSessionState()

        let head = session.currentHead
        mixPoints = mixAnalyzer.advance(ring: mixRing, to: head)
        guitarPoints = interfaceInput.status == .running ? guitarAnalyzer.advance(ring: guitarRing, to: head) : nil
        banners = statusBanners(microphone: Permissions.microphoneStatus(),
                                systemAudioRecording: Permissions.systemAudioRecordingStatus(),
                                mix: mixTap.status)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner)
            }
            InputsPanel(devices: model.devices,
                       selectedDeviceUID: model.selectedDeviceUID,
                       ticks: model.ticks,
                       onSelect: model.selectInput)
            SpectrumGraphView(mixPoints: model.mixPoints, guitarPoints: model.guitarPoints)
            ControlsBar(state: model.state,
                       scrubRangeSeconds: model.scrubRangeSeconds,
                       scrubSeconds: $model.scrubSeconds,
                       pinned: $model.pinned,
                       timeConstant: $model.timeConstant,
                       onPause: model.pause,
                       onPlay: model.play,
                       onResumeLive: model.resumeLive,
                       onScrub: model.scrub,
                       onReset: model.reset)
            AdvicePanel(state: model.adviceState,
                       isAvailable: model.adviceAvailable,
                       model: $model.adviceModel,
                       onRequest: model.requestAdvice,
                       onCancel: model.cancelAdvice)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

private struct BannerView: View {
    let banner: StatusBanner

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(banner.title)
            Spacer()
            if let url = banner.settingsURL {
                Button("Open Settings") { NSWorkspace.shared.open(url) }
            }
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15))
    }
}
