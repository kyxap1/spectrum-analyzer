import SwiftUI

/// Frequency-to-x and dB-to-y mapping for the graph (R5). Pure so it is
/// testable without a live view.
enum GraphScale {
    static let dbGridLines: [Float] = [0, -20, -40, -60, -80]
    static let differenceSpanDB: Float = 30
    static let differenceLabelValues: [Float] = [30, 15, 0, -15, -30]
    /// The 10 octave bands, which are the EQ2 factory bands.
    static let frequencyGridLines = OctaveBands.centerFrequencies
    static let frequencyGridLabels = OctaveBands.labels

    static func x(forHz hz: Double, width: Double) -> Double {
        let t = log2(hz / SpectrumAnalyzer.minFrequency)
            / log2(SpectrumAnalyzer.maxFrequency / SpectrumAnalyzer.minFrequency)
        return t * width
    }

    static func y(forDB db: Float, height: Double) -> Double {
        let floor = Double(SpectrumAnalyzer.displayFloorDB)
        let clamped = max(Double(db), floor)
        let t = (clamped - floor) / -floor
        return height * (1 - t)
    }

    /// The difference curve's own scale: 0 dB at mid-height, +/-`differenceSpanDB`
    /// at the edges, values beyond clamped.
    static func y(forDifferenceDB db: Float, height: Double) -> Double {
        let clamped = min(max(db, -differenceSpanDB), differenceSpanDB)
        return height * (1 - (Double(clamped) / Double(differenceSpanDB) + 1) / 2)
    }

    /// Guitar minus mix at each display point.
    static func difference(guitar: [SpectrumPoint], mix: [SpectrumPoint]) -> [SpectrumPoint] {
        zip(guitar, mix).map { SpectrumPoint(frequencyHz: $0.frequencyHz, db: $0.db - $1.db) }
    }

    /// The reference's display powers as a curve against the live guitar.
    static func points(of reference: Reference) -> [SpectrumPoint] {
        zip(SpectrumAnalyzer.displayFrequencies, reference.guitarDisplay).map {
            SpectrumPoint(frequencyHz: $0, db: dB($1, floor: SpectrumAnalyzer.displayFloorDB))
        }
    }
}

/// One graph overlaying the mix and guitar curves on a log-frequency, dB axis
/// (R5), redrawn as `points` changes. The optional difference curve reads
/// against its own scale on the right edge; the reference curve shares the
/// main dB scale so it compares directly with the live guitar.
struct SpectrumGraphView: View {
    @ObservedObject var curves: LiveCurves
    var referencePoints: [SpectrumPoint]?
    @Environment(\.displaySizes) private var sizes

    var body: some View {
        ZStack {
            GraphGrid()
            curveCanvas
        }
        .overlay(alignment: .topTrailing) { legend }
        .background(Color.black.opacity(0.85))
    }

    private var curveCanvas: some View {
        Canvas { context, size in
            drawCurve(curves.mix, color: .orange, context: context, size: size)
            if let referencePoints {
                drawCurve(referencePoints, color: .cyan.opacity(0.45), dash: [6, 4], context: context, size: size)
            }
            if let guitarPoints = curves.guitar {
                drawCurve(guitarPoints, color: .cyan, context: context, size: size)
            }
            if let differencePoints = curves.difference {
                drawCurve(differencePoints, color: .green, dash: [2, 3], context: context, size: size) {
                    GraphScale.y(forDifferenceDB: $0, height: size.height)
                }
                drawDifferenceLabels(context: context, size: size)
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Mix", systemImage: "circle.fill").foregroundStyle(.orange)
            if curves.guitar != nil {
                Label("Guitar", systemImage: "circle.fill").foregroundStyle(.cyan)
            }
            if referencePoints != nil {
                Label("Reference", systemImage: "circle.dashed").foregroundStyle(.cyan.opacity(0.6))
            }
            if curves.difference != nil {
                Label("Guitar \u{2212} Mix", systemImage: "circle.dotted").foregroundStyle(.green)
            }
        }
        .font(sizes.legend)
        .padding(8)
    }

    private func drawDifferenceLabels(context: GraphicsContext, size: CGSize) {
        for db in GraphScale.differenceLabelValues {
            let y = GraphScale.y(forDifferenceDB: db, height: size.height)
            context.draw(Text(String(format: "%+.0f", db)).font(sizes.axis).foregroundStyle(Color.green.opacity(0.7)),
                         at: CGPoint(x: size.width - 6, y: min(max(y, 8), size.height - 8)),
                         anchor: .trailing)
        }
    }

    private func drawCurve(_ points: [SpectrumPoint], color: Color, dash: [CGFloat] = [], context: GraphicsContext, size: CGSize,
                           y: ((Float) -> Double)? = nil) {
        guard let first = points.first else { return }
        let yFor = y ?? { GraphScale.y(forDB: $0, height: size.height) }
        var path = Path()
        path.move(to: CGPoint(x: GraphScale.x(forHz: first.frequencyHz, width: size.width), y: yFor(first.db)))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: GraphScale.x(forHz: point.frequencyHz, width: size.width), y: yFor(point.db)))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: dash))
    }
}

/// The grid and its labels never change with the audio, so they sit in their
/// own view with no changing input and are not redrawn on every frame.
private struct GraphGrid: View {
    @Environment(\.displaySizes) private var sizes

    var body: some View {
        Canvas { context, size in
            drawGrid(context: context, size: size)
        }
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        var grid = Path()
        for hz in GraphScale.frequencyGridLines {
            let x = GraphScale.x(forHz: hz, width: size.width)
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for db in GraphScale.dbGridLines {
            let y = GraphScale.y(forDB: db, height: size.height)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.15)))

        // dB labels sit at the left edge, inside the canvas.
        let style = Color.white.opacity(0.5)
        for (hz, label) in zip(GraphScale.frequencyGridLines, GraphScale.frequencyGridLabels) {
            context.draw(Text(label).font(sizes.axis).foregroundStyle(style),
                         at: CGPoint(x: GraphScale.x(forHz: hz, width: size.width), y: size.height - 2),
                         anchor: .bottom)
        }
        for db in GraphScale.dbGridLines {
            let y = GraphScale.y(forDB: db, height: size.height)
            context.draw(Text("\(Int(db)) dB").font(sizes.axis).foregroundStyle(style),
                         at: CGPoint(x: 6, y: y + 2),
                         anchor: .topLeading)
        }
    }
}
