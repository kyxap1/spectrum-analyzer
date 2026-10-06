---
title: Levels Verdict - Plan
type: feat
date: 2026-10-06
topic: levels-verdict
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
---

# Levels Verdict - Plan

## Goal Capsule

- **Objective:** While setting up pedals, the user sees at a glance whether the rig is at unity and whether the tone matches the reference, without reading deltas. The screen stays still and shows a check mark when nothing needs changing. The analyzer is light enough to leave running.
- **Means:** the app acts as a measuring instrument. It shows differences against the reference in action steps, splits the graph into a spectrum pane and a difference pane, and draws the curves outside the per-frame SwiftUI `Canvas`.
- **Product authority:** this Product Contract. It extends `docs/plans/2026-10-06-0450-feat-pedal-setup-tools-plan.md`, whose Key Decisions and KTDs still hold unless a decision here replaces them. It takes over the topics of `docs/plans/2026-10-06-render-performance-stub.md`. The side topics in `docs/plans/2026-10-06-agent-tuning-stub.md` are not active scope.
- **Open blockers:** none.

---

## Product Contract

### Summary

The levels panel becomes one verdict strip: unity by loudness in 2 dB steps, tone by octave in 1 dB steps, and a check mark when nothing needs changing.
The graph splits into a spectrum pane with the reference as a corridor and a difference pane with per-octave step counts; a loudness history strip sits below.
Everything else moves into collapsed Details or a Settings window on ⌘,.
The app reports measurements only and never picks a device or knob; the AI advice gives physical knob moves as clock positions.
Steady Live CPU drops to 5% or less.

### Problem Frame

The levels panel shows every number and button at one level, so no number reads as the answer. The user has to know what each delta means before acting.

The peak comparison is close to noise. The reference stores whatever held peak the meter showed when Set reference was pressed (`Sources/SpectrumAnalyzer/App/SpectrumAnalyzerApp.swift:299`), and the live held peak runs since the last Clear peaks. The two windows are unbounded and unrelated, so one hard strum decides the number.

Flat RMS is dominated by the 31-125 Hz octaves. A pedal that cuts bass and lifts mids reads quieter in RMS while it sounds louder, which is the opposite of how the user sets unity by ear.

One graph carries four curves on two vertical scales: dBFS on the left and a ±30 dB difference scale on the right (`Sources/SpectrumAnalyzer/UI/SpectrumGraph.swift:26`). Which curve reads against which scale is not obvious.

Steady Live costs about 18% CPU on an M-series Mac. Nearly all of it is per-frame SwiftUI overhead around the graph `Canvas`, not the DSP. A 15 Hz publish experiment gave no gain.

The AI advice gives physical knob changes in dB with a clock position in brackets. A dB value does not map to a knob, because the knob taper is different on every pedal and nobody has measured it.

### Key Decisions

