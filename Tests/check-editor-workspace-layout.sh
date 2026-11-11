#!/bin/sh
# This test creates only its own invisible accessory WindowGroup. Never builds,
# launches the installed app, enables capture, or targets another process.
set -eu
export FRAMETHROWER_VECTOR_PREVIEW=1
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
products=${1:-"$repo_dir/build/Build/Products/Debug"}
dylibs="$products/FrameThrower.app/Contents/MacOS"
check_dir=$(mktemp -d -t framethrower-workspace-layout)
trap 'rm -rf "$check_dir"' EXIT
taskpolicy -b swiftc -j 1 -parse-as-library -warnings-as-errors -strict-concurrency=complete \
  -enable-upcoming-feature ExistentialAny -target "$(uname -m)-apple-macos15.0" \
  -I "$products" "$repo_dir/Tests/EditorUIProbe.swift" "$repo_dir/Tests/EditorWorkspaceLayoutChecks.swift" "$dylibs/FrameThrower.debug.dylib" \
  -Xlinker -rpath -Xlinker "$dylibs" -o "$check_dir/check-workspace-layout"
taskpolicy -b python3 - "$check_dir/check-workspace-layout" <<'PY'
import subprocess,sys
for args in [[], ['--director']]:
    subprocess.run([sys.argv[1], *args], check=True, timeout=90)
PY
