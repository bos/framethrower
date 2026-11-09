#!/bin/bash
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-layer-interface-check)
trap 'rm -rf "$check_dir"' EXIT
sources=()
for source in "$repo_dir"/FrameThrower/Sources/FrameThrower/*.swift; do
  case "$source" in */FrameThrowerApp.swift) ;; *) sources+=("$source") ;; esac
done
swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
  -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" "${sources[@]}" \
  "$repo_dir/Tests/ContentLayerInterfaceChecks.swift" -o "$check_dir/check-content-layer-interface"
"$check_dir/check-content-layer-interface"
