#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-editor-command-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorRegion.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorCommand.swift" \
  "$repo_dir/Tests/EditorCommandChecks.swift" \
  -o "$check_dir/check-editor-commands"
"$check_dir/check-editor-commands"
