# Todos

- On a Mac, "One video per range, separate settings" doesn't separate the settings (works on Linux)

## Upstream PRs (gyroflow/gyroflow)

Rules:
- One focused PR per topic, never one big PR and never from the fork's `master`.
- Each PR branch is based on `upstream/master`, rebased right before opening the PR, with clean squashed commits.
- Work that should go upstream is developed on an upstream-based branch first and then merged into the fork's `master`, instead of extracting it from `master` later.
- Fork-only work (media library, release workflow, version bumps, CRLF, this file) is never PRed.
- CONTRIBUTING requires that the author wrote 100% of the content. The commits carry `Co-Authored-By: Claude`, so mention the AI assistance in the PR descriptions or ask on Discord first.

### After a short discussion with the maintainer (issue or Discord)
- **Option to export without stabilization (trim only, no re-encoding)**: branch `feature/disableable-stabilization` (`5cf8614b`, `7a7a4884`, `aa982088`). Add the fullscreen fix `59965136` (bug introduced by `5cf8614b`), squash, rebase. Overlaps with upstream's newer changes in `render_queue.rs` and `rendering/mod.rs`.

### Parts of the multi trim ranges overhaul (port to upstream-based branches)
These are plain timeline/core features, they don't need the media library:
- **Trim range controls**: add range button, active range and its highlight, "Restrict playback to trim range" button with icon and limited to the active range. Changing the default to off should be discussed in the PR. The export listbox "One video per range / Join ranges into one video" would replace the checkbox in upstream's export settings and can be part of this PR.
- **Stabilization settings per trim range** (shared / separate config, copy to other ranges, saved in the project file): big, discuss the design first. Upstream doesn't have the "apply to other clips" button of the media library, so its part of the dropdown stays in the fork.

### Fork-only for now
- Media library / multi-file workflow: sidebar, queue modal, footer buttons, marker import, output paths, export settings per clip, queue items per output file with a shared stabilizer. Once it's settled, propose it in an issue with screenshots, and if the maintainer is interested, split it into several PRs (library and sidebar, queue modal, footer, marker import).
