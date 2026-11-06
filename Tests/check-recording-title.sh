#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-recording-title-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingTitleEditor.swift" \
  "$repo_dir/Tests/RecordingTitleChecks.swift" \
  -o "$check_dir/check-recording-title"
"$check_dir/check-recording-title"
