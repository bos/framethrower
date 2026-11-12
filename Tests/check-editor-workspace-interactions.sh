#!/bin/sh
# Own invisible vector windows and local NSEvents only. No capture or focus.
set -eu
export FRAMETHROWER_VECTOR_PREVIEW=1
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
products=${1:-"$repo_dir/build/Build/Products/Debug"}
dylibs="$products/FrameThrower.app/Contents/MacOS"
check_dir=$(mktemp -d -t framethrower-workspace-interactions)
trap 'rm -rf "$check_dir"' EXIT
taskpolicy -b swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -enable-upcoming-feature ExistentialAny -target "$(uname -m)-apple-macos15.0" -I "$products" \
  "$repo_dir/Tests/EditorUIProbe.swift" "$repo_dir/Tests/EditorWorkspaceInteractionChecks.swift" "$dylibs/FrameThrower.debug.dylib" \
  -Xlinker -rpath -Xlinker "$dylibs" -o "$check_dir/check-workspace-interactions"
taskpolicy -b "$check_dir/check-workspace-interactions"
