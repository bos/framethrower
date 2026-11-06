#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-camera-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/CameraRecorder.swift" \
  "$repo_dir/Tests/CameraRecordingChecks.swift" \
  -o "$check_dir/check-camera-recording"
"$check_dir/check-camera-recording"
