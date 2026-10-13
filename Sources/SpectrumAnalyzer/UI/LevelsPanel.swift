import SwiftUI

/// The difference pane, the levels and the loudness history, edge to edge so
/// their plots line up with the graphs above (R5, R8, R13). Tune shows the
/// levels as a table, real-time as meters. Normal mode keeps them in a
/// collapsed Details section with the settings under them (R16); display mode
/// shows them always and moves the settings into the More sheet. The guitar
/// reads unavailable while the interface is not captured.
struct LevelsPanel: View {
    /// Not observed: the fast-changing parts watch `LiveLevels` themselves.
    let model: AppModel
    var displayHeights = PaneHeights.floor
    @Environment(\.displaySizes) private var sizes
    @State private var isExpanded = false
    @State private var isShowingSettings = false
    @State private var contentHeight: CGFloat = 200

    var body: some View {
        if sizes.isDisplayMode {
            stack(differenceHeight: displayHeights.difference, historyHeight: displayHeights.history)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                DisclosureHeader(title: "Details", isExpanded: $isExpanded)
                if isExpanded {
                    // As tall as its content, so the graph above keeps the
                    // rest; it scrolls only when the window is too short.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            stack(differenceHeight: 150, historyHeight: 110)
                            DisclosureHeader(title: "Settings", isExpanded: $isShowingSettings)
                            if isShowingSettings {
                                LevelsControls(model: model).padding(.horizontal, 8).padding(.bottom, 6)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .frame(minHeight: min(200, contentHeight), maxHeight: contentHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stack(differenceHeight: CGFloat, historyHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            DifferencePane(live: model.live, sink: model.graph, height: differenceHeight)
            DisplayLevels(live: model.live)
            Divider()
            HistoryStrip(sink: model.live.history).frame(height: historyHeight)
        }
    }
}

/// A plain chevron and title; unlike `DisclosureGroup` it does not indent
/// what it opens, so the graphs inside keep the window's left edge.
private struct DisclosureHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 12)
                Text(title)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

/// Tune: the levels table; real-time: the meters.
private struct DisplayLevels: View {
    @ObservedObject var live: LiveLevels
    @Environment(\.displaySizes) private var sizes

    var body: some View {
        if let table = live.table {
            LevelsTableView(table: table)
                .padding(.leading, sizes.plotLeft)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
        } else {
            MetersRow(live: live)
                .padding(.leading, sizes.plotLeft)
                .padding(.vertical, 4)
        }
    }
}

/// Loudness, average peak and crest per row, under a header ruled off like a
/// graph's title from its plot. The rows sit 5 pt inside the plot edges.
private struct LevelsTableView: View {
    let table: LevelsTable
    @Environment(\.displaySizes) private var sizes

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 2) {
            GridRow {
                Text("Levels").font(sizes.legend).gridColumnAlignment(.leading)
                ForEach(["Loudness, dB", "Avg peak, dBFS", "Crest, dB", "Playing in window"], id: \.self) {
                    Text($0).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Rectangle().fill(Color(nsColor: GraphLayerView.frameColor)).frame(height: 1)
            if let guitar = table.guitar { row("Guitar", GraphLayerView.guitarColor, guitar, format: LevelMeter.format) }
            if let reference = table.reference { row("Reference", GraphLayerView.referenceColor, reference, format: LevelMeter.format) }
            if let difference = table.difference { row("Guitar \u{2212} Reference", nil, difference, format: Self.signed).bold() }
            row("Mix", GraphLayerView.mixColor, table.mix, format: LevelMeter.format)
        }
        .font(sizes.isDisplayMode ? .system(size: 14) : .body)
        .monospacedDigit()
    }

    private func row(_ title: String, _ color: NSColor?, _ row: LevelsRow, format: (Float) -> String) -> some View {
        GridRow {
            HStack(spacing: 8) {
                if let color { Circle().fill(Color(nsColor: color)).frame(width: 10, height: 10) }
                Text(title)
            }
            .padding(.leading, 5)
            Text(row.loudnessDB.map(format) ?? "\u{2014}")
            Text(row.averagePeakDBFS.map(format) ?? "\u{2014}")
            Text(row.crestDB.map(format) ?? "\u{2014}")
            Text(row.playing).padding(.trailing, 5)
        }
    }

    private static func signed(_ value: Float) -> String {
        String(format: "%+.1f", value)
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

/// Only while a usable reference is set (R13).
private struct DifferencePane: View {
    @ObservedObject var live: LiveLevels
    let sink: LiveSink<GraphFrame>
    let height: CGFloat

    var body: some View {
        if live.comparison != nil {
            SpectrumGraphView(sink: sink, kind: .difference).frame(height: height)
        }
    }
}

/// Thresholds with Learn noise, the window length and the export (R6, R7),
/// one labelled row each.
struct LevelsControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            thresholdRow("Guitar input", value: $model.guitarThresholdDBFS, source: .guitar)
            thresholdRow("Mix input", value: $model.mixThresholdDBFS, source: .mix)
            if !model.noiseMessage.isEmpty {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(model.noiseMessage).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            GridRow {
                Text("Comparison window")
                Picker("Comparison window", selection: $model.windowSeconds) {
                    ForEach([5, 10, 20], id: \.self) { Text("\($0) s").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            GridRow {
                Text("Agent access")
                HStack {
                    Toggle("Local data export", isOn: $model.exportEnabled)
                        .help("Serves the levels as JSON on 127.0.0.1 for a local agent; off until you turn it on")
                    Text(model.exportStatus)
                        .foregroundStyle(model.exportStatus.hasPrefix("http") ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }
        }
    }

    private func thresholdRow(_ title: String, value: Binding<Float>, source: AppModel.LevelSource) -> some View {
        GridRow {
            Text(title)
            HStack(spacing: 4) {
                Text("Threshold")
                TextField("", value: value, format: .number.precision(.fractionLength(0)))
                    .frame(width: 48)
                    .multilineTextAlignment(.trailing)
                Text("dBFS")
                Button("Learn noise") { model.learnNoise(source) }
                    .help("Press while not playing: sets the threshold to the last 3 s of noise plus 10 dB")
            }
        }
    }
}

/// The labels are SwiftUI; the numbers and the bar are AppKit views fed by the
/// sink, so a meter refresh redraws them without a SwiftUI update (KTD7).
private struct MeterView: View {
    let title: String
    let captured: Bool
    let sink: LiveSink<MeterDisplay?>
    @Environment(\.displaySizes) private var sizes

    /// Friture refreshes the numbers this often, so they stay readable.
    static let textSeconds = 0.25

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
    private func readout(_ value: KeyPath<MeterDisplay, Float>) -> some View {
        MeterReadout(sink: sink, value: value, font: sizes.readoutNSFont)
            .frame(width: sizes.isDisplayMode ? 130 : 52)
    }

    /// Bar deflection on Friture's IEC 60268-18 scale.
    static func fraction(_ dBFS: Float) -> CGFloat {
        CGFloat(MeterBallistics.iec(dBFS))
    }
}

private struct MeterReadout: NSViewRepresentable {
    let sink: LiveSink<MeterDisplay?>
    let value: KeyPath<MeterDisplay, Float>
    let font: NSFont

    func makeNSView(context: Context) -> ReadoutView {
        let view = ReadoutView()
        view.font = font
        sink.attach(view) { [value] view, reading in
            let now = Date()
            guard reading == nil || now.timeIntervalSince(view.shownAt) >= MeterView.textSeconds else { return }
            view.shownAt = now
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
    var shownAt = Date.distantPast
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
        string.draw(at: NSPoint(x: bounds.width - size.width, y: (bounds.height - size.height) / 2),
                    withAttributes: attributes)
    }
}

private struct MeterBar: NSViewRepresentable {
    let sink: LiveSink<MeterDisplay?>

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

/// As in Friture: the peak as a light bar, RMS as a solid bar over it and
/// the held peak as a 2 pt line.
private final class MeterBarView: PassiveView {
    var reading: MeterDisplay? { didSet { if reading != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        bounds.fill(using: .sourceOver)
        guard let reading else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.4).setFill()
        NSRect(x: 0, y: 0, width: bounds.width * MeterView.fraction(reading.peakDBFS), height: bounds.height).fill(using: .sourceOver)
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * MeterView.fraction(reading.rmsDBFS), height: bounds.height).fill(using: .sourceOver)
        NSColor.labelColor.setFill()
        NSRect(x: max(0, bounds.width * CGFloat(reading.heldPeakIEC) - 2), y: 0, width: 2, height: bounds.height)
            .fill(using: .sourceOver)
    }
}

/// Lists saved snapshots with Load, Rename and Delete (R12, R13).
struct SnapshotsSheet: View {
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
