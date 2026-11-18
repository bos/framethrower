#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$repo_dir/build/AppleDirectorPrototype"
mkdir -p "$build_dir"
taskpolicy -b swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
    -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
    -target "$(uname -m)-apple-macos15.0" \
    "$repo_dir/Tests/AppleFoundationModelsChecks.swift" -o "$build_dir/check-basics"
exec taskpolicy -b "$build_dir/check-basics" "${1:-$build_dir/basics}"
