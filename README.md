# FrameThrower

A native macOS screen recorder built with SwiftUI and ScreenCaptureKit. Record a
window, a display, or an area selected by dragging, then optionally upload the
recording to Google Drive or a Slack person/channel.

## Temporary media suspension

Video processing is currently disabled in source at the user's request because
of repeated kernel video-scaler hangs. Capture, camera sessions, live source
previews, video playback, thumbnails, composition, and export are blocked. The
editor plays edits over a drawn vector test pattern using a separate clock.
This exercises zooms, pans, PIP, scrubbing, and trim timing without opening
footage or creating a media player. Timeline edits, naming, project saving,
and Undo/Redo remain usable. Existing recordings are untouched.

`MediaProcessing.isSuspended` is fixed to `true`, with no preference or launch
argument override. Media test scripts stop before compilation with `SKIP` and
exit status 77; fixture creation also checks the interlock. Do not re-enable
those paths on this machine without explicit approval. The feature descriptions
below document the implementation behind this temporary interlock.

## Local speech recognition

English dictation uses the bundled Metal Whisper runtime when the verified
large-v3-turbo Q5_0 model is installed. Otherwise it uses Apple's on-device
dictation. Recognition stays on this Mac. Whisper returns the final utterance
when you press Stop; it does not display tentative words while recording.
Dictation is limited to two minutes per utterance.

The app build bundles and signs a helper plus its tensor libraries. The first
build needs CMake and internet access to fetch the pinned official source;
subsequent builds reuse the native runtime cache. The runtime source commit and
archive checksum are pinned in `Tools/build-local-speech-runtime.sh`. End users
receive compiled binaries and never need a compiler or Homebrew.

Install already downloaded weights with `python3 Tools/local_speech_model.py`,
or explicitly download the official 547 MiB model with
`python3 Tools/local_speech_model.py --download`. Both paths verify the exact
size and SHA-256 before atomic installation in
`~/Library/Caches/FrameThrower/LocalSpeech/models/`. Weights are never committed.
An existing verified ASR benchmark cache is also imported during preparation.
An interrupted or invalid installation cannot replace a valid model.

Run `Tests/check-whisper-speech.sh` for asset/protocol/cancellation checks.
`Tests/check-whisper-speech.sh --native` additionally synthesizes 18 utterances
in memory and tests the actual Metal helper through `LocalSpeechInput.finish`.
Neither check opens a microphone, plays audio, writes an audio file, or runs a
video operation. These synthetic checks measure command fidelity, not human
microphone accuracy.
`Tests/check-local-speech-bundle.sh` checks the already-built app's outer and
nested signatures, bundled license, library symlinks, and portable loader paths
without launching it.

## Requirements

- macOS 15 or later to run the app.
- Xcode 26 or later with the macOS 26 SDK or later to build it. Speech APIs
  require this SDK; the deployment target remains macOS 15.
- CMake (`brew install cmake`) to build the bundled optional Metal speech
  runtime. End users receive compiled binaries and need no compiler.
- XcodeGen (`brew install xcodegen`) to regenerate the checked-in Xcode project.

## Build and run

From the repository root:

```bash
xcodegen generate --spec FrameThrower/project.yml
open FrameThrower/FrameThrower.xcodeproj
```

Select the **FrameThrower** scheme and **My Mac** destination, choose your signing
team under Signing & Capabilities if needed, and run. The project currently uses
the original developer's team. Its configuration is in `FrameThrower/project.yml`;
update that file when changing project settings so regeneration preserves them.

To build and install from the command line:

```bash
xcodebuild \
  -project FrameThrower/FrameThrower.xcodeproj \
  -scheme FrameThrower \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  build
python3 Tools/install-debug.py
```

Quit FrameThrower yourself before installing. The guarded installer refuses a
running app, checks the build and installed bundle/signing team, stages a copy,
verifies its signature, and checks processes again immediately before atomic
replacement. It retains the prior build at the backup path reported in its JSON
result and rolls back a failed replacement. It never quits, kills, or launches
FrameThrower. Open `~/Applications/FrameThrower.app` yourself when ready.
`build/` contains disposable build output. Pass an alternate signed build path
as the installer's argument when needed. Run
`python3 Tests/DebugInstallerChecks.py` for temporary-fixture installer tests;
these never touch the installed app.

For a compile-only check without a signing identity, append
`CODE_SIGNING_ALLOWED=NO` to the build command. Use a consistently signed build
for normal use so macOS can recognize its recording permissions.

## Recording

