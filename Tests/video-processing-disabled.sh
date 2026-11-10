#!/bin/sh
# Recorded-file tests were authorized on 2026-11-10. Live capture, device
# sessions and capture-writer checks remain skipped unless separately approved.
# Recorded-only callers explicitly pass their domain; this cannot open the
# source-fixed MediaProcessing.isCaptureSuspended gate.
if [ "${1-}" != recorded ]; then
  printf '%s\n' 'SKIP: Live video capture and its pipeline checks remain disabled.' >&2
  exit 77
fi
if [ "${FRAMETHROWER_VECTOR_PREVIEW:-}" = 1 ]; then
  printf '%s\n' 'SKIP: Recorded-media checks require normal recorded mode, not vector-preview mode.' >&2
  exit 77
fi
