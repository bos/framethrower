#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-pip-opacity)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
taskpolicy -b swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
  -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorMutation.swift" "$sources/EditorCommand.swift" "$sources/EditorActionDescription.swift" \
  "$sources/TimelineAnimation.swift" "$sources/EditorAnimationEditing.swift" \
  "$sources/ScribbleGeometry.swift" "$sources/EditorConflictGeometry.swift" \
  "$sources/EditorCanvas.swift" "$sources/EditorTestPattern.swift" "$sources/RecordingTimeline.swift" \
  "$repo_dir/Tests/PIPOpacityChecks.swift" -o "$check_dir/check-pip-opacity"
taskpolicy -b "$check_dir/check-pip-opacity"
