import AVFoundation
import Testing
@testable import SpectrumAnalyzer

@Suite("AdviceMarkdown")
struct AdviceMarkdownTests {
    @Test("headings turn bold, list markers turn into bullets, inline markup is parsed")
    func rewritesBlockSyntax() {
        let rendered = AdviceMarkdown.attributed("## Level\n- **Treble** +2\n  * nested\n2 * 3 = 6")

        #expect(String(rendered.characters) == "Level\n\u{2022} Treble +2\n  \u{2022} nested\n2 * 3 = 6")
        let bold = rendered.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(rendered[$0.range].characters) }
        #expect(bold == ["Level", "Treble"])
    }
}
