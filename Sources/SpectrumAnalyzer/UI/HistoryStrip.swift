import SwiftUI

/// One guitar hop in the history strip.
struct HistoryPoint: Equatable {
    let endFrame: Int
    let loudnessDB: Float
    let isActive: Bool
}

struct HistoryFrame: Equatable {
    var points: [HistoryPoint] = []
    var referenceLoudnessDB: Float?
}

/// Geometry of the last 5 minutes of guitar loudness (R14). Fixed axes, so
/// nothing rescales as hops arrive.
enum HistoryScale {
    static let spanFrames = 300 * HistoryRing.sampleRate

    /// Fills from the left until 5 minutes are logged, then scrolls.
    static func x(endFrame: Int, points: [HistoryPoint], width: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        let origin = max(first.endFrame, last.endFrame - spanFrames)
        return width * Double(endFrame - origin) / Double(spanFrames)
    }

    static func range(referenceLoudnessDB: Float?) -> ClosedRange<Float> {
        guard let reference = referenceLoudnessDB else { return -48 ... 0 }
        return reference - 12 ... reference + 12
    }

    /// 0 at the top.
    static func y(loudnessDB: Float, range: ClosedRange<Float>, height: Double) -> Double {
        let clamped = min(max(loudnessDB, range.lowerBound), range.upperBound)
        return height * Double((range.upperBound - clamped) / (range.upperBound - range.lowerBound))
    }

    static func points(log: BandLog, thresholdDBFS: Float) -> [HistoryPoint] {
        guard let last = log.hops.last else { return [] }
        return log.hops.reversed().prefix { last.endFrame - $0.endFrame < spanFrames }.reversed().map {
            HistoryPoint(endFrame: $0.endFrame, loudnessDB: Loudness.db(bands: $0.bands), isActive: $0.rmsDBFS >= thresholdDBFS)
        }
    }
}

/// An AppKit view fed by a sink at hop rate (KTD7).
struct HistoryStrip: NSViewRepresentable {
    let sink: LiveSink<HistoryFrame>

    func makeNSView(context: Context) -> HistoryStripView {
        let view = HistoryStripView()
        sink.attach(view) { view, frame in view.history = frame }
        return view
    }

    func updateNSView(_ view: HistoryStripView, context: Context) {}
}

final class HistoryStripView: NSView {
    var history = HistoryFrame() { didSet { if history != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.3).setFill()
        bounds.fill()
        let range = HistoryScale.range(referenceLoudnessDB: history.referenceLoudnessDB)
        // AppKit's y grows upwards; the scale's grows downwards.
        let y = { (db: Float) in self.bounds.height - HistoryScale.y(loudnessDB: db, range: range, height: self.bounds.height) }
        if let reference = history.referenceLoudnessDB {
            NSColor.systemOrange.setFill()
            NSRect(x: 0, y: y(reference) - 0.5, width: bounds.width, height: 1).fill()
        }
        for point in history.points {
            (point.isActive ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            let x = HistoryScale.x(endFrame: point.endFrame, points: history.points, width: bounds.width)
            NSRect(x: x - 1, y: y(point.loudnessDB) - 1, width: 2, height: 2).fill()
        }
    }
}
