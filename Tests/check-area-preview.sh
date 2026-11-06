#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-area-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/Models.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/AreaPreviewEditor.swift" \
  "$repo_dir/Tests/AreaPreviewEditorChecks.swift" \
  -o "$check_dir/check-area-preview"
"$check_dir/check-area-preview"
