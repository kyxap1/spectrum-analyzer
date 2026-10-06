#!/bin/sh
# Sets a cask's version and sha256 for a release. The cask lives in the
# kyxap1/homebrew-spectrum-analyzer tap.
# Usage: scripts/bump-cask.sh <cask.rb> <version> <sha256>
set -e

cask="$1"
version="$2"
sha256="$3"
if [ -z "$cask" ] || [ -z "$version" ] || [ -z "$sha256" ]; then
    echo "usage: $0 <cask.rb> <version> <sha256>" >&2
    exit 1
fi

# -i.bak (suffix attached, no space) is the one -i spelling both BSD sed
# (macOS/CI) and GNU sed (shadowing it on some dev machines) agree on.
sed -i.bak "s/^  version \".*\"/  version \"$version\"/" "$cask"
sed -i.bak "s/^  sha256 \".*\"/  sha256 \"$sha256\"/" "$cask"
rm -f "$cask.bak"
