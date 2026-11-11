#!/bin/sh
# Pure project metadata and hidden native timeline; no media or live capture.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-timeline-track-layout)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
taskpolicy -b swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
  -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorConflictGeometry.swift" "$sources/TimelineAnimation.swift" "$sources/RecordingTimeline.swift" \
  "$repo_dir/Tests/TimelineTrackLayoutChecks.swift" -o "$check_dir/check-timeline-track-layout"
taskpolicy -b "$check_dir/check-timeline-track-layout"
