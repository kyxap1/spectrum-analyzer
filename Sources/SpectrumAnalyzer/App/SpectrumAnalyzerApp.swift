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
    @Published var inputFailure: OSStatus?
    @Published var adviceState: AdviceState = .idle
    @Published var adviceProgress = ""
    @Published var adviceLiveUsage: AdviceUsage?
    @Published var adviceModel = UserDefaults.standard.string(forKey: "advice.model") ?? "sonnet" {
        didSet { UserDefaults.standard.set(adviceModel, forKey: "advice.model") }
    }
    @Published var adviceProfile = UserDefaults.standard.string(forKey: "advice.profile") ?? "claude-private" {
        didSet { UserDefaults.standard.set(adviceProfile, forKey: "advice.profile") }
    }
    @Published var adviceLanguage = UserDefaults.standard.string(forKey: "advice.language").flatMap(AdviceLanguage.init(rawValue:)) ?? .russian {
        didSet { UserDefaults.standard.set(adviceLanguage.rawValue, forKey: "advice.language") }
    }
    @Published var adviceGoal = UserDefaults.standard.string(forKey: "advice.goal").flatMap(AdviceGoal.init(rawValue:)) ?? .practice {
        didSet { UserDefaults.standard.set(adviceGoal.rawValue, forKey: "advice.goal") }
    }
    /// From the cached rig until a fresh fetch replaces it.
    @Published var rigPedals = FileRigCache().read().map { RigPedals.names(in: $0.text) } ?? []
    @Published var isRefreshingRig = false
    @Published var engagedPedals = Set(UserDefaults.standard.stringArray(forKey: "advice.engagedPedals") ?? []) {
        didSet { UserDefaults.standard.set(engagedPedals.sorted(), forKey: "advice.engagedPedals") }
    }
    @Published var rigNotes = UserDefaults.standard.string(forKey: "advice.rigNotes") ?? "" {
        didSet { UserDefaults.standard.set(rigNotes, forKey: "advice.rigNotes") }
    }
    @Published var advicePrompt = AdviceSettings.load(AdviceSettings.promptKey, default: AdviceSettings.defaultPrompt) {
        didSet { AdviceSettings.store(advicePrompt, AdviceSettings.promptKey, default: AdviceSettings.defaultPrompt) }
    }
    @Published var startingPositions = AdviceSettings.load(AdviceSettings.startingPositionsKey, default: AdviceSettings.defaultStartingPositions) {
        didSet { AdviceSettings.store(startingPositions, AdviceSettings.startingPositionsKey, default: AdviceSettings.defaultStartingPositions) }
    }
    @Published var adviceFetchDomains = AdviceSettings.load(AdviceSettings.fetchDomainsKey, default: AdviceSettings.defaultFetchDomains) {
        didSet { AdviceSettings.store(adviceFetchDomains, AdviceSettings.fetchDomainsKey, default: AdviceSettings.defaultFetchDomains) }
    }
    @Published var adviceAvailable = false
    @Published var guitarThresholdDBFS = AppModel.storedThreshold("levels.guitarThreshold") {
        didSet { UserDefaults.standard.set(guitarThresholdDBFS, forKey: "levels.guitarThreshold") }
    }
    @Published var mixThresholdDBFS = AppModel.storedThreshold("levels.mixThreshold") {
        didSet { UserDefaults.standard.set(mixThresholdDBFS, forKey: "levels.mixThreshold") }
    }
    /// The outcome of the last Learn noise, shown next to its button.
    @Published var noiseMessage = ""
    /// Survives a restart: the amp keeps its knob positions when the app quits.
    @Published var previousRound = UserDefaults.standard.data(forKey: "advice.previousRound").flatMap { try? JSONDecoder().decode(AdviceRound.self, from: $0) } {
        didSet { UserDefaults.standard.set(previousRound.flatMap { try? JSONEncoder().encode($0) }, forKey: "advice.previousRound") }
    }

    private let audioDevices = AudioDevices()
    /// Shared by `MixTap` and `InterfaceInput` so their HAL setup/teardown
    /// never runs concurrently — CoreAudio's aggregate-device create/destroy
    /// wedges coreaudiod when two devices race it from separate threads.
    private let audioHALQueue = DispatchQueue(label: "pro.kyxap.SpectrumAnalyzer.audioHAL")
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
    private let mixLog = BandLog()
    private let guitarLog = BandLog()
    private var timer: Timer?

    private static let cliPathKey = "advice.cliPath"
    private static let rigURLKey = "advice.rigURL"
    private let adviceRunner = AdviceRunner()
    private var cliPath: String { UserDefaults.standard.string(forKey: AppModel.cliPathKey) ?? "~/bin/\(adviceProfile)" }
    private let rigURL = UserDefaults.standard.string(forKey: AppModel.rigURLKey).flatMap(URL.init(string:)) ?? RigSource.defaultURL
    private var adviceTask: Task<Void, Never>?

    init() {
        mixTap = MixTap(queue: mixQueue,
                        outputDeviceUID: { [audioDevices] in audioDevices.defaultOutputDeviceUID },
                        halQueue: audioHALQueue)
        interfaceInput = InterfaceInput(queue: guitarQueue,
                                        inputDevices: { [audioDevices] in audioDevices.inputDevices },
                                        halQueue: audioHALQueue)
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
        // CoreAudio delivers these mid-notification; rebuilding devices
        // synchronously here re-enters the HAL and deadlocks the main thread.
        // Defer to the next run loop turn so the notification settles first.
        audioDevices.onDefaultOutputChange = { [mixTap] in
            Task { @MainActor in mixTap.rebuild() }
        }
        audioDevices.onDeviceListChange = { [weak self, interfaceInput] in
            Task { @MainActor in
                interfaceInput.deviceListChanged()
                self?.refreshDevices()
            }
        }
        session.onStateChange = { [weak self] in self?.syncSessionState() }

        Permissions.requestMicrophoneAccessIfNeeded()
        mixTap.start()
        interfaceInput.start()
        refreshDeviceList()
        refreshDevices()
        syncSessionState()

        let timer = Timer(timeInterval: SpectrumAnalyzer.liveHopSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // The capture queues hold under a second of audio, so draining must
        // keep running while a menu is open or the window is being resized.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        refreshRig()
    }

    func pause() { session.pause() }
    func play() { session.play() }
    func resumeLive() {
        mixLog.markBreak()
        guitarLog.markBreak()
        session.resumeLive()
    }

    func reset() {
        session.reset()
        mixLog.reset()
        guitarLog.reset()
    }

    enum LevelSource { case guitar, mix }

    /// Sets the source's threshold to the noise measured over the last few
    /// seconds, so it must be pressed while Live and not playing.
    func learnNoise(_ source: LevelSource) {
        let log = source == .guitar ? guitarLog : mixLog
        switch log.learnNoise(isLive: session.isLive) {
        case .learned(let threshold):
            if source == .guitar { guitarThresholdDBFS = threshold } else { mixThresholdDBFS = threshold }
            noiseMessage = String(format: "Threshold %.0f dBFS", threshold)
        case .silent: noiseMessage = "Digital silence: threshold unchanged."
        case .refused(let reason): noiseMessage = reason
        }
    }

    private static func storedThreshold(_ key: String) -> Float {
        UserDefaults.standard.object(forKey: key) as? Float ?? Payload.defaultThresholdDBFS
    }

    func scrub(toSeconds seconds: Int) {
        session.scrub(to: seconds * HistoryRing.sampleRate)
    }

    /// F2: builds the payload from both rings' whole kept history and runs
    /// the CLI. Replacing `adviceState` on cancel discards a late result.
    /// The analysis runs inside the `Task` so `.running` reaches the screen
    /// before the (possibly many-hop) FFT pass over the kept history.
    func requestAdvice() {
        guard adviceAvailable, adviceState != .running else { return }
        let model = adviceModel
        let instruction = [advicePrompt, adviceGoal.instruction, adviceLanguage.instruction].compactMap { $0 }.joined(separator: "\n\n")
        let fetchDomains = AdviceSettings.domains(from: adviceFetchDomains)
        let previous = previousRound
        let positions = startingPositions
        adviceState = .running
        adviceProgress = "Analyzing history\u{2026}"
        adviceLiveUsage = nil

        let mixThreshold = mixThresholdDBFS
        let guitarThreshold = guitarThresholdDBFS
        adviceTask = Task { [adviceRunner, cliPath, rigURL, mixRing, guitarRing] in
            let mix = Payload.analyze(ring: mixRing, thresholdDBFS: mixThreshold)
            let guitarBands = Payload.analyze(ring: guitarRing, thresholdDBFS: guitarThreshold)
            let guitar = guitarBands.analyzedSeconds > 0 ? guitarBands : nil

            self.adviceProgress = "Loading rig\u{2026}"
            let rigResult = await RigSource.fetch(url: rigURL)
            let outcome: AdviceOutcome
            switch rigResult {
            case .failure(.unavailable(let reason)):
                outcome = .failure(reason)
            case .success(let rig):
                self.rigPedals = RigPedals.names(in: rig.markdown)
                let rigState = RigPedals.state(pedals: self.rigPedals, engaged: self.engagedPedals, notes: self.rigNotes)
                let payload = Payload.render(mix: mix, guitar: guitar, rig: rig, instruction: instruction, rigState: rigState, startingPositions: positions, previous: previous)
                self.adviceProgress = "Waiting for \(model.capitalized)\u{2026}"
                outcome = await adviceRunner.run(cliPath: cliPath, model: model, payload: payload, fetchDomains: fetchDomains) { progress in
                    Task { @MainActor in
                        guard self.adviceState == .running else { return }
                        if let status = progress.status { self.adviceProgress = status }
                        self.adviceLiveUsage = progress.usage
                    }
                }
            }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let answer, let usage):
                self.adviceState = .answer(text: answer, usage: usage, model: model)
                self.previousRound = AdviceRound(date: Date(), bands: Payload.bandTable(mix: mix, guitar: guitar), answer: answer)
            case .failure(let message): self.adviceState = .error(message)
            }
        }
    }

    func refreshRig() {
        guard !isRefreshingRig else { return }
        isRefreshingRig = true
        Task { [rigURL] in
            if case .success(let rig) = await RigSource.fetch(url: rigURL) {
                self.rigPedals = RigPedals.names(in: rig.markdown)
            }
            self.isRefreshingRig = false
        }
    }

    /// Forgets the previous round, for when the rig is back at its defaults.
    func startOver() {
        previousRound = nil
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
        selectedDeviceUID = interfaceInput.deviceUID
        ticks = Set(interfaceInput.ticks)
    }

    /// `AudioDevices.inputDevices` makes CoreAudio HAL calls, which must never
    /// run on the main thread while `audioHALQueue` may be mid device
    /// create/start/destroy — CoreAudio's internal HAL lock is process-wide,
    /// so a concurrent call from main blocks until the HAL op completes,
    /// which can take tens of seconds and freezes the whole UI. Reading it
    /// here, on `audioHALQueue`, serializes it behind any in-flight HAL work.
    private func refreshDevices() {
        audioHALQueue.async { [audioDevices] in
            let devices = audioDevices.inputDevices
            Task { @MainActor [weak self] in self?.devices = devices }
        }
    }

    private func resetAnalyzers() {
        mixAnalyzer = SpectrumAnalyzer(timeConstant: timeConstant)
        guitarAnalyzer = SpectrumAnalyzer(timeConstant: timeConstant)
    }

    private func syncSessionState() {
        state = session.state
        // `scrubPosition` stays at the frame replay started from, so the
        // thumb has to follow the analyzer head to move during playback.
        scrubSeconds = session.currentHead / HistoryRing.sampleRate
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

        if session.isLive {
            mixLog.advance(ring: mixRing, to: mixRing.head)
            guitarLog.advance(ring: guitarRing, to: guitarRing.head)
        }

        let head = session.currentHead
        mixPoints = mixAnalyzer.advance(ring: mixRing, to: head)
        guitarPoints = interfaceInput.status == .running ? guitarAnalyzer.advance(ring: guitarRing, to: head) : nil
        if case .unavailable(let status) = interfaceInput.status { inputFailure = status } else { inputFailure = nil }
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
                       failure: model.inputFailure,
                       onSelect: model.selectInput)
            VSplitView {
                VStack(spacing: 0) {
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
                }
                .frame(minHeight: 220, idealHeight: 420)
                AdvicePanel(state: model.adviceState,
                           isAvailable: model.adviceAvailable,
                           progress: model.adviceProgress,
                           liveUsage: model.adviceLiveUsage,
                           model: $model.adviceModel,
                           profile: $model.adviceProfile,
                           language: $model.adviceLanguage,
                           goal: $model.adviceGoal,
                           prompt: $model.advicePrompt,
                           startingPositions: $model.startingPositions,
                           fetchDomains: $model.adviceFetchDomains,
                           pedals: model.rigPedals,
                           engagedPedals: $model.engagedPedals,
                           rigNotes: $model.rigNotes,
                           isRefreshingRig: model.isRefreshingRig,
                           onRefreshRig: model.refreshRig,
                           previousRoundDate: model.previousRound?.date,
                           onStartOver: model.startOver,
                           onRequest: model.requestAdvice,
                           onCancel: model.cancelAdvice)
                    .frame(minHeight: 80, idealHeight: 360)
            }
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
