import SwiftUI

/// Formats a frame count in `m:ss` for the scrubber labels.
func formatMMSS(seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// Transport, scrubber, Reset, pin toggle and smoothing picker (R7, R9, R15).
struct ControlsBar: View {
    let state: SessionState
    let scrubRangeSeconds: ClosedRange<Int>
    @Binding var scrubSeconds: Int
    @Binding var pinned: Bool
    @Binding var timeConstant: Double

    let onPause: () -> Void
    let onPlay: () -> Void
    let onResumeLive: () -> Void
    let onScrub: (Int) -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: onPause) { Image(systemName: "pause.fill") }
                    .disabled(state != .live && state != .replaying)
                Button(action: onPlay) { Image(systemName: "play.fill") }
                    .disabled(state != .paused)
                Button("Resume Live", action: onResumeLive)
                    .disabled(state == .live)
                Spacer()
                Button("Reset", action: onReset)
                Toggle("Pin on Top", isOn: $pinned)
                Picker("Smoothing", selection: $timeConstant) {
                    Text("1 s").tag(1.0)
                    Text("3 s").tag(3.0)
                    Text("8 s").tag(8.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            HStack {
                Text(formatMMSS(seconds: scrubRangeSeconds.lowerBound))
                Slider(value: Binding(get: { Double(scrubSeconds) },
                                      set: { onScrub(Int($0)) }),
                       in: Double(scrubRangeSeconds.lowerBound)...Double(scrubRangeSeconds.upperBound))
                    .disabled(state == .live)
                Text(formatMMSS(seconds: scrubRangeSeconds.upperBound))
            }
        }
        .padding(8)
    }
}
