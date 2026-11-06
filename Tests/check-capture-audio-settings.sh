#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-audio-settings-check)
trap 'rm -rf "$check_dir"' EXIT
# Pure settings and isolated UserDefaults only: no view model, device discovery,
# capture session, permissions, account access, or camera hardware.
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/Models.swift" \
  "$repo_dir/Tests/CaptureAudioSettingsChecks.swift" \
  -o "$check_dir/check-capture-audio-settings"
"$check_dir/check-capture-audio-settings"
