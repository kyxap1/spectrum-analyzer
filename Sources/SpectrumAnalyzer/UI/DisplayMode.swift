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
    let touchHeight: CGFloat

    static let normal = DisplaySizes(isDisplayMode: false, axis: .caption2, legend: .caption, label: .headline,
                                     readout: .body, touchHeight: 0)
    /// About 2 m from a 10-inch 1920x1200 screen.
    static let display = DisplaySizes(isDisplayMode: true, axis: .system(size: 20), legend: .system(size: 20),
                                      label: .system(size: 24, weight: .semibold),
                                      readout: .system(size: 40, weight: .semibold), touchHeight: 88)
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
/// clear the history (R15).
struct DisplayTouchRow: View {
    let state: SessionState
    let status: String
    let onPause: () -> Void
    let onResumeLive: () -> Void
    let onSetReference: () -> Void
    let onReset: () -> Void
    let onMore: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(status).font(DisplaySizes.display.label).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 16) {
                button("Pause", action: onPause).disabled(state != .live)
                button("Resume live", action: onResumeLive).disabled(state == .live)
                button("Set reference", action: onSetReference)
                Spacer(minLength: 72)
                button("Reset", action: onReset)
                button("More", action: onMore)
            }
        }
        .padding(12)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DisplaySizes.display.label)
                .frame(maxWidth: .infinity, minHeight: DisplaySizes.display.touchHeight)
        }
        .buttonStyle(.bordered)
    }
}
