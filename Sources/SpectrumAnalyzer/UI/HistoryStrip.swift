import SwiftUI

/// One guitar hop in the history strip.
struct HistoryPoint: Equatable {
    let endFrame: Int
    let loudnessDB: Float
    var isActive = true
}

/// Tune: one stretch of playing, drawn as a step at its loudness.
struct HistoryTake: Equatable {
    /// The frame its first hop starts at, and its last hop's end.
    let startFrame: Int
    let endFrame: Int
    let loudnessDB: Float
}

struct HistoryFrame: Equatable {
    var points: [HistoryPoint] = []
    var referenceLoudnessDB: Float?
    /// Tune mode's still strip instead of Friture's scrolling one.
    var isTune = false
}

/// Geometry of the guitar's loudness history. Real-time follows Friture's
/// long-time levels: 10 minutes ending at "now", smoothed, one continuous
/// line. Tune holds still for tuning: 5 minutes filling from the left, an
/// axis around the reference, and each take of playing as one step (KTD11).
enum HistoryScale {
    /// Friture's default duration; the band log holds exactly this much.
    static let spanFrames = 600 * HistoryRing.sampleRate
    /// Friture's default levels range and response time.
    static let range: ClosedRange<Float> = -70 ... -20
    static let responseSeconds = 20.0
    static let gridLines: [Float] = stride(from: range.upperBound, through: range.lowerBound, by: -10).map { $0 }
    static let tuneSpanFrames = 300 * HistoryRing.sampleRate
    /// A longer pause starts a new take; a shorter take is a stray note, not a take.
    static let takeGapFrames = 2 * HistoryRing.sampleRate
    static let minimumTakeHops = 4

    /// The newest hop sits at the right edge, under "now".
    static func x(endFrame: Int, newestFrame: Int, width: Double) -> Double {
        width * (1 - Double(newestFrame - endFrame) / Double(spanFrames))
    }

    /// Tune: the first hop since Reset at the left edge; scrolls only once
    /// 5 minutes are logged.
    static func tuneX(endFrame: Int, points: [HistoryPoint], width: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        return width * Double(endFrame - tuneOrigin(first: first.endFrame, last: last.endFrame)) / Double(tuneSpanFrames)
    }

    static func tuneOrigin(first: Int, last: Int) -> Int {
        max(first - BandLog.hopFrames, last - tuneSpanFrames)
    }

    /// Tune: the reference ±12 dB, or real-time's range without one; never moves as hops arrive.
    static func tuneRange(referenceLoudnessDB: Float?) -> ClosedRange<Float> {
        guard let reference = referenceLoudnessDB else { return range }
        return reference - 12 ... reference + 12
    }

    /// 0 at the top, clamped to the range.
    static func y(loudnessDB: Float, range: ClosedRange<Float> = range, height: Double) -> Double {
        let clamped = min(max(loudnessDB, range.lowerBound), range.upperBound)
        return height * Double((range.upperBound - clamped) / (range.upperBound - range.lowerBound))
    }

    /// Every hop's loudness, exponentially smoothed in power over `responseSeconds`.
    static func points(log: BandLog) -> [HistoryPoint] {
        guard let last = log.hops.last else { return [] }
        let alpha = Float(1 - exp(-Payload.hopSeconds / responseSeconds))
        var smoothed: Float?
        return log.hops.reversed().prefix { last.endFrame - $0.endFrame < spanFrames }.reversed().map {
            let power = pow(10, Loudness.db(bands: $0.bands) / 10)
            let next = smoothed.map { $0 + alpha * (power - $0) } ?? power
            smoothed = next
            return HistoryPoint(endFrame: $0.endFrame, loudnessDB: 10 * log10(next))
        }
    }

    /// Tune: each hop's own loudness, marked active at or above the threshold.
    static func tunePoints(log: BandLog, thresholdDBFS: Float) -> [HistoryPoint] {
        guard let last = log.hops.last else { return [] }
        return log.hops.reversed().prefix { last.endFrame - $0.endFrame < tuneSpanFrames }.reversed().map {
            HistoryPoint(endFrame: $0.endFrame, loudnessDB: Loudness.db(bands: $0.bands), isActive: $0.rmsDBFS >= thresholdDBFS)
        }
    }

    /// Tune: the active hops grouped into takes, each at its power-mean
    /// loudness, which is the loudness of its averaged bands.
    static func takes(_ points: [HistoryPoint]) -> [HistoryTake] {
        var runs: [[HistoryPoint]] = []
        for point in points where point.isActive {
            if let previous = runs.last?.last, point.endFrame - previous.endFrame - BandLog.hopFrames <= takeGapFrames {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }
        return runs.filter { $0.count >= minimumTakeHops }.map { run in
            let power = run.reduce(Float(0)) { $0 + pow(10, $1.loudnessDB / 10) } / Float(run.count)
            return HistoryTake(startFrame: run[0].endFrame - BandLog.hopFrames, endFrame: run[run.count - 1].endFrame,
                               loudnessDB: 10 * log10(power))
        }
    }
}

/// An AppKit view fed by a sink at hop rate (KTD7).
struct HistoryStrip: NSViewRepresentable {
    let sink: LiveSink<HistoryFrame>

    func makeNSView(context: Context) -> HistoryStripView {
        let view = HistoryStripView()
        view.sizes = context.environment.displaySizes
        sink.attach(view) { view, frame in view.history = frame }
        return view
    }

