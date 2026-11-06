#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-audio-check)
trap 'rm -rf "$check_dir"' EXIT
# Pure metadata and sentinel text only: no media assets or audio devices.
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorRegion.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/Tests/RecordingAudioChecks.swift" \
  -o "$check_dir/check-recording-audio"
"$check_dir/check-recording-audio"
