#!/bin/sh
# Synthetic PCM only. Never opens the microphone or constructs a media codec.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-whisper-speech-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -O -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/LocalSpeechInput.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/WhisperSpeechRuntime.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/WhisperSpeechSession.swift" \
  "$repo_dir/Tests/WhisperSpeechChecks.swift" -o "$check_dir/check-whisper-speech"
if [ "${1:-}" = --native ]; then
  "$repo_dir/Tools/build-local-speech-runtime.sh" "$repo_dir/build/LocalSpeech"
  "$check_dir/check-whisper-speech" "${2:-$repo_dir/build/LocalSpeech/FrameThrowerSpeech}"
else
  "$check_dir/check-whisper-speech"
fi
