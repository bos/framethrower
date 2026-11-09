#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-time-map-check)
trap 'rm -rf "$check_dir"' EXIT
taskpolicy -b swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
  -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorRegion.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/Tests/RecordingTimeMapChecks.swift" -o "$check_dir/check-recording-time-map"
taskpolicy -b "$check_dir/check-recording-time-map"
