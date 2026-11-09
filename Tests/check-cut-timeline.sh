#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-cut-timeline-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorConflictGeometry.swift" "$sources/TimelineAnimation.swift" "$sources/RecordingTimeline.swift" \
  "$repo_dir/Tests/CutTimelineChecks.swift" -o "$check_dir/check-cut-timeline"
"$check_dir/check-cut-timeline"
