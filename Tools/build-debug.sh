#!/bin/sh
# Fast, incremental local build. Keep signing enabled for capture-permission
# stability; append CODE_SIGNING_ALLOWED=NO for a compile-only check.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec xcodebuild \
  -project "$repo_dir/FrameThrower/FrameThrower.xcodeproj" \
  -scheme FrameThrower -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$repo_dir/build" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO \
  "$@" build
