import SwiftUI

/// Frequency-to-x and dB-to-y mapping for the graph (R5). Pure so it is
/// testable without a live view.
enum GraphScale {
    static let dbGridLines: [Float] = [0, -20, -40, -60, -80]
    static let frequencyGridLines: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]

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

    /// Axis label for a frequency grid line: "500", "1k", "20k".
    static func frequencyLabel(_ hz: Double) -> String {
        hz >= 1_000 ? "\(Int(hz / 1_000))k" : "\(Int(hz))"
    }
}

/// One graph overlaying the mix and guitar curves on a log-frequency, dB axis
/// (R5), redrawn as `points` changes.
struct SpectrumGraphView: View {
    let mixPoints: [SpectrumPoint]
    let guitarPoints: [SpectrumPoint]?

    var body: some View {
        Canvas { context, size in
            drawGrid(context: context, size: size)
            drawCurve(mixPoints, color: .orange, context: context, size: size)
            if let guitarPoints {
                drawCurve(guitarPoints, color: .cyan, context: context, size: size)
            }
        }
        .overlay(alignment: .topTrailing) { legend }
        .background(Color.black.opacity(0.85))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Mix", systemImage: "circle.fill").foregroundStyle(.orange)
            if guitarPoints != nil {
                Label("Guitar", systemImage: "circle.fill").foregroundStyle(.cyan)
            }
        }
        .font(.caption)
        .padding(8)
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

        // Edge labels anchor inward so 20 Hz, 20k and 0 dB stay inside the canvas.
        let style = Color.white.opacity(0.5)
        let lines = GraphScale.frequencyGridLines
        for (i, hz) in lines.enumerated() {
            let (anchor, dx): (UnitPoint, Double) = i == 0 ? (.bottomLeading, 6)
                : i == lines.count - 1 ? (.bottomTrailing, -6) : (.bottom, 0)
            let x = GraphScale.x(forHz: hz, width: size.width) + dx
            context.draw(Text(GraphScale.frequencyLabel(hz)).font(.caption2).foregroundStyle(style),
                         at: CGPoint(x: x, y: size.height - 2),
                         anchor: anchor)
        }
        for db in GraphScale.dbGridLines {
            let y = GraphScale.y(forDB: db, height: size.height)
            context.draw(Text("\(Int(db)) dB").font(.caption2).foregroundStyle(style),
                         at: CGPoint(x: 6, y: y + 2),
                         anchor: .topLeading)
        }
    }

    private func drawCurve(_ points: [SpectrumPoint], color: Color, context: GraphicsContext, size: CGSize) {
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: CGPoint(x: GraphScale.x(forHz: first.frequencyHz, width: size.width),
                              y: GraphScale.y(forDB: first.db, height: size.height)))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: GraphScale.x(forHz: point.frequencyHz, width: size.width),
                                     y: GraphScale.y(forDB: point.db, height: size.height)))
        }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }
}