    func updateNSView(_ view: HistoryStripView, context: Context) {
        view.sizes = context.environment.displaySizes
    }
}

/// Same dark theme and gutters as the spectrum graph: title and legend on
/// top, dB on the left, time below (R14, KTD11).
final class HistoryStripView: NSView {
    var history = HistoryFrame() { didSet { if history != oldValue { needsDisplay = true } } }
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
        let labelHeight = ceil(font.ascender - font.descender) + 2
        let titleHeight = ceil(titleFont.ascender - titleFont.descender) + 6
        let left = sizes.plotLeft
        let plot = NSRect(x: left, y: titleHeight, width: max(1, bounds.width - left - 10),
                          height: max(1, bounds.height - titleHeight - labelHeight - 2))
        let isTune = history.isTune

        text(isTune ? "Loudness per take, dB, last 5 min" : "Loudness, dB, last 10 min", titleFont,
             color: GraphLayerView.titleColor)
            .draw(at: NSPoint(x: plot.minX, y: 3))
        let legend = NSMutableAttributedString(attributedString: text("\u{2014} Guitar", titleFont, color: GraphLayerView.guitarColor))
        if history.referenceLoudnessDB != nil {
            legend.append(text("    \u{2014} Reference", titleFont, color: GraphLayerView.referenceColor))
        }
        legend.draw(at: NSPoint(x: plot.maxX - legend.size().width, y: 3))

        let range = isTune ? HistoryScale.tuneRange(referenceLoudnessDB: history.referenceLoudnessDB) : HistoryScale.range
        let y = { (db: Float) in plot.minY + HistoryScale.y(loudnessDB: db, range: range, height: plot.height) }
        // Around a reference only the edges are labelled: a line inside would read as its value.
        let gridLines = isTune && history.referenceLoudnessDB != nil ? [range.upperBound, range.lowerBound] : HistoryScale.gridLines
        GraphLayerView.gridColor.setFill()
        for db in gridLines {
            NSRect(x: plot.minX, y: y(db) - 0.5, width: plot.width, height: 1).fill()
        }
        let labelYs: [Double] = gridLines.map { y($0) }
        for i in GraphScale.fittingLabels(labelYs, labelHeight: labelHeight) {
            let db = gridLines[i]
            let string = text((db < 0 ? "\u{2212}" : "") + String(format: "%.0f", abs(db)), font)
            let size = string.size()
            string.draw(at: NSPoint(x: plot.minX - 4 - size.width, y: labelYs[i] - size.height / 2))
        }
        for step in 0...5 {
            // Tune counts minutes from the left edge; real-time back from "now".
            let x = isTune ? plot.minX + plot.width * Double(step) / 5 : plot.maxX - plot.width * Double(step) / 5
            // Drawing a label changes the fill colour, so each line sets it again.
            GraphLayerView.gridColor.setFill()
            NSRect(x: x - 0.5, y: plot.minY, width: 1, height: plot.height).fill()
            let label = isTune ? "\(step)m" : step == 0 ? "now" : "\u{2212}\(step * 2)m"
            let string = text(label, font)
            let width = string.size().width
            string.draw(at: NSPoint(x: min(max(x - width / 2, plot.minX), plot.maxX - width), y: plot.maxY + 2))
        }
        GraphLayerView.frameColor.setStroke()
        NSBezierPath(rect: plot).stroke()

        if let reference = history.referenceLoudnessDB {
            GraphLayerView.referenceColor.setFill()
            NSRect(x: plot.minX, y: y(reference) - 1, width: plot.width, height: 2).fill()
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot).addClip()
        if isTune { drawTakes(plot: plot, y: y) } else { drawLine(plot: plot, y: y) }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLine(plot: NSRect, y: (Float) -> Double) {
        guard let newest = history.points.last?.endFrame else { return }
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        for (i, point) in history.points.enumerated() {
            let location = NSPoint(x: plot.minX + HistoryScale.x(endFrame: point.endFrame, newestFrame: newest, width: plot.width),
                                   y: y(point.loudnessDB))
            if i == 0 { path.move(to: location) } else { path.line(to: location) }
        }
        GraphLayerView.guitarColor.setStroke()
        path.stroke()
    }

    /// Each take as a step with its loudness above it; newest labels win
    /// where they would overlap.
    private func drawTakes(plot: NSRect, y: (Float) -> Double) {
        let x = { (frame: Int) in plot.minX + HistoryScale.tuneX(endFrame: frame, points: self.history.points, width: plot.width) }
        var labelLimit = plot.maxX
        for take in HistoryScale.takes(history.points).reversed() {
            let left = max(x(take.startFrame), plot.minX)
            let right = x(take.endFrame)
            let top = y(take.loudnessDB)
            GraphLayerView.guitarColor.setFill()
            NSRect(x: left, y: top - 1.5, width: max(2, right - left), height: 3).fill()
            let label = text(LevelMeter.format(take.loudnessDB), font, color: GraphLayerView.guitarColor)
            let size = label.size()
            let labelX = min(max((left + right - size.width) / 2, plot.minX), plot.maxX - size.width)
            guard labelX + size.width + 4 <= labelLimit else { continue }
            label.draw(at: NSPoint(x: labelX, y: max(plot.minY, top - 2 - size.height)))
            labelLimit = labelX
        }
    }

    private func text(_ string: String, _ font: NSFont, color: NSColor = GraphLayerView.labelColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }
}
