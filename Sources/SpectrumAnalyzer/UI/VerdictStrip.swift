import SwiftUI

/// The strings the verdict strip shows for a verdict (R2, R4, R25, AE3).
struct VerdictText: Equatable {
    var direction: String
    var detail: String?
    var tone: String?
    var crest: String?
    var status: String?
    var isDimmed = false

    init(_ verdict: Verdict?, isPaused: Bool = false, referenceTooShort: Bool = false) {
        direction = referenceTooShort ? "Reference too short \u{2014} set it again" : "Play, then press Set reference"
        if let verdict {
            if let unity = verdict.unitySteps {
                let db = Float(unity) * verdict.unityStepDB
                direction = unity > 0 ? "louder \u{2192} turn down" : unity < 0 ? "quieter \u{2192} turn up" : "Unity \u{2713}"
                detail = unity == 0 ? nil : Self.signed(db) + " dB"
            } else {
                direction = "Keep playing"
                detail = String(format: "%.0f / %.0f s", verdict.activeSeconds.rounded(.down), verdict.windowSeconds)
            }
            if let toneSteps = verdict.toneSteps {
                let bands = toneSteps.filter { $0 != 0 }.count
                tone = bands == 0 ? "Tone \u{2713}" : "Tone: \(bands) band" + (bands == 1 ? "" : "s")
            }
            if let crestSteps = verdict.crestSteps, crestSteps != 0 {
                let db = String(format: "%.0f", abs(Float(crestSteps) * VerdictTracker.crestStepDB))
                crest = crestSteps < 0 ? "dynamics squashed by \(db) dB" : "dynamics opened up by \(db) dB"
            }
        }
        if isPaused {
            status = "Paused"
            isDimmed = true
        }
    }

    private static func signed(_ db: Float) -> String {
        (db < 0 ? "\u{2212}" : "+") + String(format: "%.0f", abs(db))
    }
}

/// The verdict in large type with Set reference and the Reference menu. It
/// observes only the published text, which changes when a step does (KTD7).
/// Display mode has Set reference in its touch row and the menu in More.
struct VerdictStrip: View {
    @ObservedObject var live: LiveLevels
    let model: AppModel
    @Environment(\.displaySizes) private var sizes

    var body: some View {
        let text = live.verdictText
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(text.direction).font(sizes.verdict)
            if let detail = text.detail { Text(detail).font(.title3).monospacedDigit() }
            VStack(alignment: .leading, spacing: 0) {
                if let crest = text.crest { Text(crest) }
                if let tone = text.tone { Text(tone) }
            }
            .foregroundStyle(.secondary)
            if let status = text.status { Text(status).foregroundStyle(.secondary) }
            // Messages sit left of the spacer, so one appearing never moves the buttons.
            if let warning = ClipLatch.warning(live.clipping) {
                Text(warning).foregroundStyle(.red).fontWeight(.semibold)
            }
            ReferenceStatus(model: model)
            Spacer(minLength: 0)
            if !sizes.isDisplayMode {
                Button("Set reference", action: model.setReference)
                    .buttonStyle(.borderedProminent)
                ReferenceMenu(model: model)
            }
        }
        .opacity(text.isDimmed ? 0.5 : 1)
        .padding(.horizontal, sizes.isDisplayMode ? 20 : 8)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.05))
    }
}

/// The last Set reference's outcome, or the snapshot store's error.
struct ReferenceStatus: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let error = model.snapshotError {
            Text(error).foregroundStyle(.red).lineLimit(1)
        } else {
            Text(model.referenceStatus).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// Clear, Save as and Snapshots.
struct ReferenceMenu: View {
    @ObservedObject var model: AppModel
    @State private var isNaming = false
    @State private var isShowingSnapshots = false
    @State private var draftName = ""

    var body: some View {
        HStack {
            Menu("Reference") {
                Button("Clear", action: model.clearReference).disabled(model.reference == nil)
                Button("Save as\u{2026}") {
                    draftName = model.reference?.name ?? ""
                    isNaming = true
                }
                .disabled(model.reference == nil)
                Button("Snapshots\u{2026}") { isShowingSnapshots = true }
            }
            .fixedSize()
        }
        .alert("Save reference as", isPresented: $isNaming) {
            TextField("Song \u{2014} part", text: $draftName)
            Button("Save") { model.saveSnapshot(name: draftName.trimmingCharacters(in: .whitespaces)) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $isShowingSnapshots) { SnapshotsSheet(model: model) }
    }
}
