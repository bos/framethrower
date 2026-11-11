# Backlog

- [ ] **Animate the main video independently to black and back.** Fade the
  screen recording while any PIP continues at its own opacity. Use the same
  timed animation controls, easing, Director tools, and Undo/Redo as PIP fades.
  Keep screen and camera visibility independent.

- [x] **Playback-speed automation in exported recordings.** Support slow-motion
  and fast-forward sections, including smooth speed-up and slow-down ramps over
  a chosen interval. Use the same timeline animation controls and ordinary
  Undo/Redo stack as other edits; preserve the original media.
  - Keep screen video, camera, pointer/click events and audio synchronized.
  - Show the resulting output duration. Define how retiming affects the timing
    of other edit animations and how audio pitch is handled.

  Implemented in the editor, Director tools and shared timing/render plans.
  Runtime capture/export validation remains blocked by the video-driver interlock.

- [ ] **Preserve audio metadata for the primary imported clip.** Retain the
  importer's audio-presence result so silent footage does not advertise an
  audio-envelope disclosure. Handle older projects with unknown audio metadata
  without assuming that a track is present.
- [ ] **Restore baseline audio controls in older projects.** When a decoded
  project identifies microphone or system-audio sources but has no corresponding
  volume-channel state, show a selectable baseline on that track. Opening a
  project should not create an edit or change its ordinary Undo stack.
- [ ] **Edit animation durations numerically on the finished project clock.**
  Define how one value applies when cuts split a movement into several visible
  spans, including crossfades and speed ramps. Until then, numeric fields identify
  original timing explicitly; dragging timeline handles uses the project ruler.
