# Native Director session verification — November 8, 2026

Director now uses the official Claude/Codex command-line runtimes and pinned
Qwen Code 0.27.0 with native resumable conversations and scoped MCP tools.
Production no longer builds or trims a model conversation or asks a model to
select one JSON function per call. Native runtimes own history, tool loops,
caching and compaction. Editor mutations still use ordinary validation,
revision checks, visual conflict review, durable saves and Undo/Redo.

## Real cloud runtime checks

Both final batteries used a disposable 14-second metadata-only editor, a private
Unix MCP socket and the production automation host. No GUI was opened, no user
project changed, and no video operation ran. Each provider retained the same
native conversation across all seven natural-language turns.

| Check | Sonnet 5.5 | Requested Codex GPT-6.1 Sol, medium |
|---|---:|---:|
| Camera fullscreen, 9–11 s |12.55s |21.17s |
| Recall request without edits |6.05s |5.43s |
| Double pointer size, 1.5→3 |9.56s |14.81s |
| Rename recording |7.04s |12.60s |
| Review at 2×, no document/history change |8.92s |13.27s |
| Undo rename, preserve camera/pointer |7.30s |13.79s |
| Redo rename |7.62s |11.07s |
| Total |59.04s |92.14s |

Both batteries passed actual state, durable save, ordinary Undo/Redo, unrelated
metadata preservation and native-session continuity assertions. These are single
CLI-inclusive observations, not comparative benchmark estimates. Tool-call counts
and provider cache counter semantics differ. Native cache reads were reported
across turns; raw results and metrics are retained. Codex does not expose its
resolved model ID in this stream, so its row identifies the requested model.

Earlier Codex attempts exposed real integration errors that mock CLI tests
missed: disabling its native tool runtime removed editor controls; automatic MCP
approval then blocked writes despite successful inspection. The fixes enable the
official standalone tool runtime and approve only the eight named FrameThrower
tools on its document-scoped server. OS, shell, web and other app tools remain
disabled. Original failures and their regression tests are retained.

One Sonnet reply incorrectly claimed its accepted rename was not saved. The host
now explicitly returns project_metadata_saved=true after successful document
operations; a direct backend regression verifies that receipt. That final receipt
addition was not followed by another model battery.

Final cloud evidence lives under build/NativeDirectorLive/:

- sonnet-final-capabilities-2026-11-08
- codex-final-capabilities-2026-11-08

Earlier camera-only smoke checks and both initial Codex failures remain there.

## Local Qwen observations

The pinned Qwen Code runtime sends the exact shared system instructions, literal
user messages, actual tool results and native resumed history. Official-CLI tests
against synthetic HTTP/MCP peers verify both thinking-off and thinking-on wire
settings. The real local server used Metal, unchanged Qwen3-8B Q4_K_M weights,
32,768-token context and f16 KV storage. It stayed warm between actual turns.

Observed server resident memory settled near 9.2 GiB (about 9.9 decimal GB), with no
substantial growth in later runs. The first test was cancelled at a pressure
change; Bryan then explicitly approved roughly 9 GB, and subsequent runs completed.
The final runs showed no swapout growth during their observation windows. No
video-driver failure was observed; this does not establish a driver diagnosis.

Local editing reliability did NOT pass the strict fixture oracle. Earlier runs
also exposed a headless fixture bug—navigation reported success without updating
its observable inspector—which was fixed and self-tested before later runs.
With corrected navigation, reasoning enabled and explicit catalog subjects, the
last run correctly expanded the PIP from 9–11 s and left main framing unchanged, but
also renamed the recording without being asked. It took 86.0 s. Recall and the
remaining capability turns were therefore not sent. This was not reported as a
successful complete edit or a clean reasoning-mode comparison.

That run exposed an ambiguous API argument: apply_edits.title could be mistaken
for a history label. The public field is now recording_title, with an explicit
recording-rename description; name labels only the Undo step. Old title rejects
atomically. Backend regressions verify this distinction. No local-model retry
followed that final API clarification, so local reliability remains unverified.
No model substitution or utterance-specific routing was introduced.

Local evidence directories include qwen-smoke-approved-9gb-2026-11-08,
qwen-shared-guidance-2026-11-08, qwen-reasoning-on-navigation-2026-11-08 and
qwen-final-api-2026-11-08. All fixture-owned model processes and keys were removed;
retained diagnostics were checked for bearer-token leaks.

## Automatic checks

- Claude adapter: 10 offline tests; Codex adapter: 17; Qwen adapter: 12.
- Broker: 7 tests, including early identity persistence, no silent new-session
  fallback, recording/provider isolation, serialization and preserved evidence
  when saving a binding fails.
- MCP proxy: 6 tests, including recording-scoped tools/resources, cancellation,
  framing, EOF behavior and private socket validation.
- Official Qwen CLI against synthetic HTTP/MCP peers: actual tool execution,
  exact eight-tool catalog, transcript persistence and native resume.
- Warm local-server lease tests: shared preparation, retained endpoint after
  release, cancellation, dead-process failure and explicit recovery.
- Nine shared Director integration suites, including native turns without app
  history reconstruction, long literal input, manual changes, natural replies,
  recording identity isolation and the ordinary conflict buttons. Native change
  notifications replay exact collection deltas, including removals and ordering,
  instead of repeating unchanged keyframes; no history or facts are truncated.
- Native conflict tests plus unchanged existing automation compatibility tests:
  typed/legacy overlaps, exact frozen review state, Keep/Replace, stale revisions,
  failed-save retry, one durable Undo/Redo and independent camera/audio/pointer.
- Component inspection: exact source-time values without seeking or saving;
  a 160-screen/160-camera-keyframe fixture returned 437–612 byte component results
  versus 89,043 bytes for full state. Catalog subject descriptions add 580 bytes.
- PIP fullscreen model and vector interaction checks: exact canvas fill, shared
  easing, aspect-fill cropping without stretching, restored original layout,
  continuous resizing and no invisible drag edits.

`MediaProcessing.isSuspended` remains enabled. Actual capture, decoding,
encoding, compositing, scaling and original-footage playback remain untested
under the driver interlock. The final developer-signed build passed strict
signature verification; all seven bundled native Python resources match source
and parse successfully, with no bytecode cache bundled. After Bryan quit the
previous app, the verified update was installed at
`/Users/bosullivan/Applications/FrameThrower.app` and left closed. No foreground
launch or computer-use interaction was performed.
