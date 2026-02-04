# Screencast

macOS ScreenCaptureKit recorder with Google Drive upload. It records a window, display,
or a user-entered area rectangle and uploads the last recording to Drive.

## Quick start

1. Install XcodeGen if you do not already have it.
2. Generate the Xcode project:

```bash
cd Screencast
xcodegen
```

3. Open `Screencast.xcodeproj` in Xcode.
4. Set your signing team for the `Screencast` target.
5. Run the app. The first capture will prompt for Screen Recording permission.

## Google Drive setup

1. Create an OAuth client ID for a macOS app in Google Cloud Console.
2. Add a custom redirect URI (example:
   `com.googleusercontent.apps.YOUR_CLIENT_ID:/oauth`).
3. Paste the Client ID and Redirect URI into the app.
4. Click Authorize and complete the sign-in flow.

## Notes

- Recordings are saved to `~/Movies` by default.
- Uploads use the `drive.file` scope and create a new file in the root of Drive.
- Area capture uses manual coordinates (x, y, width, height). On macOS 14+, the
  rectangle is applied via `SCStreamConfiguration.sourceRect`.
