#!/bin/sh
# Use the verified matching Debug module; never rebuild the whole application
# for a UI assertion. Only vector/offscreen controls are constructed.
set -eu
export FRAMETHROWER_VECTOR_PREVIEW=1
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
products=${1:-"$repo_dir/build/Build/Products/Debug"}
dylibs="$products/FrameThrower.app/Contents/MacOS"
check_dir=$(mktemp -d -t framethrower-inspector-layout-check)
trap 'rm -rf "$check_dir"' EXIT
taskpolicy -b swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" -I "$products" \
  "$repo_dir/Tests/EditorUIProbe.swift" "$repo_dir/Tests/EditorInspectorLayoutChecks.swift" "$dylibs/FrameThrower.debug.dylib" \
  -Xlinker -rpath -Xlinker "$dylibs" -o "$check_dir/check-editor-inspector-layout"
taskpolicy -b "$check_dir/check-editor-inspector-layout"
