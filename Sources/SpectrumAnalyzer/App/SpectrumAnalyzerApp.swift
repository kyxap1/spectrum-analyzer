import SwiftUI

@main
struct SpectrumAnalyzerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        Text("Spectrum Analyzer")
            .frame(minWidth: 480, minHeight: 320)
    }
}
