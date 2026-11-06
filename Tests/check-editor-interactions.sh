#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-interaction-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/ProjectRenderer.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/PIPVideoCompositor.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorPlayback.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorCanvas.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/PIPGeometryViews.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingTimeline.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/ProjectEditorView.swift" \
  "$repo_dir/Tests/EditorInteractionChecks.swift" \
  -o "$check_dir/check-editor-interactions"
"$check_dir/check-editor-interactions"
