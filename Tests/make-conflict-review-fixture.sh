#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-conflict-fixture)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorActionDescription.swift" "$sources/EditorCommand.swift" "$sources/EditorAgentControls.swift" \
  "$sources/LocalEditPlanner.swift" "$sources/LocalModelRuntime.swift" "$sources/DirectorTranscript.swift" \
  "$sources/DirectorConversation.swift" "$sources/EditorConflictGeometry.swift" "$sources/EditorConflictReview.swift" \
  "$repo_dir/Tests/MakeConflictReviewFixture.swift" -o "$check_dir/make-fixture"
"$check_dir/make-fixture" "$@"