First launch opens in **Display** mode. Later launches remember the last mode and
available source selection. A window that has closed requires choosing a new one.

1. Grant FrameThrower access in **System Settings > Privacy & Security > Screen &
   System Audio Recording** (called **Screen Recording** on some macOS versions),
   then quit and relaunch the app. Capture controls stay disabled without access.
2. Choose **Window**, **Display**, or **Area**. Use **Choose…** to select a window
   on screen or drag an area; the window picker also lists available windows.
   Area mode shows the full display with the recording region highlighted. Drag
   outside the region to draw a new one, drag inside to move it, or drag a corner
   to resize it. Arrow keys move the focused region by one point (Shift: ten).
   **Choose…** still opens the full-screen selector for precise adjustments.
   Display and Area previews update about twice a second with existing recording
   access. Updates pause while the recorder is hidden, fully covered, minimized,
   or recording. Window previews load when requested or when positioning a camera.
   Permission requests do not run automatically on launch.
3. Choose a microphone or **Off**, and enable **System audio** as needed. Microphone,
   system audio, and camera selection share one row. Microphone capture needs its
   own macOS permission.
4. Optionally choose a **Camera**. Its live layout appears inline automatically
   with the selected source behind it, so you can set its initial PIP position and
   size against the recording content. Area backgrounds show only the selected crop.
   Turning the camera on enables the microphone, using your remembered device or
   the Mac's default. You can turn the microphone off; switching cameras keeps
   that choice until you turn the camera off and on again. Camera
   access is requested only when you select a camera. Choose **Off** to stop it.
5. Click **Record**, or use its arrow for a 5- or 10-second countdown.
   Click **Stop recording** to finish. Command-R starts/stops recording.
   A separate editor window opens when capture finishes; double-click its row to reopen
   it. The recorder stays usable, and each project's editor has its own undo history.

The recordings list shows projects in Movies and projects opened from other
folders, newest first. Scroll the list for older recordings. Click a name to
rename it; double-click a row to open its editor. The editor's header and window
title use the same saved name, and its header also supports inline renaming.
Return saves a name; Escape or clicking outside cancels. The X inside the name
field clears its draft, and the row removal button stays hidden during renaming.
Renaming supports undo/redo and keeps the original media filenames.

Record and Stop stay above the list in the side panel. The main capture preview
keeps its space as recordings are added, and shows the live camera directly over
the selected recording region. Drag the camera there to position it.

Each row's share button targets that recording. **×** removes a row from the list
and keeps the project and media files on disk. **Undo removal** below the list (or Command-Z after
removing a row) restores it, including after restarting the app. Opening a removed
project explicitly also restores it. The app never deletes recordings because of
their age; use Finder when you want to delete files permanently.

Choose **High quality** for ProRes 422 LT video and uncompressed 48 kHz PCM
audio, or **Smaller files** for H.264 capture. The choice is remembered. High-quality
capture shows an approximate storage rate; camera and audio add to that estimate.
New recordings render at 60 fps through preview and export, including cursor and
camera animation over static screen frames. Existing projects retain their prior
30 fps render cadence. ProRes LT is a high-quality codec, not mathematically lossless video.

Screen originals are saved in `~/Movies` as
`Screencast-<UTC timestamp>-<unique suffix>.mov` (high quality) or `.mp4` (smaller files).
Camera video is saved separately beside the screen original as `.camera.mov`. New recordings also save
mouse motion and clicks in an immutable `.cursor.json` sidecar. A `.framethrower`
project stores edits and undo history. Keep these files together. The legacy
filename prefix is retained for compatibility with the upload helper. Local
recording and editing do not require connecting Google Drive or Slack.

## Editing

Use the single timeline to scrub and drag its blue handles to trim. Arrow keys
seek by 0.1 seconds; Shift-arrow seeks by one second. Trimming keeps every original
frame available. Right-click the timeline for **Reset trim**. Space starts or
pauses playback.

Pinch over the timeline to zoom its time scale around your fingers; two-finger
scrolling navigates time. This changes only the timeline view, not the recording.
The playhead and trim handles occupy the top rail. Persistent **Screen**, **Camera**,
and **Pointer** lanes show the recording's animations below it. Screen combines
zoom and pan into one viewport movement. Camera has independent PIP movements.
Pointer currently shows whole-recording style settings and recorded click ticks;
it does not create timed pointer-style changes. Missing camera or pointer tracks
show **Not recorded**.

