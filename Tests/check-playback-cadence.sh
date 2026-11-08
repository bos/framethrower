#!/bin/sh
set -eu
archive=${1:?Pass a read-only Director conversation archive JSON path}
project=${2:-}
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-cadence)
trap 'rm -rf "$check_dir"' EXIT
set --
sources=${CADENCE_SOURCE_DIR:-"$repo_dir/FrameThrower/Sources/FrameThrower"}
for source in "$sources"/*.swift; do
  case "$source" in */FrameThrowerApp.swift) ;; *) set -- "$@" "$source" ;; esac
done
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" "$@" "$repo_dir/Tests/PlaybackCadenceDiagnostics.swift" -o "$check_dir/check"
if [ -n "$project" ]; then
  "$check_dir/check" "$archive" "$project"
else
  "$check_dir/check" "$archive"
fi
