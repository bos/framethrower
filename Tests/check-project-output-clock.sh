#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-output-clock)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
mkdir "$check_dir/Production"
for name in MediaProcessing EditorRegion RecordingProject EditorSimulationClock CursorRecording ProjectRenderer PIPVideoCompositor EditorPlayback EditorPreviewCommand; do
  cp "$sources/$name.swift" "$check_dir/Production/$name.swift"
done
sources="$check_dir/Production"
cp "$repo_dir/Tests/ProjectOutputClockChecks.swift" "$check_dir/ProjectOutputClockChecks.swift"
swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorSimulationClock.swift" "$sources/CursorRecording.swift" "$sources/ProjectRenderer.swift" \
  "$sources/PIPVideoCompositor.swift" "$sources/EditorPlayback.swift" "$sources/EditorPreviewCommand.swift" \
  "$check_dir/ProjectOutputClockChecks.swift" -o "$check_dir/check-project-output-clock"
FRAMETHROWER_VECTOR_PREVIEW=1 "$check_dir/check-project-output-clock"
