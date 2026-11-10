#!/bin/sh
# Offscreen actual-file UI check. Pass the generated media integration directory.
set -eu
if [ "$#" -ne 1 ]; then echo 'Usage: check-multi-video-recorded-window.sh GENERATED_FIXTURE_DIRECTORY' >&2; exit 2; fi
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
products="$repo_dir/build/Build/Products/Debug"
dylibs="$products/FrameThrower.app/Contents/MacOS"
check_dir=$(mktemp -d -t framethrower-recorded-window)
trap 'rm -rf "$check_dir"' EXIT
taskpolicy -b swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete \
 -enable-upcoming-feature ExistentialAny -target "$(uname -m)-apple-macos15.0" \
 -I "$products" "$repo_dir/Tests/MultiVideoRecordedWindowChecks.swift" "$dylibs/FrameThrower.debug.dylib" \
 -Xlinker -rpath -Xlinker "$dylibs" -o "$check_dir/check-recorded-window"
env -u FRAMETHROWER_VECTOR_PREVIEW taskpolicy -b "$check_dir/check-recorded-window" "$1"
