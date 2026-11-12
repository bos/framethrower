#!/bin/sh
# Rebuild the macOS icon from the approved transparent master artwork.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
iconset="$scratch/FrameThrower.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$repo_dir/Artwork/FrameThrower.png" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$repo_dir/Artwork/FrameThrower.png" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" --output "$repo_dir/FrameThrower/Resources/FrameThrower.icns"
