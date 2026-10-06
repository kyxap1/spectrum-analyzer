---
title: Agent tuning - stub
date: 2026-10-06
status: stub
---

# Agent tuning - stub

Hand-written seed for a later brainstorm. Not a plan: no units, no contract, not for `ce-work`. It holds the side topics from the levels-verdict brainstorm (`docs/plans/2026-10-06-1341-feat-levels-verdict-plan.md`) and does not overlap with it.

## Principle

- The app is an instrument: it measures and reports differences in steps. Choosing which device, EQ2 unit or knob to turn, and in what order, belongs in a portable skill, not in app code.
- The skill reads the export and, later, drives pedals through the guitar MIDI controller's MCP server. A heavy numeric part, if one appears, goes into a small separate tool that the skill calls, not into the app.
- No separate middleware process: the agent with the skill is the orchestrator. A middleware process is needed only if sub-second sync between the looper and the measurement turns out to matter.

## Why the decision cannot live in the app

- Chain: guitar → NS-1X → EQ2 (pre-amp) → compressor → XS-1 → Plethora → Fortin → Timmy → ENGL preamp → loop with booster → power amp → Captor → Cab X2 → EQ2 (post-cab) → Terraform → Collider → RC-5 → Scarlett. The app hears only the end of it (https://rig.kyxap.pro/raw).
- Post-cab EQ2 is linear: +3 dB at 1k reads as +3 dB at 1k. Pre-amp EQ2 feeds the drives and the tube preamp, so it is nonlinear. A change shows up as a smaller change at the band, extra harmonics and lost dynamics. The pre-amp 31, 62, 8k and 16k bands mostly change how the drive behaves, because the cab sim cuts those bands afterwards.
- Analog knobs (compressor volume, drive levels) cannot be turned digitally. dB to clock depends on each pedal's pot taper, which nobody has measured. Calibrating by hand at every session is not realistic.

## Approaches discussed for pre-amp vs post-cab

- A. Roles by convention: post-cab balances the tone; pre-amp sets the drive character once per channel or gain setting.
- B. A plus two recognisable patterns: loose lows under gain together with a crest drop points at pre-amp 125; fizz at 4-8k points at pre-amp 4k. This is a heuristic.
- C. Measured transfer: move one pre-amp band by a known amount against a reference and record what the output does at the current gain. Closed-loop control makes this cheap for an agent and impractical for a human.

## Closed loop

- One step: the agent starts the looper, marks the app, waits N active seconds, reads the window since the mark, moves an EQ2 CC, and repeats.
- EQ2 has MIDI CCs for each band's frequency, level and Q (https://pedals.kyxap.pro/source-audio-eq2/#midi-mapping). Other pedals' MIDI was not checked.
- Analog knobs stay manual. The agent guides the user with the unity verdict: "turn the Timmy level until Unity ✓".
- Recommendations for physical knobs use clock positions in American notation only, from 7 o'clock (minimum) through 12 o'clock to 5 o'clock (maximum). They never use dB, percent or the pedal's printed scale. EQ2 bands use whole dB.

## Repeatable input: Line 6 HX One looper

- The HX One replaces the Plethora. In I/O Config "Insert" with Insert Position set per preset, its looper can sit before the EQ2 pre-amp and the compressor while the pedal stays in the Plethora's place (https://pedals.kyxap.pro/line6-hx-one/#four-cable-method). The same dry phrase then runs through the whole chain each time, which removes the "played differently each take" noise from every measurement.
- The looper is controllable by MIDI CC or Note (https://pedals.kyxap.pro/line6-hx-one/#midi-looper-control).
- Limits from the manual (https://pedals.kyxap.pro/line6-hx-one/#looper):
  - Insert mode records and plays in mono.
  - A mono loop is 60 s at most.
  - The loop is discarded on a preset change and on power-off, so the agent must not switch HX One presets mid-run.
  - The looper is one of the HX One effect models, so while it is loaded the HX One is not the Plethora's replacement effect.

## App work this needs

- Commands in the export, loopback only: set a mark and read the window since the mark (`BandLog.window(since:)` already filters by sequence), Set reference, Reset, choose N, and start/stop capture.
- Move the AI advice into the skill.

## Candidates

- Crest per octave as a first-level signal, if the Details review shows it is used.
- A waterfall or spectrogram view, if CPU allows.

## Open

- Verify the HX One routing on the real rig once the pedal arrives.
