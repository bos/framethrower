# FrameThrower

A native macOS screen recorder built with SwiftUI and ScreenCaptureKit. Record a
window, a display, or an area selected by dragging, then optionally upload the
recording to Google Drive or a Slack person/channel.

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
   A separate editor window opens when capture finishes; use **Edit…** to reopen
   it. The recorder stays usable, and each project's editor has its own undo history.

Screen originals are H.264 MP4 files saved as
`~/Movies/Screencast-<UTC timestamp>-<unique suffix>.mp4`. Camera video is saved
separately beside the screen original as `.camera.mov`. New recordings also save
mouse motion and clicks in an immutable `.cursor.json` sidecar. A `.framethrower`
project stores edits and undo history. Keep these files together. The legacy
filename prefix is retained for compatibility with the upload helper. Local
recording and editing do not require connecting Google Drive or Slack.

## Editing

Use the single timeline to scrub and drag its blue handles to trim. Arrow keys
seek by 0.1 seconds; Shift-arrow seeks by one second. Trimming keeps every original
frame available. Right-click the timeline for **Reset trim**. Space starts or
pauses playback.

The fixed-height inspector has **Zoom**, **Pointer**, and (when present) **Camera**
controls. Double-click the recording to zoom in at that position or return to
1×. Drag a zoomed recording to pan. The Zoom slider and timed zoom changes
support **Jump** and **Smooth** arrivals with adjustable duration. Select a change
to change its movement or use the current video time; remove it to delete the edit.
Purple diamonds link each zoom change to its time on the timeline; click a diamond
or its matching list item to select it. Hover controls for action-specific help.
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
can all change over time. Dragging updates the PIP picture live and commits one
undo step when released. **Jump** changes placement instantly; **Smooth** eases
position, size, aspect, and framing toward the change. Shape and visibility switch
at the change's time.

Every edit, including trim, supports Command-Z and Shift-Command-Z. Each drag is
one undo step. Edits and history save automatically and survive reopening through
**Open…**. Editing never overwrites source media. **Export…**, Slack, and Drive all
render the current edit using the same composition as the preview, creating a
separate MP4. Export encoding is independent of nondestructive editing.

## Accounts and sharing

Open **Accounts** to connect Google Drive or Slack in your browser. After recording,
click **Share…**, then select a Slack person or channel and click **Send**, or
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

Automated checks run without camera hardware or connected accounts:

- `Tests/check-recording-project.sh`: edit persistence, legacy compatibility,
  undo/redo, resize and crop geometry, and source preservation.
- `Tests/check-project-renderer.sh`: pixel-level screen/camera zoom and pan, pointer
  sizing/smoothing/clicks, shape transitions, audio, and preview/export parity.
- `Tests/check-zoom-model.sh`: shared main/PIP motion, bounded source zooms,
  legacy defaults, and persisted reversible zoom/pointer edits.
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
- `Tests/check-recording-timeline.sh`: native scrub and trim gestures, overlapping
  hit targets, visible/selectable zoom markers, undo grouping, bounds, and keyboard seeking.
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

- Higher-quality video/audio masters with separately configurable compressed
  exports. Current screen and camera originals use H.264; nondestructive editing
  preserves them but does not make the original capture lossless.
- Automatically detect and center an off-center face when the PIP crop is smaller
  than the full camera image. Keep the full source, retain manual framing overrides,
  and make automatic framing reversible through the existing edit history.
