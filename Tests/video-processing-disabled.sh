#!/bin/sh
# Temporary source-fixed interlock: do not start encoders, decoders, capture,
# compositors, or media fixtures while the video-scaling driver is unstable.
# Exit 77 marks a skipped check rather than a successful media verification.
printf '%s\n' 'SKIP: Video processing tests are temporarily disabled because the video-scaling driver can hang or crash this Mac.' >&2
exit 77
