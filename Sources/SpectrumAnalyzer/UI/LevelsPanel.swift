import SwiftUI

/// Live RMS and peak for guitar and mix (R5), the activity thresholds, and
/// Set reference with its live comparison (R7, R8), between the graph and the
/// controls. The guitar meter reads unavailable while the interface is not
/// captured.
struct LevelsPanel: View {
    @ObservedObject var model: AppModel
    @State private var isNaming = false
    @State private var isShowingSnapshots = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 24) {
                MeterView(title: "Guitar", reading: model.guitarLevel)
                MeterView(title: "Mix", reading: model.mixLevel)
                Spacer()
            }
            HStack {
                thresholdField("Guitar threshold", value: $model.guitarThresholdDBFS, source: .guitar)
                thresholdField("Mix threshold", value: $model.mixThresholdDBFS, source: .mix)
                Text(model.noiseMessage).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            HStack {
                Button("Set reference", action: model.setReference)
                Button("Clear", action: model.clearReference).disabled(model.reference == nil)
                Button("Save as\u{2026}") {
                    draftName = model.reference?.name ?? ""
                    isNaming = true
                }
                .disabled(model.reference == nil)
                Button("Snapshots\u{2026}") { isShowingSnapshots = true }
                Picker("Window", selection: $model.windowSeconds) {
                    ForEach([5, 10, 20], id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Text(model.referenceStatus).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            if model.reference != nil {
                ComparisonView(comparison: model.comparison, windowSeconds: model.windowSeconds)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .alert("Save reference as", isPresented: $isNaming) {
            TextField("Song \u{2014} part", text: $draftName)
            Button("Save") { model.saveSnapshot(name: draftName.trimmingCharacters(in: .whitespaces)) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $isShowingSnapshots) { SnapshotsSheet(model: model) }
    }

    private func thresholdField(_ title: String, value: Binding<Float>, source: AppModel.LevelSource) -> some View {
        HStack(spacing: 4) {
            Text(title)
            TextField("", value: value, format: .number.precision(.fractionLength(0)))
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
            Text("dBFS")
            Button("Learn noise") { model.learnNoise(source) }
                .help("Press while not playing: sets the threshold to the last 3 s of noise plus 10 dB")
        }
    }
}

/// The overall difference and the 10 octave-band differences, each as a
/// signed number with a bar centred on 0 dB, marked partial until N active
/// seconds have accumulated since the press.
private struct ComparisonView: View {
    let comparison: Comparison?
    let windowSeconds: Int

    /// Bars span +/-12 dB.
    private static let spanDB: Float = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Overall").font(.headline)
                Text(Self.signed(comparison?.levelDifferenceDB) + " dB").monospacedDigit()
                if let comparison {
                    Text(String(format: "%.1f / %d s", comparison.activeSeconds, windowSeconds))
                        .foregroundStyle(.secondary).monospacedDigit()
                    if comparison.partial { Text("partial").foregroundStyle(.orange) }
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<OctaveBands.labels.count, id: \.self) { i in
                    let difference = comparison?.octaveDifferencesDB?[i]
                    VStack(spacing: 2) {
                        Text(OctaveBands.labels[i]).font(.caption)
                        Text(Self.signed(difference)).font(.caption).monospacedDigit()
                        CenteredBar(value: difference.map { CGFloat(min(max($0 / Self.spanDB, -1), 1)) })
                    }
                    .frame(minWidth: 40)
                }
            }
        }
    }

    private static func signed(_ value: Float?) -> String {
        guard let value else { return "\u{2014}" }
        return String(format: "%+.1f", value)
    }
}

private struct CenteredBar: View {
    /// -1...1, nil for no reading.
    let value: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let half = geometry.size.width / 2
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                if let value {
                    Rectangle().fill(.tint)
                        .frame(width: abs(value) * half)
                        .offset(x: value < 0 ? half + value * half : half)
                }
                Rectangle().fill(.secondary).frame(width: 1).offset(x: half)
            }
        }
        .frame(height: 8)
    }
}

private struct MeterView: View {
    let title: String
    let reading: LevelReading?

    /// Bar spans -60 dBFS to 0 dBFS.
    private static let floorDBFS: Float = -60

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                if let reading {
                    Text("RMS \(LevelMeter.format(reading.rmsDBFS))").monospacedDigit()
                    Text("Peak \(LevelMeter.format(reading.peakDBFS)) dBFS").monospacedDigit()
                } else {
                    Text("not captured").foregroundStyle(.secondary)
                }
            }
            bar(for: reading)
        }
    }

    private func bar(for reading: LevelReading?) -> some View {
        GeometryReader { geometry in
            let fraction = reading.map { Self.fraction($0.rmsDBFS) } ?? 0
            let peak = reading.map { Self.fraction($0.peakDBFS) } ?? 0
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                Rectangle().fill(.tint).frame(width: geometry.size.width * fraction)
                Rectangle().fill(.primary).frame(width: 2).offset(x: max(0, geometry.size.width * peak - 2))
                    .opacity(reading == nil ? 0 : 1)
            }
        }
        .frame(width: 200, height: 8)
    }

    private static func fraction(_ dBFS: Float) -> CGFloat {
        guard dBFS.isFinite else { return 0 }
        return CGFloat(min(max((dBFS - floorDBFS) / -floorDBFS, 0), 1))
    }
}

/// Lists saved snapshots with Load, Rename and Delete (R12, R13).
private struct SnapshotsSheet: View {
    @ObservedObject var model: AppModel
    @State private var renaming: UUID?
    @State private var draftName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Snapshots").font(.headline)
            if model.snapshots.isEmpty {
                Text("None saved. Set a reference, then Save as\u{2026}").foregroundStyle(.secondary)
            }
            List(model.snapshots) { snapshot in
                HStack {
                    if renaming == snapshot.id {
                        TextField("Name", text: $draftName)
                            .onSubmit { commitRename(snapshot.id) }
                        Button("Done") { commitRename(snapshot.id) }
                    } else {
                        VStack(alignment: .leading) {
                            Text(snapshot.name)
                            Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Load") {
                            model.loadSnapshot(snapshot.id)
                            dismiss()
                        }
                        Button("Rename") {
                            draftName = snapshot.name
                            renaming = snapshot.id
                        }
                        Button("Delete", role: .destructive) { model.deleteSnapshot(snapshot.id) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480, height: 360)
    }

    private func commitRename(_ id: UUID) {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { model.renameSnapshot(id, to: name) }
        renaming = nil
    }
}
