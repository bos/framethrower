#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-canvas-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorConflictGeometry.swift" \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorRegion.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/ProjectRenderer.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/CursorRecording.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/PIPVideoCompositor.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorPlayback.swift" "$repo_dir/FrameThrower/Sources/FrameThrower/EditorSimulationClock.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorCanvas.swift" "$repo_dir/FrameThrower/Sources/FrameThrower/EditorTestPattern.swift" \
  "$repo_dir/Tests/EditorCanvasChecks.swift" \
  -o "$check_dir/check-editor-canvas"
"$check_dir/check-editor-canvas"
