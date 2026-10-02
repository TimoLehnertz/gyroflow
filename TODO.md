# Todos

- on branch origin/feature/better-multi-file Pressing the play button (start export) should open the que modal
- on branch origin/feature/better-multi-file ESC should close the que modal
- on branch origin/feature/better-multi-file
- on whatever branch this got introduced in. When the playhead is outside the render sequence(s), The preview is wacky. It seems to be distorted extremely towards the center. Probably because scaling is incorrect there.
- On branch origin/feature/better-multi-file The footer of the main view needs to get organized better. Right now it takes up way too much space horizontally and is not intuitive

## Multi trim ranges overhaul

On branch origin/feature/better-multi-file

Right now, each video can have multiple sections in the media sidebar. And there is also an old feature that allows having multiple trim ranges per video. These features collide. Here we resolve that collision. The sidebar should no longer be responsible for that. Instead multiple trim ranges should be managed by the timeline exclusively just as upstream gyroflow did it. But we need some changes to that as well:
The option "export trim ranges as separate videos" should be moved from the advanced section into the footer and it should be a listbox. Next, There must be a button to add a new trim range (That is needed beccause Not all users know about the ctrl + I / O shortcut). Next, It must be possible to define different stabilization settings per trim range. This should be done by offering two modes:

- Shared config (default)
- Separate config. The dispalyed config should be the config of the active range. The active range is the range in which the cursor is in or the last active one. The active range must be visually highlighted. New ranges get the config of the active range. There must be a button to copy settings to the other ranges. Merge this with the pre existing button to copy settings to otehr clips using a dropdown.

When done, merge the branch origin/feature/better-multi-file into master

## Other Todos

- On branch origin/feature/better-multi-file The original left sidebar must get removed and its parts moved elsewhere. The gyroflow logo should go in the top of the media sidebar. Video information, lens profile and motion data should go into a modal that can be opened from a video.
