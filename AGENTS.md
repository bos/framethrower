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

# Temporary video-driver interlock

Keep `MediaProcessing.isSuspended` enabled while the video-scaling driver is
unstable. Do not run capture, video fixture creation, decoding, encoding,
compositing, scaling, or the blocked media test scripts. Do not remove or bypass
the source and test interlocks without Bryan explicitly authorizing it. Compile
builds and tests of models, files, text controls, and the suspended editor are
permitted. Use empty or vector previews for UI work.

This is a video/media restriction, not a general GPU restriction. Native Metal
compute for text-only local language models is allowed. Use Metal by default for
local model interaction tests; CPU mode is an explicit diagnostic option.
