import AppKit
import SwiftUI

/// KTD10: display mode is switched by hand and remembered for the screen it
/// was turned on for. Moving the window to another screen turns it off, and
/// back to the remembered one turns it on again. Pure so it tests without
/// windows; screens are matched by name only.
struct DisplayModeMemory: Equatable {
    private(set) var isOn = false
    private(set) var remembered: String?
    private var currentScreen: String?
    /// Turned on before any screen was reported: the first one is remembered.
    private var awaitingScreen = false

    init(remembered: String? = nil) {
        self.remembered = remembered
    }

    mutating func setOn(_ on: Bool) {
        isOn = on
        remembered = on ? currentScreen : nil
        awaitingScreen = on && currentScreen == nil
    }

    mutating func screenChanged(to name: String?) {
        currentScreen = name
        if awaitingScreen, let name {
            remembered = name
            awaitingScreen = false
        } else if remembered != nil {
            isOn = name == remembered
        }
    }
}

/// Type and target sizes for one switch, so every view scales together (R14).
struct DisplaySizes {
    let isDisplayMode: Bool
    let axis: Font
    let legend: Font
    let label: Font
    let readout: Font
    let verdict: Font
    let touchHeight: CGFloat

    static let normal = DisplaySizes(isDisplayMode: false, axis: .caption2, legend: .caption, label: .headline,
                                     readout: .body, verdict: .title.weight(.semibold), touchHeight: 0)
    /// A 10-inch 1920x1200 tablet as a second display at 1280x800 points.
    static let display = DisplaySizes(isDisplayMode: true, axis: .system(size: 15), legend: .system(size: 17),
                                      label: .system(size: 22, weight: .semibold),
                                      readout: .system(size: 24, weight: .semibold),
                                      verdict: .system(size: 26, weight: .bold), touchHeight: 48)

    /// `readout` for numbers drawn by AppKit views, with fixed-width digits.
    var readoutNSFont: NSFont {
        isDisplayMode ? .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
            : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    /// `axis` and `legend` for text drawn by the graph's layers.
    var axisNSFont: NSFont { isDisplayMode ? .systemFont(ofSize: 15) : .preferredFont(forTextStyle: .caption2) }
    var legendNSFont: NSFont { isDisplayMode ? .systemFont(ofSize: 17) : .preferredFont(forTextStyle: .caption1) }

    /// Every graph's plot starts here, so stacked graphs share one left edge.
    var plotLeft: Double {
        let width = { (string: String, font: NSFont) in (string as NSString).size(withAttributes: [.font: font]).width }
        return ceil(max(width("\u{2212}100", axisNSFont), width("vs ref", legendNSFont))) + 10
    }
}

/// Display mode's graph panes as shares of the window height, so a taller
/// screen gives them room instead of only the spectrum graph, which takes
/// what is left. The floors are the sizes tuned on a 1280x800 tablet.
struct PaneHeights: Equatable {
    static let floor = PaneHeights(windowHeight: 0)

    let octave: CGFloat
    let difference: CGFloat
    let history: CGFloat

    init(windowHeight: CGFloat) {
        octave = max(144, (windowHeight * 0.18).rounded())
        difference = max(137, (windowHeight * 0.15).rounded())
        history = max(98, (windowHeight * 0.15).rounded())
    }
}

private struct DisplaySizesKey: EnvironmentKey {
    static let defaultValue = DisplaySizes.normal
}

extension EnvironmentValues {
    var displaySizes: DisplaySizes {
        get { self[DisplaySizesKey.self] }
        set { self[DisplaySizesKey.self] = newValue }
    }
}

/// Reports the name of the screen the hosting window is on, now and whenever
/// it moves.
struct ScreenReader: NSViewRepresentable {
    let onChange: (String?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScreenView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ScreenView)?.onChange = onChange
    }

    private final class ScreenView: NSView {
        var onChange: (String?) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            report(window)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification,
                                                              object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if let self, let window { self.report(window) }
                }
            }
        }

        private func report(_ window: NSWindow) {
            let name = window.screen?.localizedName
            // Deferred so a publish never lands inside a view update.
            DispatchQueue.main.async { [onChange] in onChange(name) }
        }
    }
}

/// Large touch targets for the tablet: Pause, Resume live, Set reference,
/// Reset and More. Reset sits apart from Set reference so a mistap cannot
/// clear the history (R15). The outcome of Set reference shows in the
/// verdict strip.
struct DisplayTouchRow: View {
    let state: SessionState
    let onPause: () -> Void
    let onResumeLive: () -> Void
    let onSetReference: () -> Void
    let onReset: () -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            button("Pause", action: onPause).disabled(state != .live)
            button("Resume live", action: onResumeLive).disabled(state == .live)
            button("Set reference", action: onSetReference).buttonStyle(.borderedProminent)
            Spacer(minLength: 72)
            button("Reset", action: onReset)
            button("More", action: onMore)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DisplaySizes.display.label)
                .frame(maxWidth: .infinity, minHeight: DisplaySizes.display.touchHeight)
        }
    }
}
