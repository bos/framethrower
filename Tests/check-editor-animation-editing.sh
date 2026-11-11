#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-animation-editing-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
mkdir "$check_dir/Production"
for name in EditorRegion RecordingProject EditorActionDescription TimelineAnimation EditorAnimationEditing; do
  cp "$sources/$name.swift" "$check_dir/Production/$name.swift"
done
sources="$check_dir/Production"
cp "$repo_dir/Tests/EditorAnimationEditingChecks.swift" "$check_dir/EditorAnimationEditingChecks.swift"
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" "$sources/EditorActionDescription.swift" \
  "$sources/TimelineAnimation.swift" "$sources/EditorAnimationEditing.swift" \
  "$check_dir/EditorAnimationEditingChecks.swift" -o "$check_dir/check-editor-animation-editing"
"$check_dir/check-editor-animation-editing"
