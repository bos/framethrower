#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-local-model-lease)
trap 'rm -rf "$check_dir"' EXIT
# Only self-hosted signal-handling child processes; no HTTP/model/GPU/media.
taskpolicy -b swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  "$repo_dir/FrameThrower/Sources/FrameThrower/LocalModelRuntime.swift" \
  "$repo_dir/Tests/LocalModelLeaseChecks.swift" -o "$check_dir/check"
taskpolicy -b "$check_dir/check"