Click an animation to select it and inspect its destination. Drag its body to
move the entire movement, or its start/end grips to change its timing. Pull an
instant change's start grip left to turn it into a smooth movement. The inner
handles adjust acceleration and deceleration; tooltips report timing. Short,
crowded marks show a count badge with a chooser listing their names and times;
pinching into the timeline separates their controls. The selected animation's **×** or Delete removes only that lane's
change, preserving other components and reference boxes.

Same-lane movements stop at their neighbors with a sticky contact while they
intersect. Moving a whole span completely past its neighbor reorders it and clears
the contact warning. Resizing continues to stop at the adjacent movement. Hold Option
while dragging to push whole neighboring movements, preserving their durations
and ramps; the chain stops at the recording boundary. Different lanes can overlap.
Each gesture is one Undo step. Escape restores the whole gesture. Click empty
lane space to save pending adjustments and deselect without moving the playhead.
Mouse clicks leave no full-timeline focus border; keyboard navigation uses a
small cue beneath the playhead.

The fixed-height inspector has **Zoom**, **Pointer**, and (when present) **Camera**, plus **Canvas**
and **Audio** controls. Pinch over the preview to zoom the picture; two-finger scrolling pans
it, including trackpad momentum. Double-click also zooms at that position, and
mouse dragging pans a zoomed view. Repeated adjustments at the same source time
refine one combined draft. Selecting an existing edit revises it in place. Leaving
that time, playing, exporting, or closing saves one undo step. Escape discards the
draft; Undo followed by Redo can recover it.

**Jump** applies framing instantly. **Smooth** accelerates, moves at constant
speed, then decelerates to a stop at the edit's time. Duration controls total
movement time as an editable number of seconds. Transition controls appear only
for a selected edit. Drag the visual strip's left and right boundary bars to adjust
acceleration and deceleration; their tooltips report the ramp times. Ramps cannot
overlap. Right-click the timeline for **Hold current framing** when you need an
unchanged view before a later movement.
The strip and timeline spans show the effective transition,
shortened when the previous edit leaves less time available. Screen and camera
use the same motion curve, with separate settings for each component of an edit.
Deceleration slows earlier and has a flatter settling tail while retaining the
chosen ramp duration and arrival time.
**Suggest zooms** offers Subtle and Focused suggestions from recorded click groups,
with steady holds and returns to the wider context. Suggestions are ordinary
editable changes and applying them is one undo step.

For new recordings, **Pointer** changes pointer size, smoothing, visibility, and
click highlights after capture. Smoothing keeps click targets exact and preserves
held-button paths when dragging or drawing. Older recordings retain their baked-in
cursor; screen zooming and panning still work on them. Pointer tracking covers
Window, Display, and Area capture, including moving windows and multiple displays.
If pointer capture cannot start, recording retains the ordinary baked-in cursor.

Camera edits create timed camera changes. Move the PIP by dragging or
using a corner button; resize with **Size** or any of its four corner handles. **Original**
preserves the camera aspect, **Rectangle** allows independent width and height,
and **Square** and **Circle** crop without stretching. **Framing…** lets you move
the crop within the full camera image and zoom the camera source independently
of the PIP window size. Main-view and camera movement share transition timing,
easing, and viewport bounds. Shape, framing, zoom, size, position, and visibility
can all change over time. Dragging updates the PIP picture live and joins the shared draft at that time. **Jump** changes placement instantly; **Smooth** eases
position, size, aspect, and framing toward the change. Shape and visibility switch
at the change's time.

Every edit, including trim, supports Command-Z and Shift-Command-Z. Moving or
removing an edit is one undo step; framing adjustments at one time share a step. Edits and history save automatically and survive reopening through
**Open…**. Pending timed edits are also journaled beside the project and restored
after an unexpected exit. Undo/Redo reveals the affected edit. Editing never
overwrites source media.

The speed selector beside Play reviews at 0.5×, 1×, 2×, or 5×. Speed can change
while playing or paused, and remains selected while editing and replaying.
This is a preview preference; project timing, Undo history, and exports are unchanged.

**Canvas** sets the output shape (Source, 16:9, 9:16, or Square), padding, screen
corner radius, and background color for the whole recording. The full screen image
fits inside the canvas; camera placement uses the entire output, including margins.
Preview and export use the same composition.

**Audio** controls mute and volume for all original audio tracks together. Fade
in and fade out run from the kept trim boundaries and can last up to five seconds
each. If a short trim leaves too little room, both fades shorten proportionally;
restoring a longer trim restores their requested lengths. Each slider gesture,
mute change, or **Reset audio** is one undo step. Existing projects keep full
volume with no fades. Audio edits change only project metadata; source tracks
and their relative levels stay intact. Playback and export share the same gain
envelope when media processing is enabled.

