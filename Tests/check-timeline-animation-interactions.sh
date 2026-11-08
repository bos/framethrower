#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-timeline-animation-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$sources/MediaProcessing.swift" "$sources/EditorConflictGeometry.swift" \
  "$sources/TimelineAnimation.swift" "$sources/RecordingTimeline.swift" \
  "$repo_dir/Tests/TimelineAnimationInteractionChecks.swift" -o "$check_dir/check-timeline-animation-interactions"
"$check_dir/check-timeline-animation-interactions"
