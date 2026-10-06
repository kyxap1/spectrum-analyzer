#!/bin/sh
# Sets Casks/spectrum-analyzer.rb's version and sha256 for a release.
# Usage: scripts/bump-cask.sh <version> <sha256>
set -e

version="$1"
sha256="$2"
if [ -z "$version" ] || [ -z "$sha256" ]; then
    echo "usage: $0 <version> <sha256>" >&2
    exit 1
fi

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cask="$root_dir/Casks/spectrum-analyzer.rb"

# -i.bak (suffix attached, no space) is the one -i spelling both BSD sed
# (macOS/CI) and GNU sed (shadowing it on some dev machines) agree on.
sed -i.bak "s/^  version \".*\"/  version \"$version\"/" "$cask"
sed -i.bak "s/^  sha256 \".*\"/  sha256 \"$sha256\"/" "$cask"
rm -f "$cask.bak"
