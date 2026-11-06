#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-inspector-layout-check)
trap 'rm -rf "$check_dir"' EXIT
# Compile all real views, construct only an editor whose media access is blocked.
set --
for source in "$repo_dir"/FrameThrower/Sources/FrameThrower/*.swift; do
  case "$source" in
    */FrameThrowerApp.swift) ;;
    *) set -- "$@" "$source" ;;
  esac
done
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$@" "$repo_dir/Tests/EditorInspectorLayoutChecks.swift" \
  -o "$check_dir/check-editor-inspector-layout"
"$check_dir/check-editor-inspector-layout"
