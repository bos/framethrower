#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-recorded-policy)
trap 'rm -rf "$check_dir"' EXIT
python3 "$repo_dir/Tests/LiveCapturePolicyChecks.py"
taskpolicy -b swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/Tests/RecordedVideoPolicyChecks.swift" -o "$check_dir/check-policy"
env -u FRAMETHROWER_VECTOR_PREVIEW "$check_dir/check-policy"
FRAMETHROWER_VECTOR_PREVIEW=1 "$check_dir/check-policy" --vector

taskpolicy -b swiftc -DDEBUG -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/Tests/RecordedVideoPolicyChecks.swift" -o "$check_dir/check-debug-policy"
env -u FRAMETHROWER_VECTOR_PREVIEW "$check_dir/check-debug-policy"
FRAMETHROWER_VECTOR_PREVIEW=1 "$check_dir/check-debug-policy" --vector
