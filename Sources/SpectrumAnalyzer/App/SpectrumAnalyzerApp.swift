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
        // Stays on the laptop, with the keyboard, while the main window runs on a tablet.
        Window("AI advice", id: AdviceHost.windowID) {
            AdviceHost(model: model, isInWindow: true)
                .frame(minWidth: AdviceWindowPlacer.minWidth, minHeight: 300)
                .background(AdviceWindowPlacer())
                .onAppear { model.adviceInWindow = true }
                .onDisappear { model.adviceInWindow = false }
        }
    }
}

/// Wires capture, history, analysis and replay into the published state the
/// window renders, redrawing at 30 fps (KTD5).
@MainActor
final class AppModel: ObservableObject {
    let graph = LiveSink(GraphFrame())
    let octaves = LiveSink(OctaveFrame())
    /// Real-time follows the signal like Friture; Tune shows figures over the
    /// window of playing, which hold still while you turn a knob.
    @Published var viewMode = UserDefaults.standard.string(forKey: "view.mode").flatMap(ViewMode.init(rawValue:)) ?? .tune {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: "view.mode")
            guitarOctaves = OctaveLevels()
            mixOctaves = OctaveLevels()
            octaveCaps.reset()
            refreshComparison()
        }
    }
    @Published var showPeakHold = UserDefaults.standard.bool(forKey: "graph.showPeakHold") {
        didSet {
            UserDefaults.standard.set(showPeakHold, forKey: "graph.showPeakHold")
            peakHold.reset()
        }
    }
    /// Whole dB; sizes the reference corridor and the tone figures.
    @Published var toneStep = UserDefaults.standard.object(forKey: "levels.toneStep") as? Int ?? 1 {
        didSet {
            UserDefaults.standard.set(toneStep, forKey: "levels.toneStep")
            verdictTracker.toneStepDB = Float(toneStep)
            refreshComparison()
        }
    }
    /// Whole dB; the unity figure's step.
    @Published var unityStep = UserDefaults.standard.object(forKey: "levels.unityStep") as? Int ?? 2 {
        didSet {
            UserDefaults.standard.set(unityStep, forKey: "levels.unityStep")
            verdictTracker.unityStepDB = Float(unityStep)
            refreshComparison()
        }
    }
    @Published var banners: [StatusBanner] = []
    @Published var pinned = false
    @Published var timeConstant = 3.0 { didSet { resetAnalyzers() } }
    @Published var state: SessionState = .live
    let scrub = LiveSink(ScrubPosition())
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
    /// The advice panel is in its own window instead of the main one.
    @Published var adviceInWindow = false
    @Published var guitarThresholdDBFS = AppModel.storedThreshold("levels.guitarThreshold") {
        didSet {
            UserDefaults.standard.set(guitarThresholdDBFS, forKey: "levels.guitarThreshold")
            exportDirty = true
        }
    }
    @Published var mixThresholdDBFS = AppModel.storedThreshold("levels.mixThreshold") {
        didSet {
            UserDefaults.standard.set(mixThresholdDBFS, forKey: "levels.mixThreshold")
            exportDirty = true
        }
    }
    /// The outcome of the last Learn noise, shown next to its button.
    @Published var noiseMessage = ""
    /// N for Set reference and the live comparison: 5, 10 or 20 active seconds.
    @Published var windowSeconds = UserDefaults.standard.object(forKey: "levels.windowSeconds") as? Int ?? 10 {
        didSet {
            UserDefaults.standard.set(windowSeconds, forKey: "levels.windowSeconds")
            exportDirty = true
        }
    }
    @Published var reference: Reference? {
        didSet {
            exportDirty = true
            referencePoints = reference.flatMap { $0.isFull ? GraphScale.points(of: $0) : nil }
            verdictTracker.clear()
        }
    }
    @Published var displayMode = false
    /// Off by default and remembered; turning it on starts the loopback listener.
    @Published var exportEnabled = UserDefaults.standard.bool(forKey: "export.enabled") {
        didSet {
            UserDefaults.standard.set(exportEnabled, forKey: "export.enabled")
            if exportEnabled { startExport() } else { stopExport() }
        }
    }
    @Published var exportStatus = ""
    @Published var snapshots: [Snapshot] = []
    @Published var snapshotError: String?
    let live = LiveLevels()
    /// The outcome of the last Set reference, shown next to its button.
    @Published var referenceStatus = ""
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
    private var peakHold = PeakHold()
    private var verdictTracker = VerdictTracker()
    private var referencePoints: [SpectrumPoint]?
    /// Tune: the curves the graph shows instead of the live FFT.
    private var tuneCurves: (guitar: [SpectrumPoint]?, mix: [SpectrumPoint]) = (nil, [])
    private let snapshotStore = SnapshotStore()
    private let exportServer = LocalServer()
    private var exportRunning = false
    /// Tells a start that was superseded by a stop or restart to stay silent.
    private var exportGeneration = 0
    /// Set by anything the export document shows besides the logs' growth.
    private var exportDirty = false
    private var exportSequence = 0
    private var tickCount = 0
    /// The raw readings and the comparison refresh at 10 Hz; the meters
    /// themselves move every tick.
    private static let levelsEveryTicks = 3
    /// The frames each meter last read up to.
    private var guitarMeterHead = 0
    private var mixMeterHead = 0
    private var guitarOctaves = OctaveLevels()
    private var mixOctaves = OctaveLevels()
    private var octaveCaps = PeakHold()
    /// Each permission check is a synchronous round trip to tccd on the main
    /// thread, so it runs once a second, not every frame.
    private static let permissionsEveryTicks = 30
    private var microphoneStatus = PermissionStatus.unknown
    private var systemAudioStatus = PermissionStatus.unknown
    private var exportBuiltAt = Date.distantPast
    /// Meter readings change every tick; the document follows them this often.
    private static let exportRefreshInterval: TimeInterval = 0.25
    private var displayMemory = DisplayModeMemory(remembered: UserDefaults.standard.string(forKey: "display.screen"))
    /// The guitar log's sequence number when the reference was set or loaded;
    /// only hops logged since then count toward the comparison.
    private var referenceMark = 0
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
        session.onStateChange = { [weak self] in
            self?.exportDirty = true
            self?.syncSessionState()
        }
        exportServer.onFailure.withLock { $0 = { [weak self] message in
            Task { @MainActor in self?.exportFailed(message) }
        } }

        verdictTracker.unityStepDB = Float(unityStep)
        verdictTracker.toneStepDB = Float(toneStep)
        snapshots = snapshotStore.snapshots
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
        if exportEnabled { startExport() }
    }

    func pause() { session.pause() }
    func play() {
        peakHold.reset()
        session.play()
    }
    func resumeLive() {
        mixLog.markBreak()
        guitarLog.markBreak()
        peakHold.reset()
        session.resumeLive()
    }

    func reset() {
        session.reset()
        peakHold.reset()
        mixLog.reset()
        guitarLog.reset()
        referenceMark = guitarLog.nextSequence
        verdictTracker.clear()
    }

    /// By hand; the screen the window is on is remembered (KTD10).
    func setDisplayMode(_ on: Bool) {
        displayMemory.setOn(on)
        syncDisplayMode()
    }

    func screenChanged(_ name: String?) {
        displayMemory.screenChanged(to: name)
        syncDisplayMode()
    }

    private func syncDisplayMode() {
        displayMode = displayMemory.isOn
        UserDefaults.standard.set(displayMemory.remembered, forKey: "display.screen")
    }

    /// `export.port` is a hidden override, like `advice.rigURL`.
    private var exportPort: UInt16 {
        UInt16(exactly: UserDefaults.standard.integer(forKey: "export.port")).flatMap { $0 > 0 ? $0 : nil } ?? LocalServer.defaultPort
    }

    private func startExport() {
        guard !exportRunning else { return }
        exportRunning = true
        exportGeneration += 1
        let generation = exportGeneration
        exportStatus = "Starting\u{2026}"
        let port = exportPort
        refreshExport()
        Task {
            do {
                let bound = try await exportServer.start(port: port)
                if generation == exportGeneration { exportStatus = "http://127.0.0.1:\(bound)/levels" }
            } catch {
                if generation == exportGeneration { exportFailed("Port \(port) unavailable: \(error.localizedDescription)") }
            }
        }
    }

    private func stopExport() {
        exportGeneration += 1
        exportRunning = false
        exportServer.stop()
        exportStatus = ""
    }

    private func exportFailed(_ message: String) {
        exportRunning = false
        exportServer.stop()
        exportStatus = message
    }

    /// Rebuilds the bytes the listener serves (KTD11).
    private func refreshExport() {
        guard exportRunning else { return }
        exportBuiltAt = Date()
        let guitar = interfaceInput.status == .running
            ? ExportSource(log: guitarLog, thresholdDBFS: guitarThresholdDBFS, reading: live.rawGuitar) : nil
        let mix = ExportSource(log: mixLog, thresholdDBFS: mixThresholdDBFS, reading: live.rawMix)
        exportServer.update(LevelsDocument.make(state: state, windowSeconds: windowSeconds, guitar: guitar, mix: mix,
                                                reference: reference, comparison: live.comparison, now: Date()).encoded())
    }

    private var windowHops: Int { Int(Double(windowSeconds) / Payload.hopSeconds) }
    /// Paused or replaying, the windows end where the scrubber is.
    private var windowEnd: Int { session.isLive ? .max : session.currentHead }

    /// Stores the guitar's last N active seconds as the reference (KTD7); a
    /// shorter window is refused and the reference stays as it was (R25).
    func setReference() {
        let guitar = guitarLog.window(threshold: guitarThresholdDBFS, limit: windowHops, upTo: windowEnd)
        let mix = mixLog.window(threshold: mixThresholdDBFS, limit: windowHops, upTo: windowEnd)
        guard guitar.hops.count >= windowHops,
              let made = Reference.make(guitar: guitar, mix: mix, windowSeconds: windowSeconds) else {
            referenceStatus = String(format: "Need %d s of playing, have %.0f", windowSeconds, guitar.activeSeconds.rounded(.down))
            return
        }
        reference = made
        referenceMark = guitarLog.nextSequence
        referenceStatus = String(format: "Reference set from %.1f of %d s", made.activeSeconds, windowSeconds)
        refreshComparison()
    }

    /// Saves the current reference under `name`; the reference takes the name too.
    func saveSnapshot(name: String) {
        guard let reference, !name.isEmpty else { return }
        snapshotStore.save(reference, name: name)
        self.reference?.name = name
        syncSnapshots()
    }

    func renameSnapshot(_ id: UUID, to name: String) {
        snapshotStore.rename(id, to: name)
        syncSnapshots()
    }

    func deleteSnapshot(_ id: UUID) {
        snapshotStore.delete(id)
        syncSnapshots()
    }

    private func syncSnapshots() {
        snapshots = snapshotStore.snapshots
        snapshotError = snapshotStore.lastError
    }

    /// Makes a snapshot the current reference and restarts the partial count.
    func loadSnapshot(_ id: UUID) {
        guard let snapshot = snapshots.first(where: { $0.id == id }) else { return }
        reference = snapshot.reference
        referenceMark = guitarLog.nextSequence
        referenceStatus = "Loaded \(snapshot.name)"
        refreshComparison()
    }

    func clearReference() {
        reference = nil
        refreshComparison()
        referenceStatus = ""
    }

    private func refreshComparison() {
        let comparison = reference.flatMap { $0.isFull ? $0 : nil }.map {
            Comparison.make(reference: $0, window: guitarLog.window(threshold: guitarThresholdDBFS, limit: windowHops, since: referenceMark, upTo: windowEnd),
                            windowHops: windowHops)
        }
        live.setComparison(comparison)
        live.setVerdict(verdictTracker.update(comparison), isPaused: state != .live,
                        referenceTooShort: reference.map { !$0.isFull } ?? false)
        let referenceLoudness = reference.map { Loudness.db(bands: $0.guitarBands) }
        let isTune = viewMode == .tune
        let history = HistoryFrame(points: isTune ? HistoryScale.tunePoints(log: guitarLog, thresholdDBFS: guitarThresholdDBFS)
                                                  : HistoryScale.points(log: guitarLog),
                                   referenceLoudnessDB: referenceLoudness, isTune: isTune)
        if history != live.history.value { live.history.send(history) }
        if isTune {
            refreshTuneFigures(comparison: comparison)
        } else {
            live.setTable(nil)
        }
    }

    /// Tune: the figures and octave bars over the same window the verdict
    /// reads, so they change only as new playing lands.
    private func refreshTuneFigures(comparison: Comparison?) {
        // Scrubbed back, the curves show the playing there, even from before the reference.
        let guitarWindow = interfaceInput.status == .running
            ? guitarLog.window(threshold: guitarThresholdDBFS, limit: windowHops, since: session.isLive ? referenceMark : 0,
                               upTo: windowEnd) : nil
        let mixWindow = mixLog.window(threshold: mixThresholdDBFS, limit: windowHops, upTo: windowEnd)
        live.setTable(LevelsTable(guitar: guitarWindow, mix: mixWindow, reference: reference, comparison: comparison,
                                  windowSeconds: windowSeconds))
        let bars = { (window: ActiveWindow) in window.hops.isEmpty ? nil : OctaveLevels.points(bandPower: window.bandPower) }
        let curve = { (window: ActiveWindow) in window.hops.isEmpty ? nil : GraphScale.points(displayPower: window.displayPower) }
        tuneCurves = (guitarWindow.flatMap(curve), curve(mixWindow) ?? [])
        let frame = OctaveFrame(guitar: guitarWindow.flatMap(bars),
                                mix: bars(mixWindow) ?? [],
                                reference: comparison.flatMap { comparison in
                                    reference.map { GraphScale.shifted(OctaveLevels.points(bandPower: $0.guitarBands),
                                                                       by: comparison.loudnessDifferenceDB ?? 0) }
                                },
                                windowSeconds: windowSeconds)
        if frame != octaves.value { octaves.send(frame) }
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
        peakHold.reset()
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
        setIfChanged(\.selectedDeviceUID, interfaceInput.deviceUID)
        setIfChanged(\.ticks, Set(interfaceInput.ticks))
    }

    /// `@Published` announces every assignment, equal or not, and the tick
    /// runs 30 times a second; only a real change should re-render the window.
    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
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
        setIfChanged(\.state, session.state)
        // `scrubPosition` stays at the frame replay started from, so the
        // thumb has to follow the analyzer head to move during playback.
        let upper = max(mixRing.head, HistoryRing.sampleRate) / HistoryRing.sampleRate
        let lower = mixRing.range.lowerBound / HistoryRing.sampleRate
        let position = ScrubPosition(seconds: session.currentHead / HistoryRing.sampleRate,
                                     rangeSeconds: lower...max(lower, upper))
        if position != scrub.value { scrub.send(position) }
        setIfChanged(\.adviceAvailable, AdviceAvailability.isAvailable(historyRange: mixRing.range))
    }

    /// The frames of `ring` after `last`, up to `head` but never past what is
    /// written: the live clock runs a capture chunk ahead of the ring. At most
    /// 1 s, so a jump in the head does not stall a tick.
    private static func unread(_ ring: HistoryRing, upTo head: Int, after last: inout Int) -> [Int16] {
        let end = min(head, ring.head)
        let count = min(max(end - last, 0), HistoryRing.sampleRate)
        last = end
        return ring.read(from: end - count, count: count)
    }

    private func tick() {
        tickCount &+= 1
        mixWorker.drain()
        guitarWorker.drain()
        refreshDeviceList()
        syncSessionState()

        if session.isLive {
            mixLog.advance(ring: mixRing, to: mixRing.head)
            guitarLog.advance(ring: guitarRing, to: guitarRing.head)
        }

        let head = session.currentHead
        let mixPoints = mixAnalyzer.advance(ring: mixRing, to: head)
        let guitarPoints = interfaceInput.status == .running ? guitarAnalyzer.advance(ring: guitarRing, to: head) : nil
        if showPeakHold, let guitarPoints {
            peakHold.update(with: guitarPoints, elapsedSeconds: SpectrumAnalyzer.liveHopSeconds)
        }
        let isTune = viewMode == .tune
        graph.send(GraphFrame(guitar: isTune ? tuneCurves.guitar : guitarPoints,
                              mix: isTune ? tuneCurves.mix : mixPoints,
                              peakHold: !isTune && showPeakHold && guitarPoints != nil ? peakHold.points : nil,
                              reference: referencePoints,
                              referenceOffsetDB: live.comparison?.loudnessDifferenceDB ?? 0,
                              toneStepDB: Float(toneStep),
                              toneSteps: live.verdict?.toneSteps,
                              windowSeconds: isTune ? windowSeconds : nil))
        let guitarRunning = interfaceInput.status == .running
        let guitarMeterFrames = Self.unread(guitarRing, upTo: head, after: &guitarMeterHead)
        live.showMeters(guitar: guitarRunning ? guitarMeterFrames : nil,
                        mix: Self.unread(mixRing, upTo: head, after: &mixMeterHead),
                        seconds: SpectrumAnalyzer.liveHopSeconds)
        if viewMode == .realtime {
            let guitarBands = guitarRunning
                ? guitarOctaves.update(ring: guitarRing, head: min(head, guitarRing.head), seconds: SpectrumAnalyzer.liveHopSeconds) : nil
            if let guitarBands {
                octaveCaps.update(with: guitarBands, elapsedSeconds: SpectrumAnalyzer.liveHopSeconds)
            } else {
                guitarOctaves = OctaveLevels()
                octaveCaps.reset()
            }
            octaves.send(OctaveFrame(guitar: guitarBands,
                                     mix: mixOctaves.update(ring: mixRing, head: min(head, mixRing.head), seconds: SpectrumAnalyzer.liveHopSeconds),
                                     caps: guitarBands != nil ? octaveCaps.points : nil))
        }
        if tickCount % Self.levelsEveryTicks == 0 {
            live.setMeters(guitar: interfaceInput.status == .running ? LevelMeter.read(ring: guitarRing, head: head) : nil,
                           mix: LevelMeter.read(ring: mixRing, head: head),
                           seconds: SpectrumAnalyzer.liveHopSeconds * Double(Self.levelsEveryTicks))
            refreshComparison()
        }
        if case .unavailable(let status) = interfaceInput.status { setIfChanged(\.inputFailure, status) } else { setIfChanged(\.inputFailure, nil) }
        let sequence = mixLog.nextSequence + guitarLog.nextSequence
        if exportDirty || sequence != exportSequence || Date().timeIntervalSince(exportBuiltAt) >= Self.exportRefreshInterval {
            exportDirty = false
            exportSequence = sequence
            refreshExport()
        }
        if tickCount % Self.permissionsEveryTicks == 1 {
            microphoneStatus = Permissions.microphoneStatus()
            systemAudioStatus = Permissions.systemAudioRecordingStatus()
        }
        setIfChanged(\.banners, statusBanners(microphone: microphoneStatus,
                                              systemAudioRecording: systemAudioStatus,
                                              mix: mixTap.status))
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var isShowingMore = false
    @State private var displayHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner)
            }
            if model.displayMode {
                displayLayout
            } else {
                normalLayout
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .environment(\.displaySizes, model.displayMode ? .display : .normal)
        .background(ScreenReader(onChange: model.screenChanged))
        .sheet(isPresented: $isShowingMore) { moreSheet }
    }

    private var normalLayout: some View {
        VStack(spacing: 0) {
            inputsPanel
            VSplitView {
                VStack(spacing: 0) {
                    VerdictStrip(live: model.live, model: model)
                    graph.frame(minHeight: 220)
                    OctaveBars(sink: model.octaves).frame(height: 130)
                    // Details takes what is left above the graph's minimum, never more.
                    LevelsPanel(model: model).layoutPriority(1)
                    controlsBar
                }
                // No fixed minimum: the children's sum is the minimum, so it
                // grows when Details opens.
                .frame(idealHeight: 520)
                if !model.adviceInWindow {
                    AdviceHost(model: model, isInWindow: false)
                        .frame(minHeight: 80, idealHeight: 360)
                }
            }
        }
    }

    /// The verdict, the graphs on one frequency axis, the levels table, the
    /// history and the touch row; everything else is in More.
    private var displayLayout: some View {
        let heights = PaneHeights(windowHeight: displayHeight)
        return VStack(spacing: 0) {
            VerdictStrip(live: model.live, model: model)
            graph.frame(minHeight: 120)
            Divider()
            OctaveBars(sink: model.octaves).frame(height: heights.octave)
            Divider()
            LevelsPanel(model: model, displayHeights: heights)
            DisplayTouchRow(state: model.state,
                            onPause: model.pause,
                            onResumeLive: model.resumeLive,
                            onSetReference: model.setReference,
                            onReset: model.reset,
                            onMore: { isShowingMore = true })
                .background(.primary.opacity(0.05))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { displayHeight = $0 }
    }

    private var moreSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { isShowingMore = false }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.extraLarge)
            }
            .padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    inputsPanel
                    controlsBar
                    ReferenceMenu(model: model).padding(.horizontal, 8)
                    LevelsControls(model: model).padding(.horizontal, 8)
                    if !model.adviceInWindow {
                        AdviceHost(model: model, isInWindow: false).frame(minHeight: 360)
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 600)
    }

    private var graph: some View {
        SpectrumGraphView(sink: model.graph)
    }

    private var inputsPanel: some View {
        InputsPanel(devices: model.devices,
                    selectedDeviceUID: model.selectedDeviceUID,
                    ticks: model.ticks,
                    failure: model.inputFailure,
                    onSelect: model.selectInput)
    }

    private var controlsBar: some View {
        ControlsBar(state: model.state,
                    scrub: model.scrub,
                    pinned: $model.pinned,
                    viewMode: $model.viewMode,
                    showPeakHold: $model.showPeakHold,
                    displayMode: Binding(get: { model.displayMode }, set: { model.setDisplayMode($0) }),
                    timeConstant: $model.timeConstant,
                    onPause: model.pause,
                    onPlay: model.play,
                    onResumeLive: model.resumeLive,
                    onScrub: model.scrub,
                    onReset: model.reset)
    }
}

