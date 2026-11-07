#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-spoken-reference-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorActionDescription.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorRegion.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorCommand.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorAgentControls.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/LocalEditPlanner.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/LocalModelRuntime.swift" \
  "$repo_dir/Tests/SpokenReferenceChecks.swift" \
  -o "$check_dir/check-spoken-references"
"$check_dir/check-spoken-references" "$@"
