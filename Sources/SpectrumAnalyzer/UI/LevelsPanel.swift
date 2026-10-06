import SwiftUI

/// Live RMS and peak for guitar and mix, between the graph and the controls
/// (R5). The guitar meter reads unavailable while the interface is not captured.
struct LevelsPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            MeterView(title: "Guitar", reading: model.guitarLevel)
            MeterView(title: "Mix", reading: model.mixLevel)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
