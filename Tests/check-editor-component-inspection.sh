#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-editor-component-inspection)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
taskpolicy -b swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
  -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorConflictGeometry.swift" "$sources/EditorConflictReview.swift" \
  "$sources/EditorActionDescription.swift" "$sources/EditorCommand.swift" "$sources/EditorMutation.swift" \
  "$sources/EditorAgentControls.swift" "$sources/LocalEditPlanner.swift" \
  "$sources/TimelineAnimation.swift" "$sources/EditorAnimationEditing.swift" \
  "$sources/EditorSimulationClock.swift" "$sources/EditorPreviewCommand.swift" \
  "$sources/CursorRecording.swift" "$sources/ProjectRenderer.swift" "$sources/PIPVideoCompositor.swift" \
  "$sources/EditorPlayback.swift" "$sources/RecordedScene.swift" "$sources/DirectorInspection.swift" \
  "$sources/FrameThrowerMCPServer.swift" "$sources/EditorAutomationAPI.swift" "$sources/EditorAutomationHost.swift" \
  "$repo_dir/Tests/EditorComponentInspectionChecks.swift" -o "$check_dir/check-editor-component-inspection"
taskpolicy -b "$check_dir/check-editor-component-inspection"
