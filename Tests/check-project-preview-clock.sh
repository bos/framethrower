#!/bin/sh
set -eu
export FRAMETHROWER_VECTOR_PREVIEW=1
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
products=${FRAMETHROWER_PREVIEW_TEST_PRODUCTS:-"$repo_dir/build/Build/Products/Debug"}
dylibs="$products/FrameThrower.app/Contents/MacOS"
check_dir=$(mktemp -d -t framethrower-preview-clock)
trap 'rm -rf "$check_dir"' EXIT
cp "$repo_dir/Tests/ProjectPreviewClockChecks.swift" "$check_dir/ProjectPreviewClockChecks.swift"
taskpolicy -b swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -enable-upcoming-feature ExistentialAny -target "$(uname -m)-apple-macos15.0" \
  -I "$products" "$check_dir/ProjectPreviewClockChecks.swift" "$dylibs/FrameThrower.debug.dylib" \
  -Xlinker -rpath -Xlinker "$dylibs" -o "$check_dir/check-project-preview-clock"
taskpolicy -b "$check_dir/check-project-preview-clock"