/// The advice panel with its header, which moves it into its own window and
/// back into the main one.
struct AdviceHost: View {
    static let windowID = "advice"
    @ObservedObject var model: AppModel
    let isInWindow: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AI advice").font(.headline)
                Spacer()
                if isInWindow {
                    Button("Attach window") { dismissWindow(id: Self.windowID) }
                        .help("Close this window and show the advice in the main window again")
                } else {
                    Button("Detach window") { openWindow(id: Self.windowID) }
                        .help("Show the advice in its own window, for example on the laptop while the main window is on a tablet")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            panel
        }
    }

    private var panel: some View {
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
    }
}

/// Lists the advice window in the Dock and Window menus, which SwiftUI leaves
/// out for a `Window` scene, and docks it to the main window's side.
struct AdviceWindowPlacer: NSViewRepresentable {
    static let minWidth: Double = 640

    func makeNSView(context: Context) -> NSView { PlacerView() }
    func updateNSView(_ view: NSView, context: Context) {}

    /// Edge to edge with the main window, same top and height: right, else
    /// left, else the main window shifts left to make room on its right.
    static func docked(advice width: Double, main: NSRect, in visible: NSRect) -> (main: NSRect, advice: NSRect) {
        let width = min(width, max(minWidth, visible.width - main.width))
        var main = main
        var advice = NSRect(x: main.maxX, y: main.minY, width: width, height: main.height)
        if main.minX - width >= visible.minX && advice.maxX > visible.maxX {
            advice.origin.x = main.minX - width
        } else if advice.maxX > visible.maxX {
            main.origin.x = max(visible.minX, visible.maxX - width - main.width)
            advice.origin.x = main.maxX
        }
        return (main, advice)
    }

    private final class PlacerView: NSView {
        override func viewDidMoveToWindow() {
            guard let window else { return }
            window.isExcludedFromWindowsMenu = false
            // After SwiftUI restores the saved frame and orders the window.
            DispatchQueue.main.async { [weak window] in
                guard let window,
                      let main = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.canBecomeMain }),
                      let screen = main.screen else { return }
                // The main window on the tablet: the advice stays on the laptop where it was.
                if window.screen == screen {
                    let docked = AdviceWindowPlacer.docked(advice: window.frame.width, main: main.frame, in: screen.visibleFrame)
                    main.setFrame(docked.main, display: true)
                    window.setFrame(docked.advice, display: true)
                }
                window.makeKeyAndOrderFront(nil)
            }
        }
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
