#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-director-diagnostics-check)
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  "$repo_dir/FrameThrower/Sources/FrameThrower/DirectorDiagnostics.swift" \
  "$repo_dir/Tests/DirectorDiagnosticsChecks.swift" \
  -o "$check_dir/check-director-diagnostics"
"$check_dir/check-director-diagnostics"
