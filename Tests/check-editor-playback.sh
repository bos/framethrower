#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_dir/Tests/video-processing-disabled.sh" recorded
check_dir=$(mktemp -d -t framethrower-playback-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
mkdir "$check_dir/Production"
for name in MediaProcessing EditorRegion RecordingProject PIPVideoCompositor ProjectRenderer CursorRecording EditorPreviewCommand EditorPlayback EditorSimulationClock; do
  cp "$sources/$name.swift" "$check_dir/Production/$name.swift"
done
cp "$repo_dir/Tests/EditorPlaybackChecks.swift" "$check_dir/EditorPlaybackChecks.swift"
swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macos15.0" \
  "$check_dir/Production/"*.swift "$check_dir/EditorPlaybackChecks.swift" \
  -o "$check_dir/check-editor-playback"
"$check_dir/check-editor-playback" "$@"
