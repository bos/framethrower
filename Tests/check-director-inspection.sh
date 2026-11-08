#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-director-inspection-check)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
  -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/RecordedScene.swift" \
  "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/EditorCommand.swift" "$sources/DirectorInspection.swift" \
  "$repo_dir/Tests/DirectorInspectionChecks.swift" -o "$check_dir/check-director-inspection"
"$check_dir/check-director-inspection"
