#!/bin/sh
# Plans, vector layers and AV gain parameters only. Never opens video or audio.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-multi-video-rendering)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
taskpolicy -b swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
  -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorSimulationClock.swift" "$sources/EditorPreviewCommand.swift" \
  "$sources/EditorTestPattern.swift" "$sources/EditorConflictGeometry.swift" \
  "$sources/ScribbleGeometry.swift" "$sources/CursorRecording.swift" "$sources/ProjectRenderer.swift" \
  "$sources/PIPVideoCompositor.swift" "$sources/EditorPlayback.swift" "$sources/EditorCanvas.swift" \
  "$repo_dir/Tests/MultiVideoRenderingChecks.swift" -o "$check_dir/check-multi-video-rendering"
taskpolicy -b "$check_dir/check-multi-video-rendering"
