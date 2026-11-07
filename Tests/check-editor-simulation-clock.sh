#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-simulation-clock-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorSimulationClock.swift" \
  "$repo_dir/Tests/EditorSimulationClockChecks.swift" -o "$check_dir/check-editor-simulation-clock"
"$check_dir/check-editor-simulation-clock"
