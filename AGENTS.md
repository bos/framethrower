# Interface copy

Use visible text only when it identifies a control, explains a concrete action,
reports a meaningful state or error, or provides information needed for a decision.
Do not add taglines, slogans, promotional captions, generic reassurances, or redundant
subheadings. Prefer concise tooltips for secondary interaction instructions.

# Restarting the development app

After sending Quit, discard the computer-use app handle. Do not request an
accessibility tree, screenshot, or another action from that terminated process;
doing so can trigger macOS “application is not open anymore” dialogs. Check
process exit through read-only process inspection, replace the installed build,
then acquire a fresh app handle to launch and inspect it. Do not retry stale
handles or batch a post-quit inspection with the Quit action.

# Video capture restriction

Bryan lifted the recorded-video moratorium on November 10, 2026. Importing,
creating recorded test fixtures, decoding, playback, encoding, compositing and
export of recorded video are permitted.

Keep `MediaProcessing.isCaptureSuspended` fixed true. Do not start live screen,
window, area or camera capture, live previews, or screenshot capture. Do not
remove or bypass that capture interlock without Bryan explicitly authorizing it.
`MediaProcessing.requireEnabled()` guards recorded processing;
`requireCaptureEnabled()` guards live capture. The disabling-only
`FRAMETHROWER_VECTOR_PREVIEW=1` environment switch keeps metadata/vector tests
independent from codecs and devices; it cannot enable capture.

This is a live-video restriction, not a general GPU restriction. Native Metal
compute for text-only local language models is allowed. Use Metal by default for
local model interaction tests; CPU mode is an explicit diagnostic option.
