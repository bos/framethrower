#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-speech-preparation-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/LocalSpeechInput.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/WhisperSpeechRuntime.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/WhisperSpeechSession.swift" \
  "$repo_dir/Tests/SpeechPreparationChecks.swift" -o "$check_dir/check-speech-preparation"
"$check_dir/check-speech-preparation" "$@"
