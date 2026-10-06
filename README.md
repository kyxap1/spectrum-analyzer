# Spectrum Analyzer

A native macOS app that overlays two live spectrum curves: everything the Mac
plays, and a guitar signal from selected audio interface inputs. It keeps the
last 10 minutes of audio in memory, so you can stop playing, scrub back, and
replay a moment with both curves following the audio.

## Install

```
brew tap kyxap1/spectrum-analyzer
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

## Local data export

Off by default. Turn on **Local data export** in the levels panel and the app
serves JSON (read-only for now) on the loopback interface, reachable only
from the same Mac:

```
curl http://127.0.0.1:47800/levels
```

The document is versioned (`format`, `version`) and carries units and band
centre frequencies. It holds the 31 third-octave band levels for guitar, mix
and their difference over the last N active seconds, the RMS and peak levels,
the reference and its differences when one is set, and the session state. Set
the hidden `export.port` default to change the port.

## Development

Requires Command Line Tools (`swift build`, `swift test`); Xcode is not
needed to build or test. `scripts/test.sh` runs the test suite; on a machine
without Xcode it adds the search path Command Line Tools need to find
`Testing.framework`, otherwise it falls back to plain `swift test`.
