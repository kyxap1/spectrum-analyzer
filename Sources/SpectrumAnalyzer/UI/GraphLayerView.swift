import AppKit
import SwiftUI

/// The spectrum graph with its tone row (R8, R11, R12), or the difference pane
/// (R13), from the same frames. Core Animation layers draw it and the tick
/// feeds them through `sink`, so the 30 Hz path never touches SwiftUI state (KTD7).
struct SpectrumGraphView: NSViewRepresentable {
    let sink: LiveSink<GraphFrame>
    var kind = GraphLayerView.Kind.spectrum

    func makeNSView(context: Context) -> GraphLayerView {
        let view = GraphLayerView(kind: kind)
        view.sizes = context.environment.displaySizes
        sink.attach(view) { view, frame in view.show(frame) }
        return view
    }

    func updateNSView(_ view: GraphLayerView, context: Context) {
        view.sizes = context.environment.displaySizes
    }
}

/// Labels, title and legend sit in gutters around the plot, never under a
/// curve. They are rebuilt only when what they show changes, not every frame.
final class GraphLayerView: NSView {
    enum Kind { case spectrum, difference }

    var sizes = DisplaySizes.normal {
        didSet { if sizes.isDisplayMode != oldValue.isDisplayMode { needsLayout = true } }
    }

    private let kind: Kind
    private var graphFrame = GraphFrame()
    private let gridLayer = CAShapeLayer()
    private let axisLayer = CAShapeLayer()
    private let corridorLayer = CAShapeLayer()
    private let peakHoldLayer = CAShapeLayer()
    private let mixLayer = CAShapeLayer()
    private let mixEdgeLayer = CAShapeLayer()
    private let guitarLayer = CAShapeLayer()
    private let differenceLayer = CAShapeLayer()
    private var textLayers: [CATextLayer] = []
    private var chromeKey = ""

    /// KTD9: the graphs follow the system's light or dark appearance on the
    /// window's own background, one colour per curve.
    static let background = NSColor.windowBackgroundColor
    static let guitarColor = adaptive(light: 0x0091C2, dark: 0x2CC6EA)
    /// Grey, so the peaks never read as a second guitar curve.
    static let peakHoldColor = NSColor.secondaryLabelColor
    static let mixColor = adaptive(light: 0xE08600, dark: 0xF5A623)
    /// Faint enough to stay orange, not brown, under its edge.
    static let mixFillColor = mixColor.withAlphaComponent(0.22)
    static let referenceColor = adaptive(light: 0x8A5CF0, dark: 0xB18CFF)
    static let differenceColor = adaptive(light: 0xB88A00, dark: 0xFFD166)
    static let gridColor = NSColor.labelColor.withAlphaComponent(0.1)
    static let frameColor = NSColor.labelColor.withAlphaComponent(0.2)
    static let labelColor = NSColor.secondaryLabelColor
    static let titleColor = NSColor.labelColor
    /// A shaded band thinner than this reads as a line (KTD9).
    private static let minCorridorThickness = 4.0

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        for shape in [gridLayer, axisLayer, peakHoldLayer, mixEdgeLayer] { shape.lineWidth = 1 }
        for shape in [guitarLayer, differenceLayer] { shape.lineWidth = 1.5 }
        for shape in [gridLayer, axisLayer, peakHoldLayer, mixEdgeLayer, guitarLayer, differenceLayer] {
            shape.fillColor = nil
            shape.lineJoin = .round
        }
        applyColors()
        for sublayer in [gridLayer, axisLayer, mixLayer, mixEdgeLayer, corridorLayer, peakHoldLayer, guitarLayer, differenceLayer] {
            sublayer.masksToBounds = false
            layer?.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ frame: GraphFrame) {
        graphFrame = frame
        drawChromeIfChanged()
        drawCurves()
    }

    override func layout() {
        super.layout()
        chromeKey = ""
        drawChromeIfChanged()
        drawCurves()
    }

