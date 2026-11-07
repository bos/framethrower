#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-agent-controls-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorActionDescription.swift" \
  "$sources/EditorCommand.swift" "$sources/EditorAgentControls.swift" "$sources/LocalEditPlanner.swift" \
  "$sources/LocalModelRuntime.swift" \
  "$repo_dir/Tests/EditorAgentControlChecks.swift" -o "$check_dir/check-editor-agent-controls"
"$check_dir/check-editor-agent-controls" "$@"
