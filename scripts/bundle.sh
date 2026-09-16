#!/bin/sh
# Builds a release binary and assembles/signs "Spectrum Analyzer.app".
# Usage: scripts/bundle.sh <version>   (e.g. scripts/bundle.sh 0.1.0)
set -e

version="$1"
if [ -z "$version" ]; then
    echo "usage: $0 <version>" >&2
    exit 1
fi

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"

app_name="Spectrum Analyzer.app"
bundle_id="pro.kyxap.SpectrumAnalyzer"

rm -rf "$app_name"

swift build -c release
binary_path="$(swift build -c release --show-bin-path)/SpectrumAnalyzer"

contents="$app_name/Contents"
macos_dir="$contents/MacOS"
resources_dir="$contents/Resources"
mkdir -p "$macos_dir" "$resources_dir"

cp "$binary_path" "$macos_dir/SpectrumAnalyzer"
cp Sources/SpectrumAnalyzer/Advice/prompt.md Sources/SpectrumAnalyzer/Advice/fetch-domains.txt "$resources_dir/"

sed "s/__VERSION__/$version/g" Bundle/Info.plist > "$contents/Info.plist"

# Build AppIcon.icns from the 1024px source PNG.
iconset_dir="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Bundle/AppIcon.png --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Bundle/AppIcon.png --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
cp Bundle/AppIcon.png "$iconset_dir/icon_512x512@2x.png"
iconutil -c icns "$iconset_dir" -o "$resources_dir/AppIcon.icns"
rm -rf "$(dirname "$iconset_dir")"

codesign --force --deep --sign - \
    --identifier "$bundle_id" \
    -r="designated => identifier \"$bundle_id\"" \
    "$app_name"

codesign --verify --deep --strict "$app_name"
codesign -d -r- "$app_name"

echo "Built $app_name ($version)"
