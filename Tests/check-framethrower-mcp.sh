#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-mcp-check)
trap 'rm -rf "$check_dir"' EXIT
python3 "$repo_dir/Tests/FrameThrowerMCPProxyChecks.py"
taskpolicy -b swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$repo_dir/FrameThrower/Sources/FrameThrower/FrameThrowerMCPServer.swift" \
  "$repo_dir/Tests/FrameThrowerMCPChecks.swift" -o "$check_dir/check-mcp"
taskpolicy -b "$check_dir/check-mcp"
