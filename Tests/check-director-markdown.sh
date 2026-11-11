#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-markdown)
trap 'rm -rf "$check_dir"' EXIT
taskpolicy -b swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" "$repo_dir/FrameThrower/Sources/FrameThrower/DirectorMarkdown.swift" \
  "$repo_dir/Tests/DirectorMarkdownChecks.swift" -o "$check_dir/check-markdown"
taskpolicy -b "$check_dir/check-markdown" "$@"
