#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-director-reference-check)
trap 'rm -rf "$check_dir"' EXIT
set --
for source in "$repo_dir"/FrameThrower/Sources/FrameThrower/*.swift; do
  case "$source" in
    */FrameThrowerApp.swift) ;;
    *) set -- "$@" "$source" ;;
  esac
done
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$@" "$repo_dir/Tests/DirectorReferenceChecks.swift" -o "$check_dir/check-director-references"
"$check_dir/check-director-references"
