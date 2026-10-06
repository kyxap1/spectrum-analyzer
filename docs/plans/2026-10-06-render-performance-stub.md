---
title: Render performance and levels UI - stub
date: 2026-10-06
status: stub
---

# Render performance and levels UI - stub

Hand-written seed for a later brainstorm. Not a plan: no units, no contract, not for `ce-work`.

## Render performance

- Target: about 1-2% CPU steady on an M-series Mac. Measured on `feat/pedal-setup-tools`: about 18%. `master` was about 33%, so this is not a regression, only a miss against the target.
- Remaining cost is flat per-frame SwiftUI/AttributeGraph overhead at 30 fps around the `Canvas` in `SpectrumGraph.swift`, not the DSP. Fixes already applied: fast state split into `LiveCurves` / `LiveLevels`, `setIfChanged`, cached FFT plans, static `GraphGrid`.
- A 15 Hz curve-publish experiment gave no measurable gain.
- Candidate: draw the curves in an `NSView`/`CALayer` (or `CAMetalLayer`) host instead of a SwiftUI `Canvas`, updated from the audio tick directly; keep SwiftUI for controls only.
- Not measured: long-run memory growth. Steady about 410 MB, mostly the pre-existing history rings.

## Levels UI

- Current panel shows every number and button at one level; no primary answer.
- Sketch: (1) always visible: one level verdict in words and colour plus the 10 octave bars with a one-line tone summary, one primary Set/Re-record button; (2) Details: meters, held peaks, average peak, crest factor, window progress; (3) Settings popover: thresholds, Learn noise, window, export.
- Peak: the held peak versus the reference peak compare different windows. Prefer mean of per-hop peaks over active hops in the same N-second window; needs a per-hop peak in `LogHop`.
- Tablet display mode keeps only level one, large.

## Open

- Verify on the real rig and the Side Screen tablet before deciding any of this.
