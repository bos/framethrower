#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-pointer-recovery)
trap 'rm -rf "$check_dir"' EXIT
# Only JSON metadata and temporary files; the movie branch rejects at its interlock.
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorRegion.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/CursorRecording.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MissingMediaRecovery.swift" \
  "$repo_dir/Tests/PointerRecoveryChecks.swift" \
  -o "$check_dir/check-pointer-recovery"
"$check_dir/check-pointer-recovery"
