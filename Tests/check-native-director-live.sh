#!/bin/sh
# Opt-in native account call against an isolated suspended metadata editor.
# --compile-only and --self-test never invoke a provider or load a local model.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=live
case "${1:-}" in
  --compile-only) mode=compile; shift ;;
  --self-test) mode=self; shift ;;
  --run-only) mode=run; shift ;;
  --help|-h)
    cat <<'HELP'
Native Director live fixture (signed-in official CLI, synthetic metadata only).
RUN_NATIVE_DIRECTOR_LIVE=1 Tests/check-native-director-live.sh [--run-only] [options]
  --provider claude|codex|qwen  Default claude; qwen explicitly loads local Metal.
  --model MODEL            Defaults claude-sonnet-5-5, gpt-6.1-sol, or verified local Qwen.
  --cli ABSOLUTE_PATH      Defaults /opt/homebrew/bin/<provider>; Qwen uses its pinned cache CLI.
  --effort on|off         Qwen diagnostic toggle; default off (cloud default medium).
  --capabilities           After camera+recall, check pointer/rename/preview/Undo/Redo.
  --artifacts DIRECTORY    Private raw native events, usage, timing and metadata.
  --compile-only           Compile immutable fixture; no provider call.
  --self-test              Actual private MCP/domain test; no provider call.
Cloud providers use medium effort; Qwen uses off. All use the same edit/recall scenario.
HELP
    exit 0 ;;
esac
if [ "$mode" = live ] || [ "$mode" = run ]; then
  if [ "${RUN_NATIVE_DIRECTOR_LIVE:-}" != 1 ]; then
    echo 'Refusing live account inference. Set RUN_NATIVE_DIRECTOR_LIVE=1 explicitly, or use --self-test/--compile-only.' >&2
    exit 2
  fi
fi
build_dir="$repo_dir/build/NativeDirectorLive"
mkdir -p "$build_dir"
chmod 700 "$build_dir"
binary="$build_dir/check-native-director-live"
sources="$repo_dir/FrameThrower/Sources/FrameThrower"
if [ "$mode" != run ]; then
  # Compile an immutable source graph while other agents resume source work.
  snapshot=$(mktemp -d "$build_dir/source-XXXXXXXX")
  for name in LocalModelRuntime MediaProcessing EditorRegion RecordingProject EditorActionDescription EditorCommand EditorMutation \
      EditorAgentControls LocalEditPlanner EditorConflictGeometry EditorConflictReview TimelineAnimation EditorAnimationEditing EditorSimulationClock EditorPreviewCommand \
      CursorRecording ProjectRenderer PIPVideoCompositor EditorPlayback RecordedScene DirectorInspection \
      FrameThrowerMCPServer EditorAutomationAPI EditorAutomationHost; do
    cp "$sources/$name.swift" "$snapshot/$name.swift"
  done
  cp "$repo_dir/Tests/NativeDirectorLiveChecks.swift" "$snapshot/NativeDirectorLiveChecks.swift"
  sources="$snapshot"
  taskpolicy -b swiftc -whole-module-optimization -Onone -num-threads 1 -parse-as-library \
    -warnings-as-errors -strict-concurrency=complete -enable-upcoming-feature ExistentialAny \
    -target "$(uname -m)-apple-macos15.0" \
    "$sources/LocalModelRuntime.swift" "$sources/MediaProcessing.swift" "$sources/EditorRegion.swift" "$sources/RecordingProject.swift" \
    "$sources/EditorActionDescription.swift" "$sources/EditorCommand.swift" "$sources/EditorMutation.swift" \
    "$sources/EditorAgentControls.swift" "$sources/LocalEditPlanner.swift" \
    "$sources/EditorConflictGeometry.swift" "$sources/EditorConflictReview.swift" \
    "$sources/TimelineAnimation.swift" "$sources/EditorAnimationEditing.swift" \
    "$sources/EditorSimulationClock.swift" "$sources/EditorPreviewCommand.swift" \
    "$sources/CursorRecording.swift" "$sources/ProjectRenderer.swift" "$sources/PIPVideoCompositor.swift" \
    "$sources/EditorPlayback.swift" "$sources/RecordedScene.swift" "$sources/DirectorInspection.swift" \
    "$sources/FrameThrowerMCPServer.swift" "$sources/EditorAutomationAPI.swift" "$sources/EditorAutomationHost.swift" \
    "$snapshot/NativeDirectorLiveChecks.swift" -o "$binary"
  shasum -a 256 "$snapshot"/*.swift \
    "$repo_dir/Tools/director-agent-client.py" "$repo_dir/Tools/framethrower-mcp.py" \
    "$repo_dir/Tools/DirectorAgents/claude.py" "$repo_dir/Tools/DirectorAgents/codex.py" "$repo_dir/Tools/DirectorAgents/qwen.py" "$repo_dir/Tools/DirectorAgents/instructions.py" > "$build_dir/compiled-source-manifest.sha256"
fi
if [ "$mode" = compile ]; then
  echo "Compiled native Director fixture: $binary"
  exit 0
fi
if [ "$mode" = self ]; then
  exec taskpolicy -b "$binary" --repo "$repo_dir" --self-test "$@"
fi
exec taskpolicy -b "$binary" --repo "$repo_dir" "$@"
