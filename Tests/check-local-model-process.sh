#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-local-model-process)
trap 'rm -rf "$check_dir"' EXIT
# The binary relaunches only itself as tiny signal-handling child processes.
# No model weights, inference, devices, capture, media or UI are used.
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  "$repo_dir/FrameThrower/Sources/FrameThrower/LocalModelRuntime.swift" \
  "$repo_dir/Tests/LocalModelProcessChecks.swift" \
  -o "$check_dir/check-local-model-process"
"$check_dir/check-local-model-process"
