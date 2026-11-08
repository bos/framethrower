#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-preview-tools)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorConflictGeometry.swift" "$sources/EditorRegion.swift" \
  "$sources/RecordingProject.swift" "$sources/ScribbleGeometry.swift" "$sources/EditorCanvas.swift" \
  "$sources/EditorTestPattern.swift" "$repo_dir/Tests/PreviewToolChecks.swift" -o "$check_dir/check-preview-tools"
"$check_dir/check-preview-tools"
