#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-camera-fullscreen-canvas)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
taskpolicy -b swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/ScribbleGeometry.swift" "$sources/EditorConflictGeometry.swift" \
  "$sources/EditorCanvas.swift" "$sources/EditorTestPattern.swift" \
  "$repo_dir/Tests/CameraFullscreenCanvasChecks.swift" -o "$check_dir/check-camera-fullscreen-canvas"
taskpolicy -b "$check_dir/check-camera-fullscreen-canvas"
