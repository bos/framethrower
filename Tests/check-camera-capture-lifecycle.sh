#!/bin/sh
# Hardware-free lifecycle/generation checks; never enables the real Debug opt-in.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-camera-lifecycle)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
for mode in debug release; do
  if [ "$mode" = debug ]; then set -- -D DEBUG; else set --; fi
  taskpolicy -b swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
    -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
    -target "$(uname -m)-apple-macos15.0" "$@" \
    "$sources/MediaProcessing.swift" "$sources/RecordingQuality.swift" "$sources/CameraRecorder.swift" \
    "$repo_dir/Tests/CameraCaptureLifecycleChecks.swift" -o "$check_dir/check-camera-lifecycle-$mode"
  taskpolicy -b "$check_dir/check-camera-lifecycle-$mode"
done
