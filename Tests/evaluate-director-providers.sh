#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache_dir="$repo_dir/build/DirectorProviderEvaluation/compiled"
mkdir -p "$cache_dir"
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
source_list="$cache_dir/sources.txt"
cat > "$source_list" <<EOF
$sources/MediaProcessing.swift
$sources/EditorRegion.swift
$sources/RecordingProject.swift
$sources/EditorConflictGeometry.swift
$sources/EditorConflictReview.swift
$sources/EditorActionDescription.swift
$sources/DirectorTranscript.swift
$sources/EditorCommand.swift
$sources/EditorAgentControls.swift
$sources/RecordedScene.swift
$sources/DirectorInspection.swift
$sources/LocalEditPlanner.swift
$sources/LocalModelRuntime.swift
$sources/DirectorModelTransport.swift
$sources/LocalSpeechInput.swift
$sources/DirectorDiagnostics.swift
$sources/DirectorConversation.swift
$sources/EditorAssistantPanel.swift
$sources/WhisperSpeechRuntime.swift
$sources/WhisperSpeechSession.swift
$repo_dir/Tests/DirectorProviderEvaluation.swift
EOF
fingerprint=$(while IFS= read -r path; do shasum -a 256 "$path"; done < "$source_list" | shasum -a 256 | cut -d ' ' -f 1)
binary="$cache_dir/evaluate-director-providers-$fingerprint"
if [ ! -x "$binary" ]; then
  # Background priority, one compiler job; never build or launch the app.
  taskpolicy -b swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
    -target "$(uname -m)-apple-macos15.0" @"$source_list" -o "$binary.tmp"
  mv "$binary.tmp" "$binary"
fi
cd "$repo_dir"
export FRAMETHROWER_EVALUATION_BUILD_FINGERPRINT="$fingerprint"
exec taskpolicy -b "$binary" --helper "$repo_dir/Tools/director-cli-client.py" "$@"
