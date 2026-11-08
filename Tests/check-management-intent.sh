#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-management-intent-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorConflictGeometry.swift" \
  "$sources/EditorConflictReview.swift" \
  "$sources/EditorActionDescription.swift" \
  "$sources/DirectorTranscript.swift" \
  "$sources/EditorCommand.swift" "$sources/EditorAgentControls.swift" "$sources/LocalEditPlanner.swift" \
  "$sources/LocalModelRuntime.swift" "$sources/LocalSpeechInput.swift" "$sources/DirectorDiagnostics.swift" "$sources/DirectorConversation.swift" "$sources/DirectorModelTransport.swift" "$sources/EditorAssistantPanel.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/WhisperSpeechRuntime.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/WhisperSpeechSession.swift" \
  "$repo_dir/Tests/ManagementIntentChecks.swift" -o "$check_dir/check-management-intent"
"$check_dir/check-management-intent" "$@"
