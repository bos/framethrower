#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-capture-settings-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingQuality.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/CaptureRecordingSettings.swift" \
  "$repo_dir/Tests/CaptureRecordingSettingsChecks.swift" \
  -o "$check_dir/check-capture-recording-settings"
"$check_dir/check-capture-recording-settings"
