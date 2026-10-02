# Todos

All branches mentioned in earlier versions of this file (`feature/better-multi-file` etc.) are already merged into `master`. New work starts from `master`.

- Pressing the play button (start export) should open the queue modal
- ESC should close the queue modal
- The footer of the main view needs to get organized better. Right now it takes up way too much space horizontally and is not intuitive. Do this together with the multi trim ranges overhaul, which adds controls to the footer.
- Make applying settings to queued clips efficient: re-process the gyro data (`recompute_gyro`) when a job starts rendering instead of when settings are applied, so applying only stores parameters.

## Multi trim ranges overhaul

Right now, each video can have multiple sections in the media sidebar. And there is also an old feature that allows having multiple trim ranges per video. These features collide. Here we resolve that collision. The sidebar should no longer be responsible for that. Instead multiple trim ranges should be managed by the timeline exclusively just as upstream gyroflow did it. But we need some changes to that as well.

### Sidebar and marker import
- Sections are removed from the media sidebar, it only lists videos.
- Marker import creates trim ranges on the clip instead of sidebar sections.
- Trim ranges get an optional name (eg. the marker name). When exporting ranges as separate videos, the name is used in the filename instead of the `-001`, `-002` numbering.

### Timeline
- There must be a button to add a new trim range (needed because not all users know about the Ctrl+I / Ctrl+O shortcuts):
  - Playhead outside a range: start a new range there, ending at the next range or after a default length.
  - Playhead inside a range: split that range at the playhead.
