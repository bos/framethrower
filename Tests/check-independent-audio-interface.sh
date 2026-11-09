#!/bin/sh
# Link the tested Debug app module; never rebuild production or launch the app.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
products="${FRAMETHROWER_AUDIO_TEST_PRODUCTS:-$repo_dir/build/Build/Products/Debug}"
dylibs="$products/FrameThrower.app/Contents/MacOS"
check_dir=$(mktemp -d -t framethrower-audio-interface)
trap 'rm -rf "$check_dir"' EXIT
taskpolicy -b swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -enable-upcoming-feature ExistentialAny -target "$(uname -m)-apple-macos15.0" \
  -I "$products" "$repo_dir/Tests/IndependentAudioInterfaceChecks.swift" "$dylibs/FrameThrower.debug.dylib" \
  -Xlinker -rpath -Xlinker "$dylibs" -o "$check_dir/check-audio-interface"
taskpolicy -b "$check_dir/check-audio-interface"
