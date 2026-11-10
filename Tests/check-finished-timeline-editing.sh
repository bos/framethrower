#!/bin/sh
# Exercise the actual compiled editor; fixture changes do not rebuild production.
set -eu
export FRAMETHROWER_VECTOR_PREVIEW=1
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
products=${FRAMETHROWER_FINISHED_TEST_PRODUCTS:-"$repo_dir/build/Build/Products/Debug"}
dylibs="$products/FrameThrower.app/Contents/MacOS"
if [ ! -f "$dylibs/FrameThrower.debug.dylib" ]; then
  echo 'Build the matching Debug app before checking Finished timeline interactions.' >&2
  exit 1
fi
check_dir=$(mktemp -d -t framethrower-finished-timing)
trap 'rm -rf "$check_dir"' EXIT
taskpolicy -b swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -enable-upcoming-feature ExistentialAny -target "$(uname -m)-apple-macos15.0" \
  -I "$products" "$repo_dir/Tests/FinishedTimelineEditingChecks.swift" "$dylibs/FrameThrower.debug.dylib" \
  -Xlinker -rpath -Xlinker "$dylibs" -o "$check_dir/check-finished-timing"
taskpolicy -b "$check_dir/check-finished-timing"
