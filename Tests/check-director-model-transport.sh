#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-director-transport)
trap 'rm -rf "$check_dir"' EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  "$sources/LocalModelRuntime.swift" "$sources/DirectorModelTransport.swift" \
  "$repo_dir/Tests/DirectorModelTransportChecks.swift" -o "$check_dir/check"
"$check_dir/check"
