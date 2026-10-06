import SwiftUI

/// Live RMS and peak for guitar and mix (R5) and the live comparison against
/// the reference (R8), between the graph and the controls. The controls
/// (thresholds, Set reference, snapshots) follow in normal mode and move into
/// the More sheet in display mode. The guitar meter reads unavailable while
/// the interface is not captured.
struct LevelsPanel: View {
    /// Not observed: the fast-changing parts watch `LiveLevels` themselves.
    let model: AppModel
    @Environment(\.displaySizes) private var sizes

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MetersRow(live: model.live)
            if !sizes.isDisplayMode {
                LevelsControls(model: model)
            }
            ComparisonSection(live: model.live)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

private struct MetersRow: View {
    @ObservedObject var live: LiveLevels
    @Environment(\.displaySizes) private var sizes

    var body: some View {
        HStack(alignment: .top, spacing: sizes.isDisplayMode ? 48 : 24) {
            MeterView(title: "Guitar", captured: live.hasGuitar, sink: live.guitarMeter)
            MeterView(title: "Mix", captured: live.hasMix, sink: live.mixMeter)
            Spacer()
        }
    }
}

private struct ComparisonSection: View {
    @ObservedObject var live: LiveLevels

    var body: some View {
        if let comparison = live.comparison {
            ComparisonView(comparison: comparison,
                           windowSeconds: Int(Double(comparison.windowHops) * Payload.hopSeconds))
        }
    }
}

/// Thresholds with Learn noise, Set reference, the window length and the
/// snapshots (R6, R7, R12, R13).
struct LevelsControls: View {
    @ObservedObject var model: AppModel
    @State private var isNaming = false
    @State private var isShowingSnapshots = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            if let error = model.snapshotError {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Toggle("Local data export", isOn: $model.exportEnabled)
                    .help("Serves the levels as JSON on 127.0.0.1 for a local agent; off until you turn it on")
                Text(model.exportStatus)
                    .foregroundStyle(model.exportStatus.hasPrefix("http") ? Color.secondary : Color.red)
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer()
            }
        }
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

/// The labels are SwiftUI; the numbers and the bar are AppKit views fed by the
/// sink, so a meter refresh redraws them without a SwiftUI update (KTD7).
private struct MeterView: View {
    let title: String
    let captured: Bool
    let sink: LiveSink<LevelReading?>
    @Environment(\.displaySizes) private var sizes

    /// Bar spans -60 dBFS to 0 dBFS.
    private static let floorDBFS: Float = -60

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title).font(sizes.label)
                if captured {
                    Text("RMS").font(sizes.label)
                    readout(\.rmsDBFS)
                    Text("Peak").font(sizes.label)
                    readout(\.peakDBFS)
                    Text("dBFS").font(sizes.label)
                } else {
                    Text("not captured").font(sizes.readout).foregroundStyle(.secondary)
                }
            }
            MeterBar(sink: sink)
                .frame(width: sizes.isDisplayMode ? 420 : 200, height: sizes.isDisplayMode ? 14 : 8)
        }
    }

    /// A fixed-width box, so a changing number never shifts its neighbours.
    private func readout(_ value: KeyPath<LevelReading, Float>) -> some View {
        MeterReadout(sink: sink, value: value, font: sizes.readoutNSFont)
            .frame(width: sizes.isDisplayMode ? 130 : 52)
    }

    static func fraction(_ dBFS: Float) -> CGFloat {
        guard dBFS.isFinite else { return 0 }
        return CGFloat(min(max((dBFS - floorDBFS) / -floorDBFS, 0), 1))
    }
}

private struct MeterReadout: NSViewRepresentable {
    let sink: LiveSink<LevelReading?>
    let value: KeyPath<LevelReading, Float>
    let font: NSFont

    func makeNSView(context: Context) -> ReadoutView {
        let view = ReadoutView()
        view.font = font
        sink.attach(view) { [value] view, reading in
            view.text = reading.map { LevelMeter.format($0[keyPath: value]) } ?? ""
        }
        return view
    }

    func updateNSView(_ view: ReadoutView, context: Context) {
        view.font = font
    }

    /// One line tall; without this SwiftUI stretches the view vertically.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReadoutView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }
}

/// Right-aligned text, redrawn only when it changes.
private final class ReadoutView: PassiveView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize) {
        didSet {
            guard font != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(font.ascender - font.descender + font.leading))
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        string.draw(at: NSPoint(x: bounds.width - size.width, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

private struct MeterBar: NSViewRepresentable {
    let sink: LiveSink<LevelReading?>

    func makeNSView(context: Context) -> MeterBarView {
        let view = MeterBarView()
        sink.attach(view) { view, reading in view.reading = reading }
        return view
    }

    func updateNSView(_ view: MeterBarView, context: Context) {}
}

/// Display only: clicks pass through to the SwiftUI gestures around it.
private class PassiveView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// RMS as a filled bar with the peak as a 2 pt line.
private final class MeterBarView: PassiveView {
    var reading: LevelReading? { didSet { if reading != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        bounds.fill(using: .sourceOver)
        guard let reading else { return }
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * MeterView.fraction(reading.rmsDBFS), height: bounds.height).fill(using: .sourceOver)
        NSColor.labelColor.setFill()
        NSRect(x: max(0, bounds.width * MeterView.fraction(reading.peakDBFS) - 2), y: 0, width: 2, height: bounds.height)
            .fill(using: .sourceOver)
    }
}

/// The overall difference and the 10 octave-band differences, each as a
/// signed number with a bar centred on 0 dB, marked partial until N active
/// seconds have accumulated since the press.
private struct ComparisonView: View {
    let comparison: Comparison
    let windowSeconds: Int
    @Environment(\.displaySizes) private var sizes

    /// Bars span +/-12 dB.
    private static let spanDB: Float = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Loudness").font(sizes.label)
                Text(Self.signed(comparison.loudnessDifferenceDB) + " dB").font(sizes.readout).monospacedDigit()
                Text(String(format: "%.1f / %d s", comparison.activeSeconds, windowSeconds))
                    .font(sizes.label).foregroundStyle(.secondary).monospacedDigit()
                if comparison.partial { Text("partial").font(sizes.label).foregroundStyle(.orange) }
            }
            HStack(spacing: 6) {
                ForEach(0..<OctaveBands.labels.count, id: \.self) { i in
                    let difference = comparison.octaveDifferencesDB?[i]
                    VStack(spacing: 2) {
                        Text(OctaveBands.labels[i]).font(sizes.isDisplayMode ? sizes.axis : .caption)
                        Text(Self.signed(difference)).font(sizes.isDisplayMode ? sizes.label : .caption).monospacedDigit()
                        CenteredBar(value: difference.map { CGFloat(min(max($0 / Self.spanDB, -1), 1)) })
                    }
                    .frame(minWidth: sizes.isDisplayMode ? 100 : 40)
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
