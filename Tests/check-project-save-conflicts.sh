#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-project-save-conflicts)
trap 'rm -rf "$check_dir"' EXIT
# Project JSON and sentinel text only; no media assets or UI.
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/EditorRegion.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/Tests/ProjectSaveConflictChecks.swift" \
  -o "$check_dir/check-project-save-conflicts"
"$check_dir/check-project-save-conflicts"
