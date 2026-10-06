#!/bin/sh
# Command Line Tools-only installs (no Xcode) don't put Testing.framework on
# `swift test`'s default search/runtime path, so pass it explicitly there.
set -e

cd "$(dirname "$0")/.."

if [ -d /Applications/Xcode.app ]; then
    exec swift test "$@"
fi

clt_frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test \
    -Xswiftc -F -Xswiftc "$clt_frameworks" \
    -Xlinker -rpath -Xlinker "$clt_frameworks" \
    "$@"
