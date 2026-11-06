#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-library-check)
trap 'rm -rf "$check_dir"' EXIT
# Synthetic project JSON and file metadata only; no capture models or hardware.
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingLibrary.swift" \
  "$repo_dir/Tests/RecordingLibraryChecks.swift" \
  -o "$check_dir/check-recording-library"
"$check_dir/check-recording-library"
