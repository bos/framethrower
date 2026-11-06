#!/bin/sh
# Audio gain parameters only; no media fixtures, sources, or codec execution.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-audio-mix-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/ProjectRenderer.swift" "$sources/CursorRecording.swift" "$sources/PIPVideoCompositor.swift" \
  "$repo_dir/Tests/RecordingAudioMixChecks.swift" -o "$check_dir/check-recording-audio-mix"
"$check_dir/check-recording-audio-mix"