The toolbar uses Undo, Redo, and Share icons with tooltips. Share offers **Save
Video…** (Command-E) and **Share Video…** (Shift-Command-E). Save uses a native file
panel with Full resolution, 1080p, and 720p size choices; Share prepares a video
for the macOS share picker. Both show progress and Cancel. Output is compressed
MP4, separate from the originals. Confirmed replacement of an exported file occurs
only after rendering completes; cancellation leaves an existing destination intact.
Command-S saves pending edits, including a name being edited.

**File → Duplicate Recording** (Shift-Command-S) opens an independent project
beside the original, including pending edits. The copy has its own name and a
fresh Undo history. The original's file, history, pending edits, and recovery
journal stay unchanged. Both projects use the same original screen, camera, and
pointer files; footage is not copied. Duplication also works when an outside
project change prevents saving the original.

Projects stay in the list if their media is missing. Open one and use **Locate…**
to copy the original file back into its project folder. The chosen source is left
unchanged, and existing files are never overwritten by this recovery action.

## Director mode

Turn on **Director** in the editor toolbar to draw reference boxes and type or
dictate editing instructions in one sidebar. Choose **Draw box** on the preview
and drag to identify an area. The box keeps the video's aspect ratio throughout
the drag and shrinks both dimensions together at the source edge. Select it and say “this area” in an instruction.
Boxes show matching **Box 1**, **Box 2** badges in the preview and sidebar.
Timeline edits have speakable letter references in descriptive lane labels
(such as **Zoom A**, **Hold B**, or **Camera C**) and the selected-edit preview badge. These references survive
retiming, insertion, removal, Undo/Redo, recovery, and reopening; they do not
silently renumber. New edits can therefore have later letters between older edits.
The box is stored in original source coordinates with the source timestamp and
the edit selected when drawn. Selecting a box preserves the current edit,
playhead, and unfinished framing adjustments. **Go to Box 1's Frame** in its
context menu explicitly returns to the frame where it was drawn. Moving the
associated edit does not silently move that source frame. All references remain
visible across edit selection in Director mode; offscreen boxes have numbered
direction badges on the preview boundary.
If the frame has no edit yet, drawing a box creates its reference mark in the
same undoable operation. This adds no zoom or camera movement, so the first
box-first workflow has an Edit A to refer to without changing the footage.
The preview's **Pan view / Draw box** selector chooses the mouse gesture.
**Pan view** lets you drag a zoomed video while keeping Director and its boxes
visible. Box badges remain selectable, and the camera remains directly movable
and resizable. **Draw box** opens Director if necessary and pauses playback when
you start drawing. Drawing retains a fixed source frame until release. Pinch and
two-finger pan work with either tool. Switching tools cancels an unfinished mouse
gesture while retaining earlier completed framing adjustments at that time.
Escape cancels unfinished drawing or framing first, then exits Director mode.
A box's X removes its guide and optional name; Undo restores both.

There is one instruction field and one microphone. An optional box name is
available from its context menu; Return saves, Escape or dismissing cancels.
Naming is never required to use a box. Names describe guides and do not become
visible graphics. The microphone starts dictation; pressing it again finishes
recognition and submits the instruction. Escape cancels. Typed instructions use
Return or the send icon. The Apple SpeechAnalyzer fallback runs on-device on supported macOS26+
hardware/locales. It may download Apple speech assets on first use; audio is
never sent to a transcription service. There is no cloud speech fallback.
An absent asset-installation request is a normal result when Apple already has
the required assets. The app rechecks readiness and lets the recognizer prepare;
it does not infer a connectivity problem from that optional result. Native
speech tests feed generated PCM through the production converter and recognizer
without opening the microphone or playing sound.

