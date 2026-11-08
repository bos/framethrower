#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-assistant-panel-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -whole-module-optimization -Onone -num-threads 2 -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorConflictGeometry.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorConflictReview.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorActionDescription.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/DirectorTranscript.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorRegion.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorCommand.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorMutation.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorPreviewCommand.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorAutomationAPI.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorAgentControls.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordedScene.swift" "$repo_dir/FrameThrower/Sources/FrameThrower/DirectorInspection.swift" "$repo_dir/FrameThrower/Sources/FrameThrower/LocalEditPlanner.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/LocalModelRuntime.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/LocalSpeechInput.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/WhisperSpeechRuntime.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/WhisperSpeechSession.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/DirectorDiagnostics.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/DirectorConversation.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/DirectorModelTransport.swift" "$repo_dir/FrameThrower/Sources/FrameThrower/EditorAssistantPanel.swift" \
  "$repo_dir/Tests/AssistantPanelLayoutChecks.swift" \
  -o "$check_dir/check-assistant-panel"
"$check_dir/check-assistant-panel"
