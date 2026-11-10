#!/bin/sh
# Actual prerecorded media only. Never creates a capture session/device/stream.
set -eu
case "${1-}" in ""|--with-ui) ;; *) echo "Usage: check-multi-video-media-integration.sh [--with-ui]" >&2; exit 2;; esac
if [ "${FRAMETHROWER_VECTOR_PREVIEW:-}" = 1 ]; then
  printf '%s\n' 'SKIP: prerecorded media integration requires normal recorded playback.' >&2
  exit 77
fi
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d -t framethrower-multi-video-media)
cleanup() {
  result=$?
  if [ "$result" -eq 0 ]; then rm -rf "$check_dir";
  else printf 'Retained failed recorded-media fixture directory: %s\n' "$check_dir" >&2; fi
}
trap cleanup EXIT
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
taskpolicy -b swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
  -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
  -target "$(uname -m)-apple-macos15.0" \
  "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
  "$sources/VideoImport.swift" "$sources/CursorRecording.swift" "$sources/ProjectRenderer.swift" \
  "$sources/PIPVideoCompositor.swift" "$repo_dir/Tests/MultiVideoMediaIntegrationChecks.swift" \
  -o "$check_dir/check-multi-video-media"
taskpolicy -b ffmpeg -nostdin -v error -y -filter_threads 1 -f lavfi -i 'color=c=black:s=96x64:r=12:d=3' \
  -c:v libx264 -threads 1 -pix_fmt yuv420p "$check_dir/primary.mov"
taskpolicy -b ffmpeg -nostdin -v error -y -filter_threads 1 -filter_complex_threads 1 \
  -f lavfi -i 'color=c=red:s=96x64:r=12:d=1' -f lavfi -i 'color=c=yellow:s=96x64:r=12:d=5' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=6' \
  -filter_complex '[0:v][1:v]concat=n=2:v=1:a=0[v]' -map '[v]' -map 2:a \
  -c:v libx264 -threads 1 -pix_fmt yuv420p -c:a aac -b:a 96k -shortest "$check_dir/A.mov"
taskpolicy -b ffmpeg -nostdin -v error -y -filter_threads 1 -f lavfi -i 'color=c=blue:s=96x64:r=12:d=6' \
  -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=6' \
  -c:v libx264 -threads 1 -pix_fmt yuv420p -c:a aac -b:a 96k -shortest "$check_dir/B.mov"
taskpolicy -b ffmpeg -nostdin -v error -y -filter_threads 1 -f lavfi -i 'color=c=0x00ff00:s=96x48:r=12:d=6' \
  -vf 'drawbox=x=48:y=0:w=48:h=24:color=cyan:t=fill,drawbox=x=0:y=24:w=48:h=24:color=magenta:t=fill,drawbox=x=48:y=24:w=48:h=24:color=white:t=fill' \
  -c:v libx264 -threads 1 -pix_fmt yuv420p "$check_dir/portrait-native.mov"
taskpolicy -b ffmpeg -nostdin -v error -y -display_rotation 90 -i "$check_dir/portrait-native.mov" -c copy "$check_dir/portrait.mov"
taskpolicy -b "$check_dir/check-multi-video-media" "$check_dir"

if [ "${1-}" = --with-ui ]; then
  "$repo_dir/Tests/check-multi-video-recorded-window.sh" "$check_dir"
fi