- **Loudness, not flat RMS, decides unity.** It follows the ear, and bass no longer dominates. (session-settled: user-approved — chosen over flat RMS, over a switch between both, and over average peak: unity is set by ear and flat RMS over-weights the low octaves.) Governs R1.
- **Differences are shown in action steps: 2 dB for unity, 1 dB for tone.** Level knobs are physical and coarse; the EQ2 encoder moves 1 dB per click. Steps are how much to adjust, not how finely the app measures. (session-settled: user-directed — chosen over the agent's ±1 dB unity and ±2 dB tone tolerances: the steps follow the controls the user turns.) Governs R3, R7.
- **The same input gives the same answer, and "nothing to do" holds still.** Quantize to steps, gate on the measured spread, and add hysteresis. (session-settled: user-directed — chosen over colour highlighting with a fixed threshold, which flickers at the boundary.) Governs R8, R24.
- **The held peak is replaced by average peak and crest, with a clipping warning on the first level.** (session-settled: user-approved — chosen over keeping the held peak in Details and over average peak alone: crest shows how much a pedal squashes dynamics, which the held peak never could.) Governs R5, R6, R16.
- **Layout A: the verdict strip sits above the graph.** (session-settled: user-directed — chosen over a verdict card beside the graph and over a verdict-first screen with the graph collapsed, after a visual sketch of all three.) Governs R15.
- **Two panes instead of two scales on one graph; the difference pane shows a curve over octave columns.** (session-settled: user-approved — chosen over one graph, over a curve alone and over columns alone.) Governs R11, R12, R13.
- **Lessons from existing tools: reference corridor, loudness history and crest per octave.** These come from iZotope Tonal Balance Control, Youlean Loudness Meter 2 and Mastering The Mix REFERENCE 2. (session-settled: user-directed — the user took these three and rejected Tonal Balance Control's four broad zones: the rig is tuned with ten EQ2 bands, so ten octaves stay the default.) Governs R12, R14, R16.
- **The app is an instrument; decisions live outside it.** Pre-amp EQ2 sits before the drives and the ENGL preamp, so its effect on the output is nonlinear and only a closed measurement loop can choose between the two EQ2 units. That logic belongs in a portable skill, not in app code. (session-settled: user-directed — chosen over rule-based pre-amp/post-cab hints in the app.) Governs R10, R23.
- **Physical knob moves are clock positions only.** (session-settled: user-directed — chosen over dB with a knob position and over the pedal's printed scale: printed scales differ per pedal, 0-10 on one and 0-12 on another.) Governs R19.
- **Details keeps the full set for now, and the user trims it after seeing it live.** (session-settled: user-directed — chosen over dropping Details and putting only a crest line on the first level.) Governs R16.
- **The peak-hold shadow is a toggle, off by default.** It shows short spikes that the averaged curve hides, such as resonances and fizz on the attack. (session-settled: user-approved — chosen over always on and over deferring it.) Governs R12.
- **CPU target: 5% or less to accept, 1-2% desired.** (session-settled: user-approved — chosen over a hard 1-2% and over 10% or less.) Governs R22.

### Requirements

**Level verdict**

- R1. The primary level figure is the guitar's K-weighted loudness, live against the reference, over the same window of N active seconds as the reference.
- R2. The verdict shows the direction in large text ("louder → turn down" or "quieter → turn up") with the difference in whole dB in small text, or "Unity ✓".
- R3. The unity step is 2 dB and can be changed in Settings. The verdict follows the stability rule in R24.
- R4. Without a reference, the verdict asks the user to play and press Set reference. While the window fills, it shows progress such as "4 / 10 s".
- R5. A crest line under the verdict shows the change in crest factor against the reference, such as "dynamics squashed by 4 dB", only when the change is 2 dB or more.
- R6. The held peak and the Clear peaks control are removed. The first level shows a clipping warning when an input peaks near full scale.

**Tone**

- R7. Tone is compared per standard octave band (the 10 EQ2 factory bands) in 1 dB steps that can be changed in Settings, following R24.
- R8. Above each octave column of the difference pane that is out by at least one step, a signed whole-dB number shows the difference against the reference ("+2" means 2 dB above). Columns within tolerance show nothing. Nothing is colour-highlighted.
- R9. The verdict strip carries a tone status: "Tone ✓" or "Tone: N bands".
- R10. Hovering a column with the mouse, or tapping it on the tablet, opens a short popup with the band and its difference against the reference in whole dB. The popup names no device, EQ2 unit, knob or action.

**Graph**

- R11. The graph has two panes that share the frequency axis: a spectrum pane on one dBFS scale and a difference pane centred on 0 dB.
- R12. The spectrum pane shows the live guitar and the reference as a corridor of ± one tone step. Two toggles add the mix as a dim curve and a peak-hold shadow of the guitar that holds for about 1-2 s and then falls. Both toggles are off by default.
- R13. The difference pane shows guitar minus reference as a curve over the 10 octave columns. Without a reference, it shows guitar minus mix as today.
- R14. A narrow strip shows the guitar's loudness over the last minutes with the reference level as a line.

**Layout and settings**

- R15. Normal mode reads from top to bottom: the verdict strip with Set reference as its primary button, the two graph panes, the loudness history strip, collapsed Details, the transport, and the AI advice.
- R16. Details is collapsed by default. It holds third-octave differences, input meters, average peak, crest overall and per octave against the reference, and window progress.
- R17. A standard macOS Settings window opens with ⌘, and from a ⚙ button. It holds the activity thresholds with Learn noise, the window N, the unity and tone steps, and the export toggle.
- R18. Display Mode shows the verdict strip, the difference pane and the loudness history strip in large type, plus the spectrum pane when toggled on. Popups open on tap.

**Advice wording**

- R19. The AI advice gives every physical knob change as a clock position in American clock notation: 7 o'clock is minimum, 12 o'clock is centre and 5 o'clock is maximum. It never uses dB, percent or the pedal's printed scale for these knobs. EQ2 bands stay in whole dB, the EQ2 OUTPUT knob is a clock position, and switches are named by position as today.

**Export and snapshots**

- R20. The export document moves to version 2. It adds loudness, average peak, crest, the per-octave step counts, and the steps and noise bounds in use, so an agent reads the same "nothing to do" as the screen. The held-peak meaning is removed. The export stays read-only in this plan, and its shape stays open to commands.
- R21. Snapshots saved before this change still load. Their loudness verdict works from the stored band powers. Their average peak and crest differences show as unknown.

**Performance**

- R22. Steady Live uses 5% CPU or less on the user's M-series Mac with every pane visible, measured the same way as the current 18% reading.

**Instrument boundary**

- R23. App code never chooses a device, an EQ2 unit, a knob or an order of adjustment. On-screen output is measurements and differences in steps. The existing AI advice is the one exception and changes only as R19 says.
- R24. Stability rule for R3 and R7: a difference is rounded to the nearest step, and zero steps means nothing to do. A non-zero result shows only when the difference is clearly larger than its spread across the hops in the window. A figure leaves "nothing to do" at a full step and returns below half a step.

### Acceptance Examples

- AE1. **Covers R2, R3, R24.** **Given** a reference and steady playing, **when** live loudness is 0.6 dB above it, **then** the verdict reads "Unity ✓". **When** it rises to 2.3 dB above, **then** it reads "louder → turn down" with "+2 dB". **When** it falls back to 1.4 dB, **then** it still reads "louder" and turns to "Unity ✓" only below 1 dB.
- AE2. **Covers R7, R8, R24.** **Given** live playing where the 1k octave spreads by about ±2 dB across hops, **when** its difference is 1.2 dB, **then** no number shows above 1k. **Given** a repeatable input that spreads by about ±0.3 dB, **when** the difference is the same 1.2 dB, **then** "+1" shows above 1k.
- AE3. **Covers R4, R9.** **Given** no reference, **then** the verdict asks the user to play and press Set reference, and no tone status shows.
- AE4. **Covers R10, R18.** **Given** Display Mode on the tablet, **when** the user taps the 125 column, **then** a popup reads "125 Hz: −3 dB against the reference" and names no pedal.
- AE5. **Covers R21.** **Given** a snapshot saved before this change, **when** it is loaded, **then** the unity verdict and the tone numbers work, and the crest line stays hidden.

### Success Criteria

- From the tablet across the room, the user can tell "unity / turn down / turn up" and "tone OK / N bands" without reading a number.
- When the rig matches the reference, the screen shows only check marks and holds still through ordinary playing.
- R22 holds on the real rig. The user reviews the Details content live and trims it in a follow-up if needed.

### Scope Boundaries

- The AI advice keeps its behaviour except for the wording in R19. Moving it into a skill is deferred.
- Transport, scrubbing, Reset and the snapshot store keep their behaviour and only move in the layout.
- Commands in the export, the optimisation skill, MIDI control and the HX One looper as a repeatable input are deferred to `docs/plans/2026-10-06-agent-tuning-stub.md`.
- A waterfall or spectrogram view is deferred.
- A Metal renderer is in scope only if the layer-backed renderer cannot meet R22.

<!-- ce-section: work-relationships -->
### How This Work Fits Together

This plan owns the measurement and display side of the analyzer. The breakdown below reflects current understanding, not a committed roadmap.

- Agent tuning (`docs/plans/2026-10-06-agent-tuning-stub.md`)
  - Depends on R20 and R24: the agent reads the same step semantics through the export.
  - Still to decide: export commands, the skill, the MIDI closed loop and the HX One looper input.

### Outstanding Questions

**Deferred to Planning**

- How loudness is computed so that live readings and old snapshots compare on equal terms (R1, R21). Weighting the stored third-octave band powers is one option.
- What "clearly larger than its spread" means as a statistic, and how it behaves for windows with few hops (R24).
- The clipping threshold and how long the warning holds (R6).
- The length of the loudness history strip (R14).
- Where snapshot Save as and Snapshots… sit in the verdict strip (R15).
- The renderer for the panes and the history strip, and how CPU is measured for R22.

### Sources / Research

- Held peak at the moment of Set reference: `Sources/SpectrumAnalyzer/App/SpectrumAnalyzerApp.swift:299`. Live peak handling: `Sources/SpectrumAnalyzer/Levels/LevelMeter.swift`, `Sources/SpectrumAnalyzer/Levels/LiveLevels.swift`.
- Per-hop log with no per-hop peak today: `Sources/SpectrumAnalyzer/Levels/BandLog.swift`.
- Export versioning rule (renaming or removing a field needs a version bump): `Sources/SpectrumAnalyzer/Export/LevelsDocument.swift:10`.
- Two scales on one graph: `Sources/SpectrumAnalyzer/UI/SpectrumGraph.swift:26`.
- Advice wording that R19 changes: `Sources/SpectrumAnalyzer/Advice/prompt.md`.
- No `Settings` scene today, only a `WindowGroup`: `Sources/SpectrumAnalyzer/App/SpectrumAnalyzerApp.swift:8`. A SwiftUI `Settings` scene adds the standard menu item with ⌘, (https://developer.apple.com/documentation/swiftui/settings).
- EQ2: 10 bands, each movable from 20 Hz to 20 kHz, 1 dB per encoder click: https://pedals.kyxap.pro/source-audio-eq2/#basic-operation
- Tools the lessons come from:
  - Mastering The Mix REFERENCE 2 (level match by LUFS, a level line around 0 dB, Punch Dots): https://www.masteringthemix.com/pages/reference-2-manual
  - iZotope Tonal Balance Control (target range as a band, broad and fine views): https://downloads.izotope.com/docs/ozone8/tonal-balance-control/index.html
  - ADPTR Metric AB (single, dual and layered views): https://www.plugin-alliance.com/products/metric-ab
  - Voxengo SPAN (secondary maximum spectrum in a darker colour)
  - Youlean Loudness Meter 2 (loudness history graph): https://youlean.co/wp-content/uploads/2019/04/Youlean-Loudness-Meter-2-V2.2.1-MANUAL.pdf
