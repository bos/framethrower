#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-conflict-review)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
# Values, dispatcher preparation and unit geometry only. No media/model/UI run.
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorActionDescription.swift" "$sources/EditorConflictGeometry.swift" "$sources/EditorConflictReview.swift" \
  "$sources/EditorCommand.swift" "$sources/EditorMutation.swift" "$sources/EditorPreviewCommand.swift" "$sources/EditorAutomationAPI.swift" "$sources/EditorAgentControls.swift" "$sources//RecordedScene.swift" "$sources//DirectorInspection.swift" "$sources//LocalEditPlanner.swift" \
  "$sources/LocalModelRuntime.swift" "$repo_dir/Tests/EditorConflictReviewChecks.swift" \
  -o "$check_dir/check-editor-conflict-review"
"$check_dir/check-editor-conflict-review"
