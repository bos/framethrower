#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-conflict-interface)
trap 'rm -rf "$check_dir"' EXIT
set --
for source in "$repo_dir"/FrameThrower/Sources/FrameThrower/*.swift; do
  case "$source" in */FrameThrowerApp.swift) ;; *) set -- "$@" "$source" ;; esac
done
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" "$@" "$repo_dir/Tests/ConflictReviewInterfaceChecks.swift" -o "$check_dir/check"
"$check_dir/check" > "$check_dir/result.log" 2>&1 || { cat "$check_dir/result.log"; exit 1; }
cat "$check_dir/result.log"
rg -q '^Conflict review interface checks passed' "$check_dir/result.log"
