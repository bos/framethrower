#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-animation-editing-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" "$sources/EditorActionDescription.swift" \
  "$sources/TimelineAnimation.swift" "$sources/EditorAnimationEditing.swift" \
  "$repo_dir/Tests/EditorAnimationEditingChecks.swift" -o "$check_dir/check-editor-animation-editing"
"$check_dir/check-editor-animation-editing"
