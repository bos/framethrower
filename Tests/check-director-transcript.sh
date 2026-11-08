#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-director-transcript-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" "$sources/EditorActionDescription.swift" \
  "$sources/EditorCommand.swift" "$sources/EditorMutation.swift" "$sources/EditorPreviewCommand.swift" "$sources/EditorAutomationAPI.swift" "$sources/EditorAgentControls.swift" "$sources//RecordedScene.swift" "$sources//DirectorInspection.swift" "$sources//LocalEditPlanner.swift" \
  "$sources/DirectorTranscript.swift" "$sources/DirectorConversation.swift" \
  "$repo_dir/Tests/DirectorTranscriptChecks.swift" -o "$check_dir/check-director-transcript"
"$check_dir/check-director-transcript"
