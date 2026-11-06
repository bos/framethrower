#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-preference-check)
trap 'rm -rf "$check_dir"' EXIT
# Compile the actual view model with its dependencies, excluding the app entry
# point. Camera enumeration is permitted; no capture/session is ever started.
set --
for source in "$repo_dir"/FrameThrower/Sources/FrameThrower/*.swift; do
  case "$source" in
    */FrameThrowerApp.swift) ;;
    *) set -- "$@" "$source" ;;
  esac
done
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -target "$(uname -m)-apple-macos15.0" \
  "$@" "$repo_dir/Tests/CapturePreferenceChecks.swift" \
  -o "$check_dir/check-capture-preferences"
"$check_dir/check-capture-preferences"
