#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-recording-names)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/Tests/RecordingNameChecks.swift" \
  -o "$check_dir/check-recording-names"
"$check_dir/check-recording-names"