Supported instructions add smooth region-to-region framing sequences with timed
holds, return to full frame, revise the selected edit while preserving its timing,
and label areas. Named references work across frames: “At Edit A, frame Box 1.
Between A and B, zoom out then smoothly into Box 2, arriving at B.” A two-leg
path inserts an editable full-frame waypoint halfway between the endpoints,
using the shared acceleration/deceleration curves. Conflicting intervening edits
produce a clarification instead of being replaced. Unknown or removed references
produce a question naming the unresolved edit or box.
For relative timing, “One second from now, pan from Box 1, zoom out, and into
Box 2 after three seconds” starts one second after the playhead and arrives
three seconds after that same playhead. The app builds the path from the named
boxes and timing. A rejected model plan gets one automatic repair attempt using
the actual rejection result; the user is not asked to repeat already stated timing.
For a direct move without a preexisting endpoint, say “At Edit A, pan and zoom
from Box 1 to Box 2 over five seconds.” The destination receives its own stable
edit letter automatically. Pulling back to full frame happens only when requested.
Conflicts are checked against the affected target: competing screen-framing
movements are flagged, while camera movement and pointer styling remain intact.
Each complete request is one normal saved Undo/Redo operation.
Ambiguous requests ask a question. If a sequence overlaps existing framing edits,
the assistant asks for an explicit revision instead of silently replacing them.
Edits made while a request is running invalidate its revision and prevent stale
results from applying. Escape, the request X, or closing the sidebar cancels it.
Starting a manual framing or drawing gesture also cancels an in-flight plan.

Human and agent changes share one chronological history. An agent request has one
descriptive Director entry. The standard Edit menu names the next Undo and Redo
actions. Fresh edits clear Redo. The agent can create, move, and remove marks,
and invoke the same Undo/Redo stack. It cannot selectively skip manual edits to
undo an older request.

Literal single-mark create, move, and delete requests also validate the proposed
operation and target identity against the instruction. A mismatched model action
is rejected before changing the project; the model receives that actual rejection
for one corrective turn. Repeated mismatches leave the project unchanged.

The initial model context includes the next eight Undo and Redo names and the
total stack sizes. Director can request older entries through the read-only
`inspect_history` tool, receiving bounded pages with the actual changes described
from saved snapshots. Inspection does not edit the project or create Undo entries.
This is the available Undo/Redo history, not an audit log of discarded Redo branches.
“Undo the last change” still uses the same next action as the normal Undo control.

Director receives ordered user messages, assistant tool calls, and the actual
application results, alongside manual changes and Undo/Redo events. Every request
also includes the complete current edit state. Recent exchanges retain matching
tool-call/result pairs; older activity becomes compact summaries. Conversations,
unfinished instructions, and pending questions are saved locally per project.
Reopening preserves a question only if the recording revision still matches.
The original instruction's playhead remains its timing anchor across answers;
the current playhead and selected box/edit are supplied separately. An explicit
“start at the current playhead instead” can change that anchor.

The conversation groups consecutive manual adjustments to the same target into
one latest-result card. Expand its earlier adjustments to inspect previous
results. User turns, Undo/Redo, and changes to a different target break the group.
This display grouping preserves the saved conversation and the ordinary Undo stack.

Local debugging traces include recognition hypotheses and final text, model
requests/responses, applied or rejected commands, and manual editor events.
They are private JSONL files in `~/Library/Logs/FrameThrower/Director`, rotated
at 5 MiB with three archives. They contain text and edit metadata, never audio
or footage. Conversation archives live in
`~/Library/Application Support/FrameThrower/Director`. Automated checks use
temporary directories and synthetic PCM without opening a microphone or speaker.

Video processing remains suspended. Guides and framing metadata work on the
vector test pattern; decoding footage, screenshots of footage, visual recognition,
capture, rendering, and export remain unavailable. The text model knows only
provided area coordinates/notes and the selected edit, and cannot inspect footage.

`llama.cpp` runs the optional Qwen3-8B Q4_K_M GGUF locally. The installer pins
an official Qwen release and verifies its SHA-256 before using it. The 5.03 GB
model stays in `~/Library/Caches/FrameThrower/LocalModel/models`, outside the
repository. Model weights use Apache-2.0; see the linked model card in the saved
manifest. Install `llama.cpp` first if `llama-server` is unavailable.

```sh
python3 -B Tools/local_model.py install
Tests/check-local-agent.sh
python3 -B Tests/LocalModelClientChecks.py
Tests/check-local-edit-planner.sh --model
Tests/check-local-model-runtime.sh --model
Tests/check-spoken-references.sh --model
```

Installation downloads weights. Inference uses an offline server bound to numeric
loopback with a per-run local key, proxies disabled, redirects rejected, and no configured
remote tools or cloud fallback. Metal on Apple Silicon is the default; use
`Tests/check-local-agent.sh --backend cpu` only for diagnostics. Text inference
uses a different pipeline from video decoding/scaling and leaves the media
interlock enabled. The native app also starts and stops its own model process
per request; cancellation and app termination clean up its authentication key.