- The active range is the range the playhead is in, or the last active one. The active range must be visually highlighted.
- "Restrict playback to trim range" is off by default (currently on) and also gets a button with an icon (not only the timeline context menu), for better accessibility. When on, playback is restricted to the active range (currently it's the span from the first to the last range).
- Fix: when the playhead is outside the trim range(s), the preview is wacky, it seems to be distorted extremely towards the center. Probably because the zooming/scaling is only computed inside the trim ranges. With multiple ranges the playhead is often outside of them, so this must be fixed as part of the overhaul.

### Export of the ranges
- The option "Export trim ranges as separate videos" moves from the advanced export section into the footer, as a listbox: "One video per range" / "Join ranges into one video".
- "Join ranges into one video" is only available in shared config mode (the renderer uses one set of stabilization settings per output file). Separate config always exports one video per range.
- Every output file is its own item in the render queue: "One video per range" gives one item per range, "Join ranges into one video" gives one item for the clip. Items of the same clip are displayed grouped per video.
- The queue items of the same clip share its loaded stabilizer (see Efficiency), so having one item per range doesn't cost extra memory or processing.

### Stabilization settings per range
It must be possible to define different stabilization settings per trim range. This should be done by offering two modes:

- Shared config (default)
- Separate config. The displayed config should be the config of the active range. New ranges get the config of the active range.

Details:
- "Config" means the stabilization settings (the Stabilization panel: FOV, smoothing, horizon lock, zooming, rolling shutter, ...). Lens profile, motion data, synchronization and export settings stay per clip.
- Switching Separate -> Shared: the config of the active range becomes the shared config.
- Switching Shared -> Separate: every range starts with the current shared config.
- When the active range changes (also while playing), the panels and the preview switch to its config. A short recompute at range boundaries is acceptable.
- There must be a button to copy settings to the other ranges. Merge this with the pre-existing button to copy settings to other clips using a dropdown. Proposed names: "Apply to all ranges of this clip" and "Apply to other clips...".
- Copying to another clip that is in separate config mode applies the settings to all of its ranges.
- The per-range settings are saved in the `.gyroflow` project file as a new field. Upstream Gyroflow ignores it and uses the shared settings.

### Efficiency
- A clip keeps one loaded stabilizer for all its ranges, never one per range. Its queue items (one per range) all use that stabilizer, rendering only their own range. Items of the same clip must not recompute the shared stabilizer at the same time (eg. with parallel renders), and only recompute when its settings actually changed.
- Shared config: all ranges are rendered from the same stabilizer, the smoothing is computed once.
- Separate config: same stabilizer, the settings are swapped and the smoothing is recomputed per range at render time.

### Suggested order
The parts marked (upstream) are developed on branches based on `upstream/master` and merged into `master`, see "Upstream PRs".
1. The efficiency fix from the list above (gyro processing at render start) (upstream, PR 3)
2. The outside-range preview fix (upstream, PR 5)
3. Sections removed from the sidebar, marker import creates ranges
4. Timeline: add range button, active range and highlight, playback restriction (upstream, PR 6)
5. Footer redesign with the separate/join listbox
6. Separate config mode (upstream, PR 7) and the copy dropdown (fork part: "Apply to other clips...")

## Upstream PRs (gyroflow/gyroflow)

Rules:
- One focused PR per topic, never one big PR and never from the fork's `master`.
- Each PR branch is based on `upstream/master`, rebased right before opening the PR, with clean squashed commits.
- Work that should go upstream is developed on an upstream-based branch first and then merged into the fork's `master`, instead of extracting it from `master` later.
- Fork-only work (media library, release workflow, version bumps, CRLF, this file) is never PRed.
- CONTRIBUTING requires that the author wrote 100% of the content. The commits carry `Co-Authored-By: Claude`, so mention the AI assistance in the PR descriptions or ask on Discord first.

First, sync the fork: merge `upstream/master` into `master` (4 newer upstream commits: lens profile math rework, optical-only stabilization). `cli.rs`, `rendering/mod.rs`, `rendering/render_queue.rs` and `App.qml` changed on both sides, expect conflicts there.

### Now (independent of the overhaul)
1. **Fix undecodable HEVC/H.264 files from the VAAPI encoders**: branch `fix/vaapi-hevc-parameter-sets`, ready (based on current `upstream/master`). Push to origin and open the PR.
2. **Fix transparent window with NVIDIA + Wayland**: branch `fix/nvidia-wayland-transparent-window` (commit `1f67921f`), 4 commits behind upstream. Rebase, and leave out the Arch/Omarchy part of the README changes unless upstream wants it.
3. **Make "Apply settings to render queue" fast**: upstream has the same problems (blocking smoothing/zoom recompute for every queued job on the UI thread, stabilizer output size not updated). Implement the lazy gyro processing from the list above on an upstream-based branch, together with the `render_queue.rs` part of `ff471df7` (non-blocking import, output size from the render options), PR it and merge the branch into `master`.

### After a short discussion with the maintainer (issue or Discord)
4. **Option to export without stabilization (trim only, no re-encoding)**: branch `feature/disableable-stabilization` (`5cf8614b`, `7a7a4884`, `aa982088`), 4 commits behind upstream. Add the fullscreen fix `59965136` (bug introduced by `5cf8614b`), squash, rebase. Overlaps with upstream's newer changes in `render_queue.rs` and `rendering/mod.rs`.

### Parts of the multi trim ranges overhaul (develop on upstream-based branches)
These are plain timeline/core features, they don't need the media library:
5. **Preview outside the trim ranges**: the zoom is only computed inside the trim ranges (`zooming/mod.rs`, the core is unchanged in the fork), so this is most likely an upstream bug too. Verify on an upstream build, then fix and PR it first, it's small.
6. **Trim range controls**: add range button, active range and its highlight, "Restrict playback to trim range" button with icon and limited to the active range. Changing the default to off should be discussed in the PR.
7. **Stabilization settings per trim range** (shared / separate config, copy to other ranges, saved in the project file): big, discuss the design first. Upstream doesn't have the "apply to other clips" button of the media library, so its part of the dropdown stays in the fork.

The export listbox "One video per range / Join ranges into one video" goes into the fork's reworked footer. For upstream it would replace the checkbox in their export settings, which can be part of PR 6.

### Fork-only for now
- Media library / multi-file workflow: sidebar, queue modal, footer buttons, marker import, output paths, export settings per clip, queue items per output file with a shared stabilizer. It's still being redesigned (overhaul above). Once it's settled, propose it in an issue with screenshots, and if the maintainer is interested, split it into several PRs (library and sidebar, queue modal, footer, marker import).

## Other Todos

- The original left sidebar must get removed and its parts moved elsewhere. The gyroflow logo should go in the top of the media sidebar. Video information, lens profile and motion data should go into a modal that can be opened from a video.
