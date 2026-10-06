import AppKit
import SwiftUI

/// The guitar and the mix on one spectrum pane; with a reference, the
/// difference pane below it shares the frequency axis (R11-R13). Core Animation layers draw it and the tick feeds them through
/// `sink`, so the 30 Hz path never touches SwiftUI state (KTD7).
struct SpectrumGraphView: NSViewRepresentable {
    let sink: LiveSink<GraphFrame>

    func makeNSView(context: Context) -> GraphLayerView {
        let view = GraphLayerView()
        view.sizes = context.environment.displaySizes
        sink.attach(view) { view, frame in view.show(frame) }
        return view
    }

    func updateNSView(_ view: GraphLayerView, context: Context) {
        view.sizes = context.environment.displaySizes
    }
}

final class GraphLayerView: NSView {
    var sizes = DisplaySizes.normal {
        didSet { if sizes.isDisplayMode != oldValue.isDisplayMode { needsLayout = true } }
    }

    private var graphFrame = GraphFrame()
    private let gridLayer = CAShapeLayer()
    private let axisLayer = CAShapeLayer()
    private let corridorLayer = CAShapeLayer()
    private let peakHoldLayer = CAShapeLayer()
    private let mixLayer = CAShapeLayer()
    private let guitarLayer = CAShapeLayer()
    private let differenceLayer = CAShapeLayer()
    private let legendLayer = CATextLayer()
    private let differenceLegendLayer = CATextLayer()
    private var labelLayers: [CATextLayer] = []
    private var legendKey = ""

    /// A shaded band thinner than this reads as a line (KTD9).
    private static let minCorridorThickness = 4.0
    private static let labelColor = NSColor.white.withAlphaComponent(0.5)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        stroke(gridLayer, NSColor.white.withAlphaComponent(0.15), width: 1)
        stroke(axisLayer, NSColor.white.withAlphaComponent(0.35), width: 1)
        corridorLayer.fillColor = NSColor.systemCyan.withAlphaComponent(0.25).cgColor
        stroke(peakHoldLayer, NSColor.systemCyan.withAlphaComponent(0.4), width: 1)
        stroke(mixLayer, .systemOrange, width: 1.5)
        stroke(guitarLayer, .systemCyan, width: 1.5)
        stroke(differenceLayer, .systemGreen, width: 1.5)
        for text in [legendLayer, differenceLegendLayer] { text.alignmentMode = .right }
        for sublayer in [gridLayer, axisLayer, corridorLayer, peakHoldLayer, mixLayer, guitarLayer, differenceLayer,
                         legendLayer, differenceLegendLayer] {
            layer?.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ frame: GraphFrame) {
        let paneChanged = (frame.reference != nil) != (graphFrame.reference != nil)
        graphFrame = frame
        if paneChanged {
            legendKey = ""
            drawGrid()
        }
        drawCurves()
    }

    private var panes: (spectrum: GraphPane, difference: GraphPane) {
        GraphScale.panes(height: bounds.height, withDifference: graphFrame.reference != nil)
    }

    override func layout() {
        super.layout()
        legendKey = ""
        drawGrid()
        drawCurves()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for text in labelLayers + [legendLayer, differenceLegendLayer] { text.contentsScale = scale }
    }

    private func stroke(_ shape: CAShapeLayer, _ color: NSColor, width: CGFloat) {
        shape.strokeColor = color.cgColor
        shape.fillColor = nil
        shape.lineWidth = width
    }

    // MARK: Geometry. GraphScale is top-down; the layers are bottom-up.

    private func point(x: Double, top y: Double) -> CGPoint {
        CGPoint(x: x, y: bounds.height - y)
    }

    private func curvePath(_ points: [SpectrumPoint], y: (Float) -> Double) -> CGPath {
        let path = CGMutablePath()
        for (i, p) in points.enumerated() {
            let location = point(x: GraphScale.x(forHz: p.frequencyHz, width: bounds.width), top: y(p.db))
            if i == 0 { path.move(to: location) } else { path.addLine(to: location) }
        }
        return path
    }

    private func corridorPath(_ frame: GraphFrame, pane: GraphPane) -> CGPath? {
        guard let reference = frame.reference else { return nil }
        let corridor = GraphScale.corridor(reference: reference, offsetDB: frame.referenceOffsetDB, stepDB: frame.toneStepDB)
        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        for (high, low) in zip(corridor.upper, corridor.lower) {
            let x = GraphScale.x(forHz: high.frequencyHz, width: bounds.width)
            var top = GraphScale.y(forDB: high.db, in: pane)
            var bottom = GraphScale.y(forDB: low.db, in: pane)
            if bottom - top < Self.minCorridorThickness {
                let middle = (top + bottom) / 2
                top = middle - Self.minCorridorThickness / 2
                bottom = middle + Self.minCorridorThickness / 2
            }
            upper.append(point(x: x, top: top))
            lower.append(point(x: x, top: bottom))
        }
        let path = CGMutablePath()
        path.addLines(between: upper + lower.reversed())
        path.closeSubpath()
        return path
    }

    // MARK: Drawing

