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

1. Grant FrameThrower access in **System Settings > Privacy & Security > Screen &
   System Audio Recording** (called **Screen Recording** on some macOS versions),
   then quit and relaunch the app. Capture controls stay disabled without access.
2. Choose **Window**, **Display**, or **Area**. Use **Choose…** to select a window
   on screen or drag an area; the window picker also lists available windows.
   Area mode shows the full display with the recording region highlighted. Drag
   outside the region to draw a new one, drag inside to move it, or drag a corner
   to resize it. Arrow keys move the focused region by one point (Shift: ten).
   **Choose…** still opens the full-screen selector for precise adjustments.
   Selecting a source shows a still preview; use its refresh button to update it.
   Preview capture and permission requests do not run automatically on launch.
3. Use the audio checkboxes to enable system audio and/or a microphone. Microphone
   capture needs its own macOS permission.
4. Click **Record**, or use its arrow for a 5- or 10-second countdown.
   Click **Stop recording** to finish. Command-R starts/stops recording.
   The saved clip appears below the preview with playback and Finder shortcuts.

Recordings are H.264 MP4 files saved as `~/Movies/Screencast-<UTC timestamp>.mp4`.
The legacy filename prefix is retained for compatibility with the upload helper.
Local recording does not require connecting Google Drive or Slack.

## Accounts and sharing

Open **Accounts** to connect Google Drive or Slack in your browser. After recording,
select a Slack person or channel in the recording card and click **Send**, or
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

Run `Tests/check-area-preview.sh` to check the area editor's coordinate mapping,
native drag interactions, keyboard nudges, and recording lock using offscreen views.

Open **Activity** in the footer for errors, or read
`~/Library/Logs/Screencast.log`. If the app opens but recording is disabled, check
its Screen Recording permission and restart the same signed build. A successful
build alone does not verify capture permissions or authenticated uploads.

`Tools/slack_upload.swift` is a separate developer helper: it uploads the latest
legacy-prefixed recording (or a supplied path) to the configured `bos` Slack DM
using the app's saved Slack token. Running it sends a real message.
