#!/bin/sh
# Link a matching Debug product; this check never builds or launches the app.
set -eu
export FRAMETHROWER_VECTOR_PREVIEW=1
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
products=${1:-"$repo_dir/build/Build/Products/Debug"}
dylibs="$products/FrameThrower.app/Contents/MacOS"
if [ ! -f "$dylibs/FrameThrower.debug.dylib" ]; then
  echo 'Build the matching Debug product first, then pass its Products/Debug directory.' >&2
  exit 1
fi
check_dir=$(mktemp -d -t framethrower-multi-video-window)
trap 'rm -rf "$check_dir"' EXIT
taskpolicy -b swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -enable-upcoming-feature ExistentialAny -target "$(uname -m)-apple-macos15.0" \
  -I "$products" "$repo_dir/Tests/EditorUIProbe.swift" "$repo_dir/Tests/MultiVideoWindowChecks.swift" "$dylibs/FrameThrower.debug.dylib" \
  -Xlinker -rpath -Xlinker "$dylibs" -o "$check_dir/check-multi-video-window"
taskpolicy -b "$check_dir/check-multi-video-window"
