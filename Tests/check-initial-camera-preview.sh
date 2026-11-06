#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-initial-camera-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/Models.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/AreaPreviewEditor.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/InitialCameraPreviewGeometry.swift" \
  "$repo_dir/Tests/InitialCameraPreviewChecks.swift" \
  -o "$check_dir/check-initial-camera-preview"
"$check_dir/check-initial-camera-preview"
