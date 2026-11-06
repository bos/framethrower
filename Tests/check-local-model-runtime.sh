#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-local-model-runtime-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  "$repo_dir/FrameThrower/Sources/FrameThrower/LocalModelRuntime.swift" \
  "$repo_dir/Tests/LocalModelRuntimeChecks.swift" \
  -o "$check_dir/check-local-model-runtime"
python3 -B "$repo_dir/Tests/LocalModelRuntimeChecks.py" "$check_dir/check-local-model-runtime" "$@"
