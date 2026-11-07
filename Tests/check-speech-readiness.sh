#!/bin/sh
# Default: fake decoders and synthetic RAM PCM. --native additionally uses
# installed local recognizers with synthetic speech; neither path opens a mic.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-speech-readiness)
trap 'rm -rf "$check_dir"' EXIT
swiftc -O -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/LocalSpeechInput.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/WhisperSpeechRuntime.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/WhisperSpeechSession.swift" \
  "$repo_dir/Tests/SpeechReadinessChecks.swift" -o "$check_dir/check-speech-readiness"
if [ "${1:-}" = --native ]; then
  helper=${2:-"$repo_dir/build/Build/Products/Debug/FrameThrower.app/Contents/Helpers/LocalSpeech/FrameThrowerSpeech"}
  "$check_dir/check-speech-readiness" "$helper"
else
  "$check_dir/check-speech-readiness"
fi
