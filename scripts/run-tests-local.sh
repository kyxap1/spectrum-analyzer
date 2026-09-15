#!/bin/bash
# `swift test` links the test target as an .xctest bundle and hands it to the
# `xctest` launcher, which only Xcode ships -- Command Line Tools don't. That
# leaves `swift test` silently doing nothing (exit 0, no output) on a
# Xcode-less machine. This links the already-built test object files into a
# plain executable that calls Swift Testing's entry point directly, so tests
# run without Xcode. CI (`macos-26` GitHub-hosted runner) has Xcode and keeps
# using plain `swift test`; this script is a local-dev-only path.
#
# ponytail: relies on the underscored `Testing.__swiftPMEntryPoint()`, the
# same call SwiftPM's own generated runner makes. Not public API -- if a
# toolchain update breaks it, drop back to plain `swift test` once Xcode is
# available.
set -euo pipefail
cd "$(dirname "$0")/.."

FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk

swift build --build-tests
BUILD_DIR=$(swift build --show-bin-path)

RUNNER_DIR="$BUILD_DIR/local-test-runner"
mkdir -p "$RUNNER_DIR"
cat > "$RUNNER_DIR/main.swift" <<'EOF'
import Testing
await Testing.__swiftPMEntryPoint() as Never
EOF

swiftc "$RUNNER_DIR/main.swift" \
  -I "$BUILD_DIR/Modules" -I "$FRAMEWORKS" -F "$FRAMEWORKS" \
  -sdk "$SDK" \
  $(find "$BUILD_DIR/SpectrumAnalyzer.build" "$BUILD_DIR/SpectrumAnalyzerTests.build" -name "*.swift.o") \
  -L "$BUILD_DIR" -L "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -framework Testing \
  -o "$RUNNER_DIR/run"

DYLD_FRAMEWORK_PATH="$FRAMEWORKS" "$RUNNER_DIR/run"
