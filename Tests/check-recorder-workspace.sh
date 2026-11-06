#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-workspace-check)
trap 'rm -rf "$check_dir"' EXIT
# Compile real views, but construct only RecorderWorkspace and fake content.
set --
for source in "$repo_dir"/FrameThrower/Sources/FrameThrower/*.swift; do
  case "$source" in
    */FrameThrowerApp.swift) ;;
    *) set -- "$@" "$source" ;;
  esac
done
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macos15.0" \
  "$@" "$repo_dir/Tests/RecorderWorkspaceChecks.swift" \
  -o "$check_dir/check-recorder-workspace"
"$check_dir/check-recorder-workspace"
