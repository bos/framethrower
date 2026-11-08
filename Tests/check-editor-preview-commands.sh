#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-editor-preview-commands)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
  -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorSimulationClock.swift" "$sources/EditorPreviewCommand.swift" \
  "$sources/CursorRecording.swift" "$sources/ProjectRenderer.swift" "$sources/PIPVideoCompositor.swift" \
  "$sources/EditorPlayback.swift" "$repo_dir/Tests/EditorPreviewCommandChecks.swift" \
  -o "$check_dir/check-editor-preview-commands"
"$check_dir/check-editor-preview-commands"
