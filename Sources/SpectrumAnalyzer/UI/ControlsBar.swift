import AppKit
import SwiftUI

/// Formats a frame count in `m:ss` for the scrubber labels.
func formatMMSS(seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// Transport, scrubber, Reset, pin toggle and smoothing picker (R7, R9, R15).
struct ControlsBar: View {
    let state: SessionState
    let scrub: LiveSink<ScrubPosition>
    @Binding var pinned: Bool
    @Binding var viewMode: ViewMode
    @Binding var showPeakHold: Bool
    @Binding var displayMode: Bool
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
                Button("Reset", action: onReset)
                Spacer()
                Picker("View", selection: $viewMode) {
                    Text("Real-time").tag(ViewMode.realtime)
                    Text("Tune").tag(ViewMode.tune)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Real-time follows the signal; Tune shows figures over the last seconds of playing, which hold still while you turn a knob")
                Toggle("Peak hold", isOn: $showPeakHold)
                    .help("Show the guitar's recent peaks, held 3 s, as a shadow above its curve")
                Toggle("Display Mode", isOn: $displayMode)
                    .help("Large type and touch targets for a tablet; remembered for this screen")
                Toggle("Pin on Top", isOn: $pinned)
                Picker("Smoothing", selection: $timeConstant) {
                    Text("1 s").tag(1.0)
                    Text("3 s").tag(3.0)
                    Text("8 s").tag(8.0)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .padding(.leading, 16)
            }
            Scrubber(scrub: scrub, isLive: state == .live, onScrub: onScrub)
        }
        .padding(8)
    }
}

struct ScrubPosition: Equatable {
    var seconds = 0
    var rangeSeconds: ClosedRange<Int> = 0...0
}

/// The position changes every second, so it reaches an AppKit slider through
/// a sink instead of SwiftUI state, which would re-lay out the window (KTD7).
private struct Scrubber: NSViewRepresentable {
    let scrub: LiveSink<ScrubPosition>
    let isLive: Bool
    let onScrub: (Int) -> Void

    func makeNSView(context: Context) -> ScrubberView {
        let view = ScrubberView()
        scrub.attach(view) { view, position in view.show(position) }
        return view
    }

    func updateNSView(_ view: ScrubberView, context: Context) {
        view.isLive = isLive
        view.onScrub = onScrub
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScrubberView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.slider.intrinsicContentSize.height)
    }
}

/// Draws its two times itself: a text field would re-measure on every new
/// time and lay out the window again. Live, there is nothing to scrub: it
/// shows a capture mark and the length captured instead of the slider.
private final class ScrubberView: NSView {
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 0, target: nil, action: nil)
    var onScrub: (Int) -> Void = { _ in }
    var isLive = true {
        didSet {
            guard isLive != oldValue else { return }
            slider.isHidden = isLive
            needsDisplay = true
        }
    }
    private var position = ScrubPosition()
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor,
    ]
    private static let labelWidth = ceil(("00:00" as NSString).size(withAttributes: attributes).width) + 8

    init() {
        super.init(frame: .zero)
        slider.target = self
        slider.action = #selector(scrubbed)
        slider.isHidden = isLive
        addSubview(slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        slider.frame = bounds.insetBy(dx: Self.labelWidth, dy: 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isLive {
            drawRecording()
            return
        }
        let now = formatMMSS(seconds: position.seconds) as NSString
        let end = formatMMSS(seconds: position.rangeSeconds.upperBound) as NSString
        let height = now.size(withAttributes: Self.attributes).height
        let y = (bounds.height - height) / 2
        now.draw(at: NSPoint(x: 0, y: y), withAttributes: Self.attributes)
        end.draw(at: NSPoint(x: bounds.width - end.size(withAttributes: Self.attributes).width, y: y),
                 withAttributes: Self.attributes)
    }

    private func drawRecording() {
        let text = NSMutableAttributedString(string: "\u{25CF} ", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.systemRed,
        ])
        text.append(NSAttributedString(string: "Capturing  " + formatMMSS(seconds: position.rangeSeconds.upperBound),
                                       attributes: Self.attributes))
        text.draw(at: NSPoint(x: 0, y: (bounds.height - text.size().height) / 2))
    }

    func show(_ position: ScrubPosition) {
        self.position = position
        needsDisplay = true
        slider.minValue = Double(position.rangeSeconds.lowerBound)
        slider.maxValue = Double(position.rangeSeconds.upperBound)
        slider.doubleValue = Double(position.seconds)
    }

    @objc private func scrubbed() { onScrub(Int(slider.doubleValue)) }
}