The six synthetic tool-call checks cover movement/hold timing, selected scribble
references, voice labels, revising existing edits, ambiguous targets, and the
video interlock. That Python harness remains a prototype check. The native
planner test additionally exercises the app's actual Swift transport, plan
parser, command dispatcher, project save, and atomic Undo/Redo. Its timing test
checks every requested movement, including the final zoom back out.
Development harness prompts and responses stay in private local directories under
`~/Library/Caches/FrameThrower/LocalModel/runs`. Console output contains only case
names, pass/fail results and timings. Network-boundary unit checks use a temporary
loopback HTTP server and require no model.

To keep a model server open for development, run
`python3 -B Tools/local_model.py serve`. It prints its loopback address and the
local key/log directory; Control-C stops it. Model and runtime choices are
isolated from the editor's project model and command API.
The 8B default replaced 4B after the smaller model inconsistently completed
multi-edit named-reference instructions in native tests. The earlier pinned
4B file can still be supplied explicitly to the Python runner for diagnostics.
The native assistant uses an 8,192-token context and Metal on Apple Silicon.

`EditorCommandBatch` is the provider-independent integration boundary: a version,
project UUID, expected SHA-256 revision, and ordered typed commands. Supported
actions are `frameRegion`, `fullFrame`, `holdFraming`, `reviseFraming`,
`moveBetweenEdits`, `moveForDuration`, `createEdit`, `moveEdit`, `removeEdit`,
and `labelRegion`. Shared history requests use `EditorHistoryRequest` and the
same revision checks. Times are original recording seconds; framing timestamps are
arrival times and movement duration specifies the preceding transition. Region
rectangles use normalized top-left source coordinates. The dispatcher validates
the complete batch before committing, accepts no paths or executable operations,
and rejects stale projects and pending manual drafts. UI, future MCP adapters,
and App Intents can share it; external MCP/Siri adapters are not implemented yet.

Safe UI regressions include `Tests/check-editor-inspector-layout.sh` (all four
tools keep identical preview/timeline geometry), `Tests/check-assistant-panel.sh`
(one instruction field/microphone and compact linked box rows), and
`Tests/check-editor-references.sh` (persistent names and recovery). These checks
use metadata, vector test patterns, and guides while video remains suspended.

## Accounts and sharing

Open **Accounts** to connect Google Drive or Slack in your browser. After recording,
use the recording’s Share icon and choose **Upload…**, then select a Slack person or channel and click **Send**, or
click **Upload** beside Google Drive. Uploads are manual and show progress; successful
uploads copy their link to the clipboard. Drive uploads create a file in the
root of your Drive and do not change its sharing permissions.

OAuth client configuration is bundled through `FrameThrower/project.yml` and
`FrameThrower/Resources/Info.plist`; the app has no client-ID entry fields.
Google sign-in uses a loopback HTTP callback and requests the `drive` scope.
Slack sign-in uses the existing hosted callback at
`https://screencast-auth.bosullivan.workers.dev/slack/oauth`, which redirects to
the app's `screencast-slack` URL scheme. A separate Slack deployment needs its
own OAuth client and callback service.

The bundle identifier remains `com.example.screencast` to preserve existing
preferences and accounts. OAuth tokens are currently stored in the app's
UserDefaults preferences, not the Keychain.

## Troubleshooting

Use `Tools/build-debug.sh` for an incremental Debug build without terminal
indexing; append `CODE_SIGNING_ALLOWED=NO` for a compile-only check. Regenerate the
Xcode project after adding source files or changing `project.yml`.

The current suspended build can be checked with `Tests/check-media-suspension.sh`
without opening media or starting capture. Model, project-file, and text-control
checks also remain available. The media checks below are currently skipped;
their descriptions record what they verify when media processing is enabled.

Automated checks run without camera hardware or connected accounts:

- `Tests/check-editor-simulation-clock.sh` and `Tests/check-editor-simulation.sh`:
  deterministic transport timing, pause/seek/trim-end/restart/close, interpolated
  vector screen/PIP geometry, and absence of media players, video layers, and assets.
- `Tests/check-director-conversation.sh`: ordered dialogue and real tool results,
  manual edits, exact Undo/Redo events, persisted questions, fresh selections,
  frozen timing anchors, failed-save preservation, and compact history snapshots.
- `Tests/check-history-lookup.sh`: bounded read-only history inspection, saved
  snapshot summaries, and model continuations using actual lookup results. Add
  `--native-model` to check the installed Metal text model's lookup and answer.