    /// Layers keep plain CGColors, so a switch between light and dark resolves them again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        chromeKey = ""
        drawChromeIfChanged()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Self.background.cgColor
            gridLayer.strokeColor = Self.gridColor.cgColor
            axisLayer.strokeColor = Self.frameColor.cgColor
            corridorLayer.fillColor = Self.referenceColor.withAlphaComponent(0.35).cgColor
            peakHoldLayer.strokeColor = Self.peakHoldColor.cgColor
            mixLayer.fillColor = Self.mixFillColor.cgColor
            mixEdgeLayer.strokeColor = Self.mixColor.cgColor
            guitarLayer.strokeColor = Self.guitarColor.cgColor
            differenceLayer.strokeColor = Self.differenceColor.cgColor
        }
    }

    /// The light or the dark shade, whichever the appearance asks for.
    private static func adaptive(light: Int, dark: Int) -> NSColor {
        let color = { (rgb: Int) in
            NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                    blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for text in textLayers { text.contentsScale = scale }
    }

    // MARK: Geometry. Everything is top-down; the layers are bottom-up.

    private var axisFont: NSFont { sizes.axisNSFont }
    private var legendFont: NSFont { sizes.legendNSFont }

    private func lineHeight(_ font: NSFont) -> Double { ceil(font.ascender - font.descender + font.leading) }

    /// The plot inside the gutters: header on top, dB labels left, Hz labels
    /// and, for the spectrum, the tone row below.
    private var plot: CGRect {
        let left = sizes.plotLeft
        let top = lineHeight(legendFont) + 6
        var bottom = lineHeight(axisFont) + 4
        if kind == .spectrum { bottom += lineHeight(legendFont) + 4 }
        return CGRect(x: left, y: top, width: max(1, bounds.width - left - 10), height: max(1, bounds.height - top - bottom))
    }

    private func point(x: Double, top y: Double) -> CGPoint {
        CGPoint(x: x, y: bounds.height - y)
    }

    private var range: ClosedRange<Float> {
        kind == .spectrum ? GraphScale.spectrumRange : GraphScale.differenceRange
    }

    private func plotX(_ hz: Double, _ plot: CGRect) -> Double { plot.minX + GraphScale.x(forHz: hz, width: plot.width) }

    private func plotY(_ db: Float, _ plot: CGRect) -> Double? {
        GraphScale.y(forDB: db, range: range, height: plot.height).map { plot.minY + $0 }
    }

    /// A point outside the range lies on its edge, as Friture clips it; only a
    /// point with no value breaks the line.
    private func curvePath(_ points: [SpectrumPoint], _ plot: CGRect) -> CGPath {
        let path = CGMutablePath()
        var drawing = false
        for p in points {
            guard let y = plotY(p.db, plot) else {
                drawing = false
                continue
            }
            let location = point(x: plotX(p.frequencyHz, plot), top: y)
            if drawing { path.addLine(to: location) } else { path.move(to: location) }
            drawing = true
        }
        return path
    }

    /// Friture's filled spectrum: the area from the plot's bottom up to the curve.
    private func fillPath(_ points: [SpectrumPoint], _ plot: CGRect) -> CGPath? {
        guard let first = points.first, let last = points.last else { return nil }
        let path = CGMutablePath()
        path.move(to: point(x: plotX(first.frequencyHz, plot), top: plot.maxY))
        for p in points {
            path.addLine(to: point(x: plotX(p.frequencyHz, plot), top: plotY(p.db, plot) ?? plot.maxY))
        }
        path.addLine(to: point(x: plotX(last.frequencyHz, plot), top: plot.maxY))
        path.closeSubpath()
        return path
    }

    /// One filled band per run of reference points whose upper edge is inside the range.
    private func corridorPath(_ frame: GraphFrame, _ plot: CGRect) -> CGPath? {
        guard let reference = frame.drawnReference else { return nil }
        let path = CGMutablePath()
        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        func closeRun() {
            if upper.count > 1 {
                path.addLines(between: upper + lower.reversed())
                path.closeSubpath()
            }
            upper = []
            lower = []
        }
        for p in reference {
            guard p.db + frame.toneStepDB >= GraphScale.spectrumRange.lowerBound,
                  let high = plotY(p.db + frame.toneStepDB, plot) else {
                closeRun()
                continue
            }
            var top = high
            var bottom = plotY(p.db - frame.toneStepDB, plot) ?? plot.maxY
            if bottom - top < Self.minCorridorThickness {
                let middle = (top + bottom) / 2
                top = middle - Self.minCorridorThickness / 2
                bottom = middle + Self.minCorridorThickness / 2
            }
            let x = plotX(p.frequencyHz, plot)
            upper.append(point(x: x, top: top))
            lower.append(point(x: x, top: bottom))
        }
        closeRun()
        return path
    }

    // MARK: Drawing

    private func drawCurves() {
        let frame = graphFrame
        let plot = plot
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch kind {
        case .spectrum:
            corridorLayer.path = corridorPath(frame, plot)
            peakHoldLayer.path = frame.peakHold.map { curvePath($0, plot) }
            mixLayer.path = fillPath(frame.mix, plot)
            mixEdgeLayer.path = curvePath(frame.mix, plot)
            guitarLayer.path = frame.guitar.map { curvePath($0, plot) }
        case .difference:
            differenceLayer.path = frame.difference.map { curvePath($0, plot) }
        }
        CATransaction.commit()
    }

    private var legendEntries: [(String, NSColor)] {
        let frame = graphFrame
        switch kind {
        case .spectrum:
            var entries: [(String, NSColor)] = []
            if frame.guitar != nil { entries.append(("\u{2014} Guitar", Self.guitarColor)) }
            entries.append(("\u{25AC} Mix", Self.mixColor))
            if frame.reference != nil { entries.append(("\u{25AC} Reference", Self.referenceColor)) }
            if frame.peakHold != nil { entries.append(("\u{2014} Peak hold", Self.peakHoldColor)) }
            return entries
        case .difference:
            return [("\u{2014} Guitar \u{2212} Reference", Self.differenceColor)]
        }
    }

    /// The signed figure of each octave out by a step; blank within tolerance (R8).
    private var toneTexts: [String] {
        guard kind == .spectrum, graphFrame.reference != nil, let steps = graphFrame.toneSteps else { return [] }
        return steps.map { $0 == 0 ? "" : Self.signed(Float($0) * graphFrame.toneStepDB) }
    }

    private static func signed(_ db: Float) -> String {
        db == 0 ? "0" : (db < 0 ? "\u{2212}" : "+") + String(format: "%.0f", abs(db))
    }

    private func drawChromeIfChanged() {
        let key = "\(bounds.size)|\(sizes.isDisplayMode)|\(range)|\(graphFrame.reference != nil)|\(graphFrame.windowSeconds ?? 0)|"
            + legendEntries.map(\.0).joined(separator: ",") + "|" + toneTexts.joined(separator: ",")
        guard key != chromeKey else { return }
        chromeKey = key
        let plot = plot

        let grid = CGMutablePath()
        let axis = CGMutablePath()
        for hz in GraphScale.frequencyGridLines {
            let x = plotX(hz, plot)
            grid.move(to: point(x: x, top: plot.minY))
            grid.addLine(to: point(x: x, top: plot.maxY))
        }
        let step = kind == .spectrum ? GraphScale.spectrumGridStepDB : GraphScale.differenceGridStepDB
        let dbLines = GraphScale.gridLines(range: range, step: step)
        for db in dbLines {
            guard let y = plotY(db, plot) else { continue }
            let path = kind == .difference && db == 0 ? axis : grid
            path.move(to: point(x: plot.minX, top: y))
            path.addLine(to: point(x: plot.maxX, top: y))
        }
        axis.addRect(CGRect(x: plot.minX, y: bounds.height - plot.maxY, width: plot.width, height: plot.height))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridLayer.path = grid
        axisLayer.path = axis
        for text in textLayers { text.removeFromSuperlayer() }
        textLayers = []

        // Header: title left, legend right.
        let window = graphFrame.windowSeconds.map { ", last \($0) s of playing" } ?? ""
        let title = (kind == .spectrum ? "PSD, dB" : "Guitar \u{2212} Reference, dB (level-matched)") + window
        addText(NSAttributedString(string: title, attributes: [.font: legendFont, .foregroundColor: Self.titleColor]),
                left: plot.minX, top: 3)
        let legend = NSMutableAttributedString()
        for (i, entry) in legendEntries.enumerated() {
            legend.append(NSAttributedString(string: (i == 0 ? "" : "    ") + entry.0,
                                             attributes: [.font: legendFont, .foregroundColor: entry.1]))
        }
        addText(legend, right: plot.maxX, top: 3)

        // dB labels in the left gutter, centred on their lines.
        let labelYs = dbLines.map { plotY($0, plot) ?? plot.maxY }
        for i in GraphScale.fittingLabels(labelYs, labelHeight: lineHeight(axisFont)) {
            let db = dbLines[i]
            let string = kind == .spectrum ? Self.signed(db).replacingOccurrences(of: "+", with: "") : Self.signed(db)
            addLabel(string, font: axisFont, right: plot.minX - 4, centerY: labelYs[i])
        }
        // Hz labels under the plot.
        for (hz, label) in zip(GraphScale.frequencyGridLines, GraphScale.frequencyGridLabels) {
            addLabel(label, font: axisFont, centerX: plotX(hz, plot), top: plot.maxY + 2)
        }
        // The tone row under the Hz labels (R8).
        if kind == .spectrum, graphFrame.reference != nil {
            let rowTop = plot.maxY + lineHeight(axisFont) + 5
            addText(NSAttributedString(string: "vs ref", attributes: [.font: legendFont, .foregroundColor: Self.labelColor]),
                    right: plot.minX - 4, top: rowTop)
            let font = NSFont.monospacedDigitSystemFont(ofSize: legendFont.pointSize, weight: .semibold)
            for (hz, text) in zip(GraphScale.frequencyGridLines, toneTexts) where !text.isEmpty {
                let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: Self.titleColor])
                addText(string, left: plotX(hz, plot) - string.size().width / 2, top: rowTop)
            }
        }
        CATransaction.commit()
    }

    private func addLabel(_ string: String, font: NSFont, right: Double, centerY: Double) {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: Self.labelColor])
        addText(attributed, right: right, top: centerY - attributed.size().height / 2)
    }

    private func addLabel(_ string: String, font: NSFont, centerX: Double, top: Double) {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: Self.labelColor])
        addText(attributed, left: centerX - attributed.size().width / 2, top: top)
    }

    private func addText(_ string: NSAttributedString, right: Double, top: Double) {
        addText(string, left: right - ceil(string.size().width), top: top)
    }

    private func addText(_ string: NSAttributedString, left: Double, top: Double) {
        let size = string.size()
        let text = CATextLayer()
        text.string = resolved(string)
        text.contentsScale = window?.backingScaleFactor ?? 2
        let origin = point(x: left, top: top + ceil(size.height))
        text.frame = CGRect(x: origin.x, y: origin.y, width: ceil(size.width), height: ceil(size.height))
        layer?.addSublayer(text)
        textLayers.append(text)
    }

    /// A text layer draws without the view's appearance, so its colours are fixed here.
    private func resolved(_ string: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: string)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            copy.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
                if let color = value as? NSColor, let fixed = NSColor(cgColor: color.cgColor) {
                    copy.addAttribute(.foregroundColor, value: fixed, range: range)
                }
            }
        }
        return copy
    }
}
