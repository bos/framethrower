#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-independent-audio-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
taskpolicy -b swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
  -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorMutation.swift" "$sources/EditorCommand.swift" \
  "$sources/TimelineAnimation.swift" "$sources/EditorActionDescription.swift" "$sources/EditorAnimationEditing.swift" \
  "$repo_dir/Tests/IndependentAudioChecks.swift" -o "$check_dir/check-independent-audio"
taskpolicy -b "$check_dir/check-independent-audio"
