#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-action-descriptions)
trap 'rm -rf "$check_dir"' EXIT
# Pure framing/reference metadata; no media, model, device or UI operations.
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorRegion.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorActionDescription.swift" \
  "$repo_dir/Tests/EditorActionDescriptionChecks.swift" \
  -o "$check_dir/check-editor-action-descriptions"
"$check_dir/check-editor-action-descriptions"
