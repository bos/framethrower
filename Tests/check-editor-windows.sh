#!/bin/bash
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-window-check)
trap 'rm -rf "$check_dir"' EXIT
sources=()
for name in CursorRecording CaptureViewModel Models RecordingQuality ScreenMasterWriter RecordingProject RecordingLibrary CameraRecorder ScreenRecorder \
  ProjectRenderer PIPVideoCompositor AreaSelection WindowSelection OAuth \
  DriveUploader SlackAPI KeychainStore; do
  sources+=("$repo_dir/FrameThrower/Sources/FrameThrower/$name.swift")
done
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macos15.0" \
  "${sources[@]}" "$repo_dir/Tests/EditorWindowChecks.swift" \
  -o "$check_dir/check-editor-windows"
"$check_dir/check-editor-windows"