    private func drawCurves() {
        let frame = graphFrame
        let panes = panes
        let spectrumY = { (db: Float) in GraphScale.y(forDB: db, in: panes.spectrum) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        corridorLayer.path = corridorPath(frame, pane: panes.spectrum)
        peakHoldLayer.path = frame.peakHold.map { curvePath($0, y: spectrumY) }
        mixLayer.path = curvePath(frame.mix, y: spectrumY)
        guitarLayer.path = frame.guitar.map { curvePath($0, y: spectrumY) }
        differenceLayer.path = frame.difference.map { curvePath($0) { GraphScale.y(forDifferenceDB: $0, in: panes.difference) } }
        updateLegends(frame, panes: panes)
        CATransaction.commit()
    }

    /// Rebuilt only when what they name changes, not every frame.
    private func updateLegends(_ frame: GraphFrame, panes: (spectrum: GraphPane, difference: GraphPane)) {
        var entries: [(String, NSColor)] = [("Mix", .systemOrange)]
        if frame.guitar != nil { entries.append(("Guitar", .systemCyan)) }
        if frame.reference != nil { entries.append(("Reference", NSColor.systemCyan.withAlphaComponent(0.6))) }
        if frame.peakHold != nil { entries.append(("Peak hold", NSColor.systemCyan.withAlphaComponent(0.4))) }
        let differenceTitle = frame.difference == nil ? "" : "Guitar \u{2212} Reference"
        let key = entries.map(\.0).joined(separator: "|") + "#" + differenceTitle
        guard key != legendKey else { return }
        legendKey = key

        let font = sizes.legendNSFont
        let legend = NSMutableAttributedString()
        for (i, entry) in entries.enumerated() {
            legend.append(NSAttributedString(string: (i == 0 ? "" : "\n") + entry.0,
                                             attributes: [.font: font, .foregroundColor: entry.1]))
        }
        place(legendLayer, legend, topRight: CGPoint(x: bounds.width - 8, y: panes.spectrum.top + 6))
        place(differenceLegendLayer,
              NSAttributedString(string: differenceTitle, attributes: [.font: font, .foregroundColor: NSColor.systemGreen]),
              topRight: CGPoint(x: bounds.width - 8, y: panes.difference.top + 4))
    }

    private func place(_ text: CATextLayer, _ string: NSAttributedString, topRight: CGPoint) {
        let size = string.size()
        text.string = string
        let origin = point(x: topRight.x - ceil(size.width), top: topRight.y + ceil(size.height))
        text.frame = CGRect(x: origin.x, y: origin.y, width: ceil(size.width), height: ceil(size.height))
    }

    private func drawGrid() {
        let panes = panes
        let width = bounds.width
        let grid = CGMutablePath()
        for hz in GraphScale.frequencyGridLines {
            let x = GraphScale.x(forHz: hz, width: width)
            grid.move(to: point(x: x, top: 0))
            grid.addLine(to: point(x: x, top: bounds.height))
        }
        for db in GraphScale.dbGridLines {
            let y = GraphScale.y(forDB: db, in: panes.spectrum)
            grid.move(to: point(x: 0, top: y))
            grid.addLine(to: point(x: width, top: y))
        }
        let axis = CGMutablePath()
        let differenceLines = panes.difference.height > 0 ? GraphScale.differenceGridLines : []
        if !differenceLines.isEmpty {
            axis.move(to: point(x: 0, top: panes.difference.top))
            axis.addLine(to: point(x: width, top: panes.difference.top))
        }
        for db in differenceLines {
            let y = GraphScale.y(forDifferenceDB: db, in: panes.difference)
            let path = db == 0 ? axis : grid
            path.move(to: point(x: 0, top: y))
            path.addLine(to: point(x: width, top: y))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridLayer.path = grid
        axisLayer.path = axis
        for text in labelLayers { text.removeFromSuperlayer() }
        labelLayers = []
        let font = sizes.axisNSFont
        for (hz, label) in zip(GraphScale.frequencyGridLines, GraphScale.frequencyGridLabels) {
            addLabel(label, font: font, centerX: GraphScale.x(forHz: hz, width: width), bottom: bounds.height - 2)
        }
        for db in GraphScale.dbGridLines {
            addLabel("\(Int(db)) dB", font: font, left: 6, top: GraphScale.y(forDB: db, in: panes.spectrum) + 2)
        }
        // Above their lines, clear of the frequency labels at the bottom.
        for db in differenceLines {
            let text = db == 0 ? "0" : String(format: "%+.0f", db).replacingOccurrences(of: "-", with: "\u{2212}")
            let height = (text as NSString).size(withAttributes: [.font: font]).height
            addLabel(text, font: font, left: 6, top: GraphScale.y(forDifferenceDB: db, in: panes.difference) - height - 1)
        }
        CATransaction.commit()
    }

    private func addLabel(_ string: String, font: NSFont, centerX: Double, bottom: Double) {
        let size = (string as NSString).size(withAttributes: [.font: font])
        addLabel(string, font: font, left: centerX - size.width / 2, top: bottom - size.height)
    }

    private func addLabel(_ string: String, font: NSFont, left: Double, top: Double) {
        let text = CATextLayer()
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: Self.labelColor])
        let size = attributed.size()
        text.string = attributed
        text.contentsScale = window?.backingScaleFactor ?? 2
        let origin = point(x: left, top: top + ceil(size.height))
        text.frame = CGRect(x: origin.x, y: origin.y, width: ceil(size.width), height: ceil(size.height))
        layer?.insertSublayer(text, above: axisLayer)
        labelLayers.append(text)
    }
}
