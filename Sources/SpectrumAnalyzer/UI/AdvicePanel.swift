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
    @Binding var model: String

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
                .frame(width: 160)
                .disabled(state == .running)

                if state == .running {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: onCancel)
                } else {
                    Button("Get AI Recommendation", action: onRequest)
                        .disabled(!isAvailable)
                }
                Spacer()
            }
            switch state {
            case .idle, .running:
                EmptyView()
            case .answer(let text, let usage, let model):
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                Text("\(model.capitalized) \u{2014} \(usage.inputTokens) input / \(usage.outputTokens) output tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .error(let message):
                Text(message).foregroundStyle(.red)
            }
        }
        .padding(8)
    }
}
