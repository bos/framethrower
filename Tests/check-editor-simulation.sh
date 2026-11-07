#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-editor-simulation)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorSimulationClock.swift" "$sources/EditorTestPattern.swift" "$sources/EditorConflictGeometry.swift" \
  "$sources/ScribbleGeometry.swift" "$sources/CursorRecording.swift" "$sources/ProjectRenderer.swift" \
  "$sources/PIPVideoCompositor.swift" "$sources/EditorPlayback.swift" "$sources/EditorCanvas.swift" \
  "$repo_dir/Tests/EditorSimulationChecks.swift" -o "$check_dir/check-editor-simulation"
"$check_dir/check-editor-simulation"
