import SwiftUI

/// After Friture's octave spectrum, one band per octave on the 10 EQ2
/// octaves, smoothed in power with Friture's 1 s response. Each octave sums
/// its three third-octave FFT bands, as the reference and the verdict do, so
/// a bar shows the same band power they compare.
struct OctaveLevels {
    static let responseSeconds = 1.0
    /// Friture's default octave spectrum range.
    static let range: ClosedRange<Float> = -80 ... -20
    /// The summed bins read a sine's squared amplitude; its mean square, as
    /// Friture's filtered power shows, is half that.
    static let meanSquareScale: Float = 0.5
    /// Friture: the samples within one response time carry 65% of the output.
    private static let weight = 0.65

    private var power: [Float]?

    /// `seconds` is the time since the previous call.
    mutating func update(ring: HistoryRing, head: Int, seconds: Double) -> [SpectrumPoint] {
        let (bins, binHz) = fftPowerSpectrum(ring: ring, endFrame: head, fftSize: SpectrumAnalyzer.fftSize)
        let octaves = OctaveBands.power(fromBands: ThirdOctaveBands.aggregate(power: bins, binHz: binHz))
        let keep = Float(pow(1 - Self.weight, seconds / Self.responseSeconds))
        let smoothed = power.map { zip($0, octaves).map { keep * $0 + (1 - keep) * $1 } } ?? octaves
        power = smoothed
        return Self.points(octavePower: smoothed)
    }

    /// Third-octave band powers, as the band log and the reference keep them, as octave bars.
    static func points(bandPower: [Float]) -> [SpectrumPoint] {
        points(octavePower: OctaveBands.power(fromBands: bandPower))
    }

    private static func points(octavePower: [Float]) -> [SpectrumPoint] {
        zip(OctaveBands.centerFrequencies, octavePower).map {
            let meanSquare = $1 * meanSquareScale
            return SpectrumPoint(frequencyHz: $0, db: meanSquare > 0 ? 10 * log10(meanSquare) : -.infinity)
        }
    }
}

enum ViewMode: String {
    case realtime, tune
}

struct OctaveFrame: Equatable {
    var guitar: [SpectrumPoint]?
    var mix: [SpectrumPoint] = []
    /// The guitar's peak caps.
    var caps: [SpectrumPoint]?
    /// Tune: the reference level-matched to the guitar, as the corridor is.
    var reference: [SpectrumPoint]?
    /// Tune: the window the bars average; nil in real-time.
    var windowSeconds: Int?
}

/// An AppKit view fed by a sink every tick (KTD7).
struct OctaveBars: NSViewRepresentable {
    let sink: LiveSink<OctaveFrame>

    func makeNSView(context: Context) -> OctaveBarsView {
        let view = OctaveBarsView()
        view.sizes = context.environment.displaySizes
        sink.attach(view) { view, frame in view.bars = frame }
        return view
    }

    func updateNSView(_ view: OctaveBarsView, context: Context) {
        view.sizes = context.environment.displaySizes
    }
}

/// Same theme, gutters and frequency axis as the spectrum graph, so a bar sits
/// under its octave of the curve: mix as translucent bars behind, guitar as
/// solid bars in front with Friture's peak caps in real-time, the reference
/// as a line across each octave in Tune.
final class OctaveBarsView: NSView {
    var bars = OctaveFrame() { didSet { if bars != oldValue { needsDisplay = true } } }
    var sizes = DisplaySizes.normal { didSet { if sizes.isDisplayMode != oldValue.isDisplayMode { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var font: NSFont { sizes.axisNSFont }
    private var titleFont: NSFont { sizes.legendNSFont }

    override func draw(_ dirtyRect: NSRect) {
        GraphLayerView.background.setFill()
        bounds.fill()
        let font = self.font
        let titleFont = self.titleFont
        let labelHeight = ceil(font.ascender - font.descender + font.leading) + 4
        let titleHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading) + 6
        let left = sizes.plotLeft
        let plot = NSRect(x: left, y: titleHeight, width: max(1, bounds.width - left - 10),
                          height: max(1, bounds.height - titleHeight - labelHeight))

        text(bars.windowSeconds.map { "Octave PSD, dB, last \($0) s of playing" } ?? "Octave PSD, dB", titleFont, color: GraphLayerView.titleColor)
            .draw(at: NSPoint(x: plot.minX, y: 3))
        let legend = NSMutableAttributedString(attributedString: text("\u{25AC} Guitar", titleFont, color: GraphLayerView.guitarColor))
        legend.append(text("    \u{25AC} Mix", titleFont, color: GraphLayerView.mixColor))
        if bars.reference != nil {
            legend.append(text("    \u{2014} Reference", titleFont, color: GraphLayerView.referenceColor))
        }
        legend.draw(at: NSPoint(x: plot.maxX - legend.size().width, y: 3))

        let range = OctaveLevels.range
        let y = { (db: Float) in plot.minY + (GraphScale.y(forDB: db, range: range, height: plot.height) ?? plot.height) }
        let x = { (hz: Double) in plot.minX + GraphScale.x(forHz: hz, width: plot.width) }
        GraphLayerView.gridColor.setFill()
        let dbLines = GraphScale.gridLines(range: range, step: 10)
        for db in dbLines {
            NSRect(x: plot.minX, y: y(db) - 0.5, width: plot.width, height: 1).fill()
        }
        let labelYs: [Double] = dbLines.map { y($0) }
        for i in GraphScale.fittingLabels(labelYs, labelHeight: labelHeight) {
            let string = text("\u{2212}" + String(format: "%.0f", abs(dbLines[i])), font)
            let size = string.size()
            string.draw(at: NSPoint(x: plot.minX - 4 - size.width, y: labelYs[i] - size.height / 2))
        }
        for (hz, label) in zip(GraphScale.frequencyGridLines, GraphScale.frequencyGridLabels) {
            let string = text(label, font)
            string.draw(at: NSPoint(x: x(hz) - string.size().width / 2, y: plot.maxY + 2))
        }
        GraphLayerView.frameColor.setStroke()
        NSBezierPath(rect: plot).stroke()

        // One octave wide, with a 1 pt gap between neighbours.
        let bar = { (point: SpectrumPoint, inset: Double) -> NSRect in
            let lo = x(point.frequencyHz / 2.squareRoot()) + 1 + inset
            let hi = x(point.frequencyHz * 2.squareRoot()) - 1 - inset
            return NSRect(x: lo, y: y(point.db), width: max(1, hi - lo), height: plot.maxY - y(point.db))
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot).addClip()
        for point in bars.mix where point.db.isFinite {
            let rect = bar(point, 0)
            GraphLayerView.mixFillColor.setFill()
            rect.fill()
            GraphLayerView.mixColor.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        }
        if let guitar = bars.guitar {
            GraphLayerView.guitarColor.setFill()
            for point in guitar where point.db.isFinite { bar(point, 6).fill() }
        }
        if let caps = bars.caps {
            GraphLayerView.peakHoldColor.setFill()
            for point in caps where point.db.isFinite {
                let rect = bar(point, 6)
                NSRect(x: rect.minX, y: rect.minY - 1, width: rect.width, height: 2).fill()
            }
        }
        if let reference = bars.reference {
            GraphLayerView.referenceColor.setFill()
            for point in reference where point.db.isFinite {
                let rect = bar(point, 2)
                NSRect(x: rect.minX, y: rect.minY - 0.75, width: rect.width, height: 1.5).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func text(_ string: String, _ font: NSFont, color: NSColor = GraphLayerView.labelColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }
}
