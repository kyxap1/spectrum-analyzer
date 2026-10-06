import SwiftUI

enum AdviceState: Equatable {
    case idle
    case running
    case answer(text: String, usage: AdviceUsage, model: String)
    case error(String)
}

/// F2: model picker, the recommendation button, progress, and the answer or
/// an error shown in place (R16, R18).
struct AdvicePanel: View {
    let state: AdviceState
    let isAvailable: Bool
    let progress: String
    let liveUsage: AdviceUsage?
    @Binding var model: String
    @Binding var profile: String
    @Binding var language: AdviceLanguage
    @Binding var goal: AdviceGoal
    @Binding var prompt: String
    @Binding var startingPositions: String
    @Binding var fetchDomains: String
    let pedals: [String]
    @Binding var engagedPedals: Set<String>
    @Binding var rigNotes: String
    let isRefreshingRig: Bool
    let onRefreshRig: () -> Void
    let previousRoundDate: Date?
    let onStartOver: () -> Void
    @State private var isEditingSettings = false

    let onRequest: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Model", selection: $model) {
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(state == .running)

                Picker("Profile", selection: $profile) {
                    Text("claude-private").tag("claude-private")
                    Text("claude-private2").tag("claude-private2")
                }
                .fixedSize()
                .disabled(state == .running)

                Picker("Language", selection: $language) {
                    Text("Русский").tag(AdviceLanguage.russian)
                    Text("English").tag(AdviceLanguage.english)
                }
                .fixedSize()
                .disabled(state == .running)

                Picker("Goal", selection: $goal) {
                    Text("Practice").tag(AdviceGoal.practice)
                    Text("Mix").tag(AdviceGoal.mix)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Practice: hear yourself clearly over the backing track. Mix: blend the guitar into the mix.")
                .disabled(state == .running)

                if state == .running {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: onCancel)
                } else {
                    Button("Get AI Recommendation", action: onRequest)
                        .disabled(!isAvailable)
                }
                Button("Prompt\u{2026}") { isEditingSettings = true }
                    .disabled(state == .running)
                if state == .running {
                    Text(progress).foregroundStyle(.secondary).lineLimit(1)
                    if let liveUsage {
                        Text("\(liveUsage.inputTokens.formatted()) in / \(liveUsage.outputTokens.formatted()) out tokens")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            Group {
                if !pedals.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 4) {
                        ForEach(pedals, id: \.self) { pedal in
                            Toggle(pedal, isOn: pedalBinding(pedal))
                                .toggleStyle(.checkbox)
                                .lineLimit(1)
                        }
                    }
                }
                HStack(alignment: .top) {
                    TextField("Now: amp channel, pedal modes, Cab X2 LC/HC\u{2026}", text: $rigNotes, axis: .vertical)
                        .lineLimit(1...3)
                    Button(action: onRefreshRig) {
                        Label("Refresh Rig", systemImage: "arrow.clockwise")
                    }
                    .help("Reload the pedal list from the rig page")
                    .disabled(isRefreshingRig)
                }
                if let previousRoundDate {
                    HStack {
                        Text("Previous round: \(previousRoundDate.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                        Button("Start Over", action: onStartOver)
                            .help("Forget the previous round's settings, for when the rig is back at its defaults")
                    }
                }
            }
            .disabled(state == .running)
            switch state {
            case .idle, .running:
                EmptyView()
            case .answer(let text, let usage, let model):
                ScrollView {
                    Text(AdviceMarkdown.attributed(text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("\(model.capitalized) \u{2014} \(usage.inputTokens.formatted()) input / \(usage.outputTokens.formatted()) output tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .error(let message):
                Text(message).foregroundStyle(.red)
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $isEditingSettings) {
            AdviceSettingsSheet(prompt: $prompt, startingPositions: $startingPositions, fetchDomains: $fetchDomains)
        }
    }

    private func pedalBinding(_ pedal: String) -> Binding<Bool> {
        Binding(get: { engagedPedals.contains(pedal) },
                set: { isOn in
            if isOn { engagedPedals.insert(pedal) } else { engagedPedals.remove(pedal) }
        })
    }
}

/// SwiftUI `Text` renders only inline markdown, so block syntax is rewritten
/// first: headings become bold lines and list markers become bullets.
enum AdviceMarkdown {
    static func attributed(_ text: String) -> AttributedString {
        let source = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let heading = line.drop(while: { $0 == "#" })
            if heading.count < line.count, heading.first == " " {
                return "**\(heading.dropFirst())**"
            }
            let indent = line.prefix(while: { $0 == " " })
            let rest = line.dropFirst(indent.count)
            if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
                return "\(indent)\u{2022} \(rest.dropFirst(2))"
            }
            return String(line)
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(text)
    }
}

/// Edits the advice prompt, the starting positions and the domains the CLI may
/// fetch from; each field
/// resets to the default shipped in the repo.
private struct AdviceSettingsSheet: View {
    @Binding var prompt: String
    @Binding var startingPositions: String
    @Binding var fetchDomains: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Prompt").font(.headline)
                Spacer()
                Button("Reset to Default") { prompt = AdviceSettings.defaultPrompt }
                    .disabled(prompt == AdviceSettings.defaultPrompt)
            }
            TextEditor(text: $prompt)
                .font(.body.monospaced())
                .frame(minHeight: 140)
            HStack {
                Text("Starting positions").font(.headline)
                Spacer()
                Button("Reset to Default") { startingPositions = AdviceSettings.defaultStartingPositions }
                    .disabled(startingPositions == AdviceSettings.defaultStartingPositions)
            }
            TextEditor(text: $startingPositions)
                .font(.body.monospaced())
                .frame(minHeight: 140)
            HStack {
                Text("Fetch domains").font(.headline)
                Spacer()
                Button("Reset to Default") { fetchDomains = AdviceSettings.defaultFetchDomains }
                    .disabled(fetchDomains == AdviceSettings.defaultFetchDomains)
            }
            Text("One per line or comma-separated. Empty disables web access.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $fetchDomains)
                .font(.body.monospaced())
                .frame(height: 60)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560, height: 640)
    }
}
