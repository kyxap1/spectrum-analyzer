import Testing
@testable import SpectrumAnalyzer

private func verdict(unity: Int? = 0, tone: [Int]? = [Int](repeating: 0, count: 10), crest: Int? = 0,
                     unityStep: Float = 2, active: Double = 10) -> Verdict {
    Verdict(unitySteps: unity, toneSteps: tone, crestSteps: crest, unityStepDB: unityStep, toneStepDB: 1,
            activeSeconds: active, windowSeconds: 10, loudnessDifferenceDB: nil,
            unitySpreadDB: nil, toneSpreadDB: nil, crestSpreadDB: nil)
}

@Suite("VerdictText")
struct VerdictTextTests {
    @Test("louder reads turn down with +2 dB, quieter reads turn up with -2 dB, and zero reads Unity")
    func direction() {
        let louder = VerdictText(verdict(unity: 1))
        #expect(louder.direction == "louder \u{2192} turn down")
        #expect(louder.detail == "+2 dB")
        let quieter = VerdictText(verdict(unity: -1))
        #expect(quieter.direction == "quieter \u{2192} turn up")
        #expect(quieter.detail == "\u{2212}2 dB")
        #expect(VerdictText(verdict(unity: 2, unityStep: 3)).detail == "+6 dB")
        #expect(VerdictText(verdict(unity: 0)).direction == "Unity \u{2713}")
        #expect(VerdictText(verdict(unity: 0)).detail == nil)
    }

    @Test("tone reads Tone ✓ with no non-zero column, and counts the bands otherwise")
    func tone() {
        #expect(VerdictText(verdict()).tone == "Tone \u{2713}")
        var two = [Int](repeating: 0, count: 10)
        two[2] = 1
        two[7] = -2
        #expect(VerdictText(verdict(tone: two)).tone == "Tone: 2 bands")
        two[7] = 0
        #expect(VerdictText(verdict(tone: two)).tone == "Tone: 1 band")
    }

    @Test("covers AE3: without a reference it asks to play and press Set reference, with no tone status; while filling it shows progress")
    func noReferenceAndFilling() {
        let none = VerdictText(nil)
        #expect(none.direction == "Play, then press Set reference")
        #expect(none.tone == nil)
        #expect(none.crest == nil)
        let filling = VerdictText(verdict(unity: nil, tone: nil, crest: nil, active: 4))
        #expect(filling.detail == "4 / 10 s")
        #expect(filling.tone == nil)
    }

    @Test("a reference shorter than its window gives no advice, only a request to set it again (R25)")
    func referenceTooShort() {
        let text = VerdictText(nil, referenceTooShort: true)
        #expect(text.direction == "Reference too short \u{2014} set it again")
        #expect(text.detail == nil)
        #expect(text.tone == nil)
        #expect(text.crest == nil)
    }

    @Test("the crest line reads squashed for a negative change and stays empty at zero")
    func crest() {
        #expect(VerdictText(verdict(crest: -2)).crest == "dynamics squashed by 4 dB")
        #expect(VerdictText(verdict(crest: 1)).crest == "dynamics opened up by 2 dB")
        #expect(VerdictText(verdict(crest: 0)).crest == nil)
        #expect(VerdictText(verdict(crest: nil)).crest == nil)
    }

    @Test("paused or scrubbing keeps the last verdict greyed out with Paused")
    func paused() {
        let paused = VerdictText(verdict(unity: 1), isPaused: true)
        #expect(paused.direction == "louder \u{2192} turn down")
        #expect(paused.status == "Paused")
        #expect(paused.isDimmed)
        #expect(!VerdictText(verdict(unity: 1)).isDimmed)
    }

    @Test("silence adds no hop, so the verdict and its text stay as they were")
    func silenceKeepsVerdict() {
        var tracker = VerdictTracker()
        let hops = (0..<20).map {
            LogHop(sequence: $0, endFrame: ($0 + 1) * BandLog.hopFrames, rmsDBFS: -20,
                   bands: [Float](repeating: 2, count: ThirdOctaveBands.centerFrequencies.count),
                   display: [Float](repeating: 1, count: SpectrumAnalyzer.displayPointCount), peakDBFS: -6)
        }
        let reference = Reference.make(guitar: BandLog.average(hops.map {
            LogHop(sequence: $0.sequence, endFrame: $0.endFrame, rmsDBFS: -20,
                   bands: [Float](repeating: 1, count: ThirdOctaveBands.centerFrequencies.count),
                   display: $0.display, peakDBFS: -6)
        }), mix: BandLog.average([]), windowSeconds: 10)!
        let window = BandLog.average(hops)
        let first = VerdictText(tracker.update(Comparison.make(reference: reference, window: window, windowHops: 20)))
        // Silence: the active window is the same hops.
        let again = VerdictText(tracker.update(Comparison.make(reference: reference, window: window, windowHops: 20)))
        #expect(first == again)
        #expect(first.direction == "louder \u{2192} turn down")
    }
}