- `Tests/check-management-intent.sh`: captured wrong-action responses, target
  substitutions, unknown labels, and bounded correction through the real session.
  Add `--model` to run the corrective turn through the local Metal model.
- `Tests/check-director-diagnostics.sh`: correlated private traces, bounded
  rotation, valid JSON truncation, permissions, and nonfatal write failures.
- `Tests/check-director-voice-integration.sh`: generated in-memory speech through
  the native recognizer and text model, actual framing edits, conflict answers,
  exact timing, and atomic Undo/Redo. Requires installed local assets; never
  opens a microphone, plays sound, or constructs a video asset. Add `--whisper`
  to test the Metal speech controller instead of Apple's recognizer.
- `Tests/check-editor-inspector-layout.sh`: all inspector tabs, selected and
  deselected edits, fixed preview/timeline geometry, and canceled slider rollback
  with metadata-only previews. UI fixtures use in-memory Director sessions.
- `Tests/check-editor-file-menu.sh`: actual Window-scene File menu commands,
  ordering, and the standard Duplicate shortcut without opening projects or media.
- `Tests/check-recording-audio.sh`: gain/fade curves, trim behavior, legacy
  migration, validation, persistence, Undo/Redo, and unchanged original bytes.
- `Tests/check-recording-audio-mix.sh`: actual AVAudioMix gain ramps and track
  mapping, including short trims and mute, without opening assets or playing audio.
- `Tests/check-pointer-recovery.sh`: same-size source mutations, atomic path
  replacement, exact stable copies, staging cleanup, and no-overwrite publication
  using temporary pointer JSON while movie recovery remains suspended.
- `Tests/check-project-save-conflicts.sh`: changed or missing saved projects,
  first-save collisions, preserved local drafts/history, and safe retry after
  restoring the exact baseline. Existing-file checks are optimistic; first-save
  publication requires a hard-link-capable filesystem.
- `Tests/check-local-model-process.sh`: already-exited, graceful, forced, and
  canceled shutdown, repeated close, actual child disappearance, and local-key
  cleanup using tiny subprocesses without inference.
- `Tests/check-recording-masters.sh`: synthetic ProRes/PCM tracks, first-frame
  timing, separate audio, bounded backpressure, interrupted capture, and final frames.
- `Tests/check-project-recovery.sh`: journal restoration, coalescing, stale/corrupt
  journals, protected sources, failed saves, and history navigation.
- `Tests/check-presentation-model.sh`, `check-presentation-renderer.sh`, and
  `check-presentation-canvas.sh`: output geometry, legacy defaults, source fitting,
  preview/export pixels, and gesture coordinates with padding.
- `Tests/check-render-cadence.sh`: sparse high-quality masters retain 60 fps
  preview/export animation; legacy projects retain 30 fps.
- `Tests/check-video-export.sh`: export sizes, progress, approved replacement,
  original protection, cancellation, and temporary-file cleanup.
- `Tests/check-media-recovery.sh`: validated movie/pointer recovery, bounded copies,
  cancellation, no-overwrite publication, and unchanged sources.
- `Tests/check-recording-row.sh`: native thumbnail/open/share/remove targets,
  independent recording actions, export state, and bounded thumbnail decoding.
- `Tests/check-recording-project.sh`: edit persistence, legacy compatibility,
  undo/redo, resize and crop geometry, and source preservation.
- `Tests/check-recording-names.sh`: shared names, legacy defaults, persisted
  rename/video undo history, validation, failed-save atomicity, and unchanged media.
- `Tests/check-recording-library.sh`: discovery, imported projects, canonical
  identity, removal/restore across restart, stale scans, and source preservation.
- `Tests/check-recording-title.sh`: native single/double click, inline editing,
  Return saves, Escape/outside clicks cancel, draft clearing, focus transfer,
  validation, and rename undo/redo.
- `Tests/check-recorder-workspace.sh`: preview minimum size, stable capture
  geometry with changing history, and Record above the recordings list.
- `Tests/check-initial-camera-preview.sh`: camera placement within the main
  recording region, negative display origins, full drag deltas, and clamping.
- `Tests/check-project-renderer.sh`: pixel-level screen/camera zoom and pan, pointer
  sizing/smoothing/clicks, shape transitions, audio, and preview/export parity.
- `Tests/check-zoom-model.sh`: shared main/PIP motion, configurable acceleration
  and deceleration, constant-speed cruise, bounded source zooms, and legacy defaults.
- `Tests/check-edit-draft.sh`: combined same-time edits, grouped retiming/removal,
  one-step undo/redo, failed-save recovery, ramp persistence, and immutable originals.
