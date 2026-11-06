#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_dir/Tests/video-processing-disabled.sh"
check_dir=$(mktemp -d -t framethrower-presentation-renderer)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorRegion.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/ProjectRenderer.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/CursorRecording.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/PIPVideoCompositor.swift" \
  "$repo_dir/Tests/PresentationRendererChecks.swift" \
  -o "$check_dir/check-presentation-renderer"
"$check_dir/check-presentation-renderer"
