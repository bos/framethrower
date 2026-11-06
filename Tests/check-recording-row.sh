#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_dir/Tests/video-processing-disabled.sh"
check_dir=$(mktemp -d -t framethrower-recording-row-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingLibrary.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/ProjectRenderer.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/CursorRecording.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/PIPVideoCompositor.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/VideoExportUI.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingTitleEditor.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingLibraryView.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecorderStyle.swift" \
  "$repo_dir/Tests/EditorMovieFixtures.swift" \
  "$repo_dir/Tests/RecordingRowChecks.swift" \
  -o "$check_dir/check-recording-row"
"$check_dir/check-recording-row"
