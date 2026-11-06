#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-trackpad-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/ProjectRenderer.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/CursorRecording.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/PIPVideoCompositor.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorPlayback.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorCanvas.swift" \
  "$repo_dir/Tests/EditorTrackpadChecks.swift" \
  -o "$check_dir/check-editor-trackpad"
"$check_dir/check-editor-trackpad"
