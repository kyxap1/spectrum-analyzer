import Foundation

/// The reply language, appended to the prompt so a custom prompt keeps it.
enum AdviceLanguage: String, CaseIterable {
    case russian
    case english

    var instruction: String? {
        switch self {
        case .russian: "Write the reply in Russian, but keep technical terms and device, control and parameter names in English."
        case .english: nil
        }
    }
}

/// What the balance is for, appended to the prompt so a custom prompt keeps
/// it. The default prompt already describes the mix goal.
enum AdviceGoal: String, CaseIterable {
    case practice
    case mix

    var instruction: String? {
        switch self {
        case .practice: "Goal override: the player practices over backing tracks and must hear their own playing clearly, including mistakes. Instead of blending into the mix, the guitar should sit slightly in front of it and stay articulate (pick attack, upper mids), without being so loud that it drowns the backing track. A moderately positive difference is therefore wanted, not a collision. Judge the band shape of the difference rather than its absolute offset, since the interface input gain and the monitor balance the player hears are not measured."
        case .mix: nil
        }
    }
}

/// The advice prompt, the starting positions and the domains the CLI may fetch
/// from. Defaults ship as `prompt.md`, `starting-positions.md` and
/// `fetch-domains.txt`; an edit is stored in `UserDefaults`
/// only while it differs from the default, so a changed default still applies.
enum AdviceSettings {
    static let promptKey = "advice.prompt"
    static let fetchDomainsKey = "advice.fetchDomains"
    static let startingPositionsKey = "advice.startingPositions"

    static let defaultPrompt = resource("prompt", "md")
    static let defaultStartingPositions = resource("starting-positions", "md")
    static let defaultFetchDomains = resource("fetch-domains", "txt")

    /// Splits on whitespace and commas, dropping empties.
    static func domains(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }

    static func load(_ key: String, default value: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? value
    }

    static func store(_ text: String, _ key: String, default value: String) {
        if text == value {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(text, forKey: key)
        }
    }

    /// `Bundle.module` looks for its bundle at the `.app` root, outside
    /// `Contents`, where codesign refuses it; `bundle.sh` copies these files
    /// into `Contents/Resources` instead, and tests fall through to the module.
    private static func resource(_ name: String, _ ext: String) -> String {
        let url = Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.module.url(forResource: name, withExtension: ext)!
        return try! String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
