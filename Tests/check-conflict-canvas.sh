#!/bin/sh
# Real canvas/vector layers only. No images, player items, source media or codecs.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-conflict-canvas)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorRegion.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/ScribbleGeometry.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorConflictGeometry.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorCanvas.swift" \
  "$repo_dir/Tests/ConflictCanvasChecks.swift" -o "$check_dir/check-conflict-canvas"
"$check_dir/check-conflict-canvas"
