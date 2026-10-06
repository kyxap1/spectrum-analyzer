# Spectrum Analyzer

A native macOS app that overlays two live spectrum curves: everything the Mac
plays, and a guitar signal from selected audio interface inputs. It keeps the
last 10 minutes of audio in memory, so you can stop playing, scrub back, and
replay a moment with both curves following the audio.

## Install

```
brew tap kyxap1/spectrum-analyzer https://github.com/kyxap1/spectrum-analyzer
brew install --cask spectrum-analyzer
```

The app is unsigned (ad-hoc, GitHub-only distribution). The first launch
needs **System Settings → Privacy & Security → Open Anyway**. Grant
Microphone and System Audio Recording access when prompted, or the app tells
you which one is missing and opens the right settings pane.

## Upgrade

```
brew upgrade --cask spectrum-analyzer
```

## Development

Requires Command Line Tools (`swift build`, `swift test`); Xcode is not
needed to build or test. `scripts/test.sh` runs the test suite; on a machine
without Xcode it adds the search path Command Line Tools need to find
`Testing.framework`, otherwise it falls back to plain `swift test`.
