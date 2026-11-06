#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-source-preview-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  "$repo_dir/FrameThrower/Sources/FrameThrower/MediaProcessing.swift" \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/Models.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/AreaPreviewEditor.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/RecordingProject.swift" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/CaptureSourcePreviews.swift" \
  "$repo_dir/Tests/CaptureSourcePreviewChecks.swift" \
  -o "$check_dir/check-capture-source-previews"
"$check_dir/check-capture-source-previews"