- `Tests/check-editor-draft-lifecycle.sh`: failed-save veto for Close and Quit,
  preserved pending edits, delegate forwarding, and successful save boundaries.
- `Tests/check-editor-trackpad.sh`: native pinch/pan/momentum, pointer anchoring,
  bounded zoom, stale configuration, and cancellation.
- `Tests/check-cursor-recording.sh`: mouse coordinates, precise click events and
  dragging, smoothing, source-time alignment, and immutable metadata.
- `Tests/check-capture-audio-settings.sh`: remembered microphone restoration,
  system-default fallback, and camera-session microphone defaults without hardware.
- `Tests/check-cursor-zoom-suggestions.sh`: click grouping, holds, smooth focus
  suggestions, trim bounds, deterministic points, and limits on long recordings.
- `Tests/check-zoom-interactions.sh`: actual editor double-click zoom, pan, PIP
  gesture priority, Escape, undo/redo, and stable inspector allocation.
- `Tests/check-editor-playback.sh`: bounded still-frame work during rapid scrubbing,
  cancellation, stale-result suppression, and end-exclusive seeking.
- `Tests/check-native-preview-sources.sh`: native playback pixel parity, bounded
  source-frame ownership, full camera framing, and live zoom/PIP/pointer drafts.
- `Tests/check-recording-timeline.sh`: native scrub and trim gestures, separate
  hit targets, draggable edit diamonds, empty-space deselection, Escape routing,
  mouse/keyboard focus cues, pinch navigation, transition bands, and bounds.
- `Tests/check-preview-tools.sh`: Pan/Box routing with Director visible, live
  aspect-locked boxes, frozen drawing coordinates, cursor targets, gesture
  cancellation, trackpad momentum, and independent PIP manipulation without media.
- `Tests/check-timeline-animation-interactions.sh`: persistent native lanes,
  body/endpoint/ramp gestures, contact and Option pushing, short-mark selection,
  lane-local deletion, pointer ticks, cancellation, and conflict hit targets.
- `Tests/check-editor-animation-editing.sh`: timing solver, ripple chains and
  boundaries, actual screen/camera interpolation, shared-reference splitting,
  stable labels, atomic drafts, Undo/Redo, failed saves, and metadata preservation.
- `Tests/check-camera-recording.sh`: synthetic camera writing and frame timing.
- `Tests/check-capture-lifecycle.sh`: bounded SDK callbacks, event ordering, media
  finalization, and retry isolation.
- `Tests/check-editor-interactions.sh`: production editor mouse gestures, exact
  drag deltas, persisted undo/redo, and trim integration.
- `Tests/check-capture-source-previews.sh`: source identity, area crop pixels,
  negative display origins, fitted PIP bounds, cache invalidation, automatic
  refresh, cancellation, nonoverlapping screenshots, and retry backoff.
- `Tests/check-display-carousel.sh`: aspect-fitted display thumbnails, selection
  borders, compact unavailable states, and clickable image/name/dimensions.
- `Tests/check-editor-canvas.sh`: native image orientation, letterboxing, resize
  handle alignment, and Escape cancellation without an edit.
- `Tests/check-windowgroup-layout.sh`: the actual SwiftUI editor scene, repeated
  play, trim-handle grabs and scrubbing at normal/minimum widths without reflow.
- `Tests/check-live-editor-layout.sh`: real 1080p video, changing scrub and live
  camera pixels, stable canvas/window geometry, and one undo per drag.
- `Tests/check-editor-windows.sh`: shared project identity, independent window
  histories, reopening, and failed-open recovery.
- `Tests/check-project-streaming-playback.sh`: real AVPlayer frame output across
  camera gaps, timed shapes, and smooth transitions.
- `Tests/check-area-preview.sh`: area coordinate mapping, native drag interactions,
  keyboard nudges, and recording lock using offscreen views.

Open **Activity** in the footer for errors, or read
`~/Library/Logs/Screencast.log`. If the app opens but recording is disabled, check
its Screen Recording permission and restart the same signed build. A successful
build alone does not verify capture permissions or authenticated uploads.

`Tools/slack_upload.swift` is a separate developer helper: it uploads the latest
legacy-prefixed recording (or a supplied path) to the configured `bos` Slack DM
using the app's saved Slack token. Running it sends a real message.


## Deferred improvements

- Automatically detect and center an off-center face when the PIP crop is smaller
  than the full camera image. Keep the full source, retain manual framing overrides,
  and make automatic framing reversible through the existing edit history.
