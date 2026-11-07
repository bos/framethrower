#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-suspension-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/EditorRegion.swift" \
  "$sources/MediaProcessing.swift" "$sources/RecordingProject.swift" \
  "$sources/ProjectRenderer.swift" "$sources/PIPVideoCompositor.swift" "$sources/CursorRecording.swift" \
  "$sources/EditorPlayback.swift" "$sources/EditorSimulationClock.swift" "$sources/ScreenMasterWriter.swift" "$sources/RecordingQuality.swift" \
  "$sources/RecordingLibrary.swift" "$sources/RecordingLibraryView.swift" \
  "$sources/RecordingTitleEditor.swift" "$sources/VideoExportUI.swift" "$sources/RecorderStyle.swift" \
  "$repo_dir/Tests/MediaSuspensionChecks.swift" -o "$check_dir/check-media-suspension"
"$check_dir/check-media-suspension"
