#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-box-connection-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
# One background compiler worker; this test never opens source media.
taskpolicy -b swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorActionDescription.swift" "$sources/EditorCommand.swift" \
  "$sources/TimelineAnimation.swift" "$sources/EditorAnimationEditing.swift" \
  "$repo_dir/Tests/BoxConnectionChecks.swift" -o "$check_dir/check-box-connections"
taskpolicy -b "$check_dir/check-box-connections"
