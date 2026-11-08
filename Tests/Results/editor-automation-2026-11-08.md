# Shared editor automation verification — 2026-11-08

The installed app shares a domain command boundary between Director and its local
MCP endpoint. A future Siri/App Intents adapter can expose a smaller vocabulary;
it does not constrain the underlying batch, inspection, geometry or history API.
Siri integration itself is not implemented.

Verified capabilities include explicit screen and camera targets, exact anchor
alignment, independent property patches, lane conflict rejection, atomic batches
with one Undo entry, and ordinary document Save/Rename/Undo/Redo. Preview and
selection commands remain transient. Editing introspection is on demand: the
operation catalog is 790 bytes and the exact alignment schema is 2,021 bytes.

Automatic checks passed:

- MCP protocol, private Unix IPC and Python stdio proxy checks, including both
  supported protocol eras, cancellation, limits, peer ownership and cleanup.
- Typed mutation and scoped planner checks, including strict field validation,
  impossible alignment, literal management intent, independent camera/source
  coordinates, atomic failure and a rename plus edits in one Undo operation.
- Preview commands and production automation host checks, including actual history
  before/after inspection, independent copied-document endpoints, late rebuilds,
  deterministic A→B→A completion races and immediate manual Pause while automation
  waits. A canceled playback request cannot resume afterward.
- All seven cached Director integration suites: inspection, Session, conversation,
  history lookup, framing conflicts, panel layout and automation planner.
- Project persistence/identity and recording duplication checks. Legacy identities
  do not rewrite files on read; ordinary Save persists them; copies get new IDs.
- Native recording-title checks, including Command-S completing a title rename
  without submitting a different text field's pending command.

The developer-signed app built successfully and passed the installer's strict
signature checks. Its bundled stdio proxy then completed 14 live local requests:
8-tool discovery, scoped selection with the matching animation highlight and no
seek, animation audition over 1–4 seconds, pause, seek, speed changes, resource
reading and modern discovery after legacy initialization. Project bytes and both
history stacks stayed unchanged. The slowest request in this single local check
was 49.9 ms; this is a smoke check, not a model latency benchmark.

On a disposable metadata-only project, the installed Director using Claude
Sonnet 5.5 also executed these natural instructions successfully:

- “Set the preview playback speed to 2x.” → selected 2×.
- “Play the selected zoom for me.” → auditioned its actual 1–4 second span.
- “Move the playhead to 1.5 seconds.” → paused at 1.50 seconds.

The test entry was removed from Recents and the user's original editor reopened.
Foreground automation was then stopped and its runtime reset.

`MediaProcessing.isSuspended` remains enabled. Checks used project metadata,
synthetic recorded semantics and vector test-pattern previews. Actual recording,
video decoding/encoding/compositing/scaling and source-frame extraction were not
exercised. Exact camera-to-box alignment requires verified source geometry and
returns unavailable rather than using the suspended preview's placeholder size.
