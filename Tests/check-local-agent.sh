#!/bin/sh
# Optional local text-model checks (Metal by default). No model download, video, or capture.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 -B "$repo_dir/Tests/LocalAgentChecks.py" "$@"
