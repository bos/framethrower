#!/bin/sh
# Only text fixtures and metadata. Never inspect, decode or create video.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-multi-import)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
taskpolicy -b swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" "$sources/VideoImport.swift" \
  "$repo_dir/Tests/MultiVideoImportChecks.swift" -o "$check_dir/check-multi-import"
taskpolicy -b "$check_dir/check-multi-import"
