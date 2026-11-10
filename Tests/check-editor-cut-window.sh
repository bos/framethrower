#!/bin/sh
# Use the compiled Debug dylib instead of compiling the complete app again.
set -eu
export FRAMETHROWER_VECTOR_PREVIEW=1
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
products="$repo_dir/build/Build/Products/Debug"
dylibs="$products/FrameThrower.app/Contents/MacOS"
check_dir=$(mktemp -d -t framethrower-cut-window)
trap 'rm -rf "$check_dir"' EXIT
taskpolicy -b swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -enable-upcoming-feature ExistentialAny -target "$(uname -m)-apple-macos15.0" \
  -I "$products" "$repo_dir/Tests/EditorCutWindowChecks.swift" "$dylibs/FrameThrower.debug.dylib" \
  -Xlinker -rpath -Xlinker "$dylibs" -o "$check_dir/check-cut-window"
taskpolicy -b "$check_dir/check-cut-window"
