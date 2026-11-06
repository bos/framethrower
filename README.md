# FrameThrower

A native macOS screen recorder built with SwiftUI and ScreenCaptureKit. Record a
window, a display, or an area selected by dragging, then optionally upload the
recording to Google Drive or a Slack person/channel.

## Temporary media suspension

Video processing is currently disabled in source at the user's request because
of repeated kernel video-scaler hangs. Capture, camera sessions, live source
previews, video playback, thumbnails, composition, and export are blocked. The
editor uses an empty preview while timeline edits, canvas geometry, naming,
project saving, and Undo/Redo remain usable. Existing recordings are untouched.

`MediaProcessing.isSuspended` is fixed to `true`, with no preference or launch
argument override. Media test scripts stop before compilation with `SKIP` and
exit status 77; fixture creation also checks the interlock. Do not re-enable
those paths on this machine without explicit approval. The feature descriptions
below document the implementation behind this temporary interlock.

## Requirements

- macOS 15 or later.
- Xcode with the macOS 15 SDK or later.
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

To build and launch from the command line:

```bash
xcodebuild \
  -project FrameThrower/FrameThrower.xcodeproj \
  -scheme FrameThrower \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  build
mkdir -p ~/Applications
ditto build/Build/Products/Debug/FrameThrower.app ~/Applications/FrameThrower.app
open -g ~/Applications/FrameThrower.app
```

Quit FrameThrower before replacing an installed build. The installed app lives in
`~/Applications`; `build/` contains disposable build output. The `-g` launch option
keeps the app in the background so it does not steal focus.

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
The playhead, trim handles, and edit diamonds have separate hit targets. Click a
diamond to select its edit and inspect that frame; drag it to change its time.
The matching item below gets an outline and scrolls into view. Its **×** removes
the entire edit, including screen and camera changes at that time. Neighboring
edits cannot be overwritten by dragging. Click empty space in the edit lane to
save the pending adjustments and deselect without moving the playhead. Escape
cancels pending adjustments and deselects. Mouse clicks leave no full-timeline
focus border; keyboard navigation uses a small cue beneath the playhead.

The fixed-height inspector has **Zoom**, **Pointer**, and (when present) **Camera**, plus **Canvas**
controls. Pinch over the preview to zoom the picture; two-finger scrolling pans
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
The strip and the selected edit's timeline band show the effective transition,
shortened when the previous edit leaves less time available. Screen and camera
use the same motion curve, with separate settings for each component of an edit.
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

**Canvas** sets the output shape (Source, 16:9, 9:16, or Square), padding, screen
corner radius, and background color for the whole recording. The full screen image
fits inside the canvas; camera placement uses the entire output, including margins.
Preview and export use the same composition.

The toolbar uses Undo, Redo, and Share icons with tooltips. Share offers **Save
Video…** (Command-E) and **Share Video…** (Shift-Command-E). Save uses a native file
panel with Full resolution, 1080p, and 720p size choices; Share prepares a video
for the macOS share picker. Both show progress and Cancel. Output is compressed
MP4, separate from the originals. Confirmed replacement of an exported file occurs
only after rendering completes; cancellation leaves an existing destination intact.
Command-S saves pending edits, including a name being edited.

Projects stay in the list if their media is missing. Open one and use **Locate…**
to copy the original file back into its project folder. The chosen source is left
unchanged, and existing files are never overwritten by this recovery action.

## Local editing instructions and scribbles

Open the editor's speech-bubble button to type or dictate an editing instruction.
The pencil button turns on **Scribble** and opens the same sidebar. Drag a box on
the preview to identify an area; select it and say “this area” in an instruction.
The box is stored in original source coordinates with the source timestamp.
Selecting a saved area returns to that frame. Scribble mode owns drawing gestures;
turn it off to pan, pinch, or move the camera. Escape cancels an unfinished box,
then exits Scribble. An area's X removes its guide and note; Undo restores both.

An optional area note can be typed or dictated. Return saves a note; Escape or
moving focus away cancels its draft. Notes describe guides and do not become
visible graphics. Dictation first produces editable text; submitting an instruction
is a separate action. Apple SpeechAnalyzer runs on-device on supported macOS26+
hardware/locales. It may download Apple speech assets on first use; audio is
never sent to a transcription service. There is no cloud speech fallback.

Supported instructions add smooth region-to-region framing sequences with timed
holds, return to full frame, revise the selected edit while preserving its timing,
and label areas. Each complete request is one normal saved Undo/Redo operation.
Ambiguous requests ask a question. If a sequence overlaps existing framing edits,
the assistant asks for an explicit revision instead of silently replacing them.
Edits made while a request is running invalidate its revision and prevent stale
results from applying. Escape, the request X, or closing the sidebar cancels it.

Video processing remains suspended. Guides and framing metadata work on the
placeholder preview; decoding footage, screenshots of footage, visual recognition,
capture, rendering, and export remain unavailable. The text model knows only
provided area coordinates/notes and the selected edit, and cannot inspect footage.

`llama.cpp` can run the optional Qwen3-4B Q4_K_M GGUF locally. The installer pins
an official Qwen release and verifies its SHA-256 before using it. The 2.50 GB
model stays in `~/Library/Caches/FrameThrower/LocalModel/models`, outside the
repository. Model weights use Apache-2.0; see the linked model card in the saved
manifest. Install `llama.cpp` first if `llama-server` is unavailable.

```sh
python3 -B Tools/local_model.py install
Tests/check-local-agent.sh
python3 -B Tests/LocalModelClientChecks.py
Tests/check-local-edit-planner.sh --model
Tests/check-local-model-runtime.sh --model
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

`EditorCommandBatch` is the provider-independent integration boundary: a version,
project UUID, expected SHA-256 revision, and ordered typed commands. Supported
actions are `frameRegion`, `fullFrame`, `holdFraming`, `reviseFraming`, and
`labelRegion`. Times are original recording seconds; framing timestamps are
arrival times and movement duration specifies the preceding transition. Region
rectangles use normalized top-left source coordinates. The dispatcher validates
the complete batch before committing, accepts no paths or executable operations,
and rejects stale projects and pending manual drafts. UI, future MCP adapters,
and App Intents can share it; external MCP/Siri adapters are not implemented yet.

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
