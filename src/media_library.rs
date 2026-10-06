// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2025 Adrian <adrian.eddy at gmail>

use qmetaobject::*;

use crate::{ core, marker_import, rendering, util };
use crate::core::StabilizationManager;
use core::filesystem;
use std::sync::Arc;
use std::sync::atomic::{ AtomicBool, AtomicUsize, Ordering::SeqCst };
use std::cell::RefCell;

// Not .lrv: those are the low resolution copies GoPro cameras record next to every video, for previews in their app
const VIDEO_EXTENSIONS: &[&str] = &[ "mp4", "mov", "mxf", "mkv", "webm", "insv", "avi", "m4v", "mts", "m2ts", "braw", "r3d", "nev", core::joined_video::EXTENSION ];

// Stabilized state
const NOT_STABILIZED: i32 = 0;
const STABILIZED:     i32 = 1;
const STALE:          i32 = 2;

#[derive(Default, Clone, PartialEq, SimpleListItem, Debug)]
pub struct MediaItem {
    pub item_id: u32,
    pub parent_id: u32,
    pub kind: QString, // folder | video
    pub depth: i32,
    pub name: QString,
    pub url: QString,
    pub output_path: QString,
    pub display_output_path: QString,
    pub expanded: bool,
    pub has_children: bool,
    pub selected: bool,
    pub is_current: bool,
    pub created_at: u64,
    pub duration_ms: f64,
    /// Trim ranges of the video, each of them is exported as its own file unless they are joined
    pub range_count: i32,
    /// Output files (and render jobs) of the video
    pub output_count: i32,
    pub lens_profile: QString,
    pub lens_warning: bool,
    pub scanning: bool,
    pub stabilized_state: i32,
    pub job_status: QString, // "" | queued | processing | rendering | done | error | question
    pub job_progress: f64,
    pub error_string: QString,
    pub job_message: QString,
    /// First job of the video, all of them are returned by `get_item_jobs`
    pub job_id: u32,
    pub job_count: i32,
    /// Files of a joined video (a split recording), 0 for other videos
    pub part_count: i32,
    /// How much of the video is in the render queue: "all" of its keys (every trim range, or the whole video), "some" of
    /// them, or "" (see "Render queue keys")
    pub queue_state: QString,
    pub queued_count: i32,
    pub key_count: i32,
    /// The trim ranges of the video and their state in the queue, JSON `[[start, end, state]]` with the start and the end
    /// as a fraction of the duration and the state as in `get_key_states` ("" if it's not queued). Empty without ranges
    pub range_bar: QString,
}

#[derive(Default, Clone, Debug)]
struct JobState {
    job_id: u32,
    status: String,
    progress: f64,
    error: String,
    /// Informational note about the job, which doesn't change its status
    message: String,
    /// Hash of the stabilization settings this job was queued with
    hash: String,
    /// What the job renders, its key in the queue together with the video: the id of a trim range (`uid` in its
    /// `trim_range_info`), or empty for the whole video (or all of its ranges joined)
    seq: String,
    /// The job is loading the video, before that it can't be removed from the queue or be the base of other jobs.
    /// `job_id` is 0 while the key has no job yet (see "Render queue keys")
    loading: bool
}
impl JobState {
    fn is_active(&self) -> bool { self.status == "queued" || self.status == "processing" || self.status == "rendering" }
    fn is_busy(&self) -> bool { self.status == "processing" || self.status == "rendering" }
}

#[derive(Default, Clone, Debug)]
struct Video {
    id: u32,
    url: String,
    filename: String,
    created_at: u64,
    duration_ms: f64,
    lens_profile: String,
    lens_warning: bool,
    timeline_markers: Vec<marker_import::TimelineMarker>,
    scanning: bool,
    scan_queued: bool,
    settings: Option<String>,
    output_path: String,
    /// Stabilization hash read from each existing output file, by its url (empty for files of older versions)
    output_hashes: std::collections::HashMap<String, String>,
    expanded: bool,
    selected: bool,
    /// One render job per output file
    jobs: Vec<JobState>,
    /// The files of a joined video (see `core::joined_video`), shown below it when it's expanded
    parts: Vec<JoinedPart>,
    /// Jobs of keys that were taken out of the queue, until the queue removed them (see "Render queue keys")
    retired: Vec<RetiredJob>
}

#[derive(Default, Clone, Debug)]
struct RetiredJob {
    job_id: u32,
    loading: bool
}

#[derive(Default, Clone, Debug)]
struct JoinedPart {
    /// Of its row, the part itself is not a video of the library
    id: u32,
    url: String,
    filename: String,
    duration_ms: f64
}

/// A file the video is exported to: one per trim range if they are exported as separate videos, otherwise one for the whole video
#[derive(Clone, Debug)]
struct OutputFile {
    range_index: i32,
    /// See `JobState::seq`
    seq: String,
    folder: String,
    filename: String,
    /// The trim range has its own stabilization settings
    own_settings: bool
}
impl OutputFile {
    fn url(&self) -> String { filesystem::get_file_url(&self.folder, &self.filename.replace("_%05d", "_00001"), false) }
}

#[derive(Default, Clone, Debug)]
struct Folder {
    id: u32,
    url: String,
    name: String,
    expanded: bool,
    videos: Vec<Video>
}

#[derive(Default, Debug)]
struct ScanResult {
    created_at: u64,
    duration_ms: f64,
    lens_profile: String,
    lens_warning: bool
}

/// The hash of the settings of every output file, by the url of its video and its trim range (-1: the whole video), see
/// `MediaLibrary::output_hash`. Shared with the render queue, which reads it while the library can be busy itself
pub type ExpectedHashes = Arc<parking_lot::Mutex<std::collections::HashMap<(String, i32), String>>>;

#[derive(Default, QObject)]
pub struct MediaLibrary {
    base: qt_base_class!(trait QObject),
    pub expected_hashes: ExpectedHashes,

    pub items: qt_property!(RefCell<SimpleListModel<MediaItem>>; NOTIFY items_changed),

    add_folder: qt_method!(fn(&mut self, url: QString)),
    add_files: qt_method!(fn(&mut self, urls: QStringList)),
    add_url: qt_method!(fn(&mut self, url: QString)),
    add_dropped: qt_method!(fn(&mut self, urls: QString)),
    remove_item: qt_method!(fn(&mut self, item_id: u32) -> QVariantList),
    remove_selected: qt_method!(fn(&mut self) -> QVariantList),
    get_removable_selection: qt_method!(fn(&self) -> QVariantList),
    clear: qt_method!(fn(&mut self)),
    has_folder: qt_method!(fn(&self, url: QString) -> bool),

    toggle_expanded: qt_method!(fn(&mut self, item_id: u32)),
    set_selected: qt_method!(fn(&mut self, item_id: u32, selected: bool)),
    select_only: qt_method!(fn(&mut self, item_id: u32)),
    toggle_selected: qt_method!(fn(&mut self, item_id: u32)),
    select_range: qt_method!(fn(&mut self, from_item_id: u32, to_item_id: u32)),
    select_all: qt_method!(fn(&mut self, selected: bool)),
    selected_count: qt_method!(fn(&self) -> usize),

    set_current_item: qt_method!(fn(&mut self, item_id: u32)),
    current_item: qt_property!(u32; NOTIFY current_item_changed),
    get_item_kind: qt_method!(fn(&self, item_id: u32) -> QString),
    get_adjacent_ranged_item: qt_method!(fn(&self, item_id: u32, forward: bool) -> u32),
    get_ranged_selection: qt_method!(fn(&self) -> QVariantList),
    get_trim_ranges: qt_method!(fn(&self, item_id: u32) -> QString),
    modify_trim_ranges: qt_method!(fn(&mut self, item_ids: QString, extend_left_ms: f64, extend_right_ms: f64, shift_ms: f64) -> i32),
    get_item_url: qt_method!(fn(&self, item_id: u32) -> QString),
    get_item_name: qt_method!(fn(&self, item_id: u32) -> QString),
    is_item_url: qt_method!(fn(&self, item_id: u32, url: QString) -> bool),
    find_by_url: qt_method!(fn(&self, url: QString) -> u32),
    get_item_index: qt_method!(fn(&self, item_id: u32) -> i32),

    load_markers: qt_method!(fn(&mut self, urls: QString) -> QString),
    preview_markers: qt_method!(fn(&self, offset_seconds: f64) -> QString),
    nearby_marker_matches: qt_method!(fn(&self, offset_seconds: f64) -> QString),
    import_markers: qt_method!(fn(&mut self, offset_seconds: f64) -> QString),
    get_timeline_markers: qt_method!(fn(&self, item_id: u32) -> QString),

    save_settings: qt_method!(fn(&mut self, item_id: u32, data: QString)),
    get_project_data: qt_method!(fn(&self, item_id: u32) -> QString),
    get_settings_for_job: qt_method!(fn(&self, job_id: u32) -> QString),
    get_range_settings: qt_method!(fn(&self, item_id: u32, range_index: i32) -> QString),
    apply_stabilization_to_all: qt_method!(fn(&mut self, data: QString, except_item_id: u32) -> usize),
    apply_settings_to_queued: qt_method!(fn(&mut self, data: QString) -> QVariantList),
    get_output_states: qt_method!(fn(&self, item_id: u32) -> QString),
    get_output_settings: qt_method!(fn(&self, item_id: u32) -> QString),

    get_output_path: qt_method!(fn(&self, item_id: u32) -> QString),
    resolve_output_path: qt_method!(fn(&self, item_id: u32, path: QString, ext: QString) -> QVariantList),
    get_output_folder: qt_method!(fn(&self, item_id: u32) -> QString),
    get_output_filename: qt_method!(fn(&self, item_id: u32, ext: QString) -> QString),
    set_output_path: qt_method!(fn(&mut self, item_id: u32, path: QString)),
    set_output_url: qt_method!(fn(&mut self, item_id: u32, folder: QString, filename: QString)),

    get_render_items: qt_method!(fn(&self, selected_only: bool) -> QVariantList),
    get_queueable_selection: qt_method!(fn(&self) -> QVariantList),
    get_queued_selection: qt_method!(fn(&self) -> QVariantList),
    is_item_queued: qt_method!(fn(&self, item_id: u32) -> bool),
    retain_jobs: qt_method!(fn(&mut self, job_ids: QVariantList)),
    set_item_job: qt_method!(fn(&mut self, item_id: u32, job_id: u32)),
    add_item_job: qt_method!(fn(&mut self, item_id: u32, job_id: u32, seq: QString)),
    enqueue: qt_method!(fn(&mut self, item_id: u32, seq: QString) -> bool),
    enqueue_all: qt_method!(fn(&mut self, item_id: u32)),
    dequeue: qt_method!(fn(&mut self, item_id: u32, seq: QString) -> bool),
    set_key_job: qt_method!(fn(&mut self, item_id: u32, seq: QString, job_id: u32, loading: bool)),
    job_loaded: qt_method!(fn(&mut self, job_id: u32)),
    forget_retired: qt_method!(fn(&mut self, item_id: u32, job_id: u32)),
    get_queue_work: qt_method!(fn(&self) -> QString),
    get_key_states: qt_method!(fn(&self, item_id: u32) -> QString),
    /// The keys or their jobs changed, the render queue has work to do (see `get_queue_work`)
    pub queue_keys_changed: qt_signal!(),
    /// The queue state of the keys of a video changed (see `get_key_states`)
    pub key_states_changed: qt_signal!(item_id: u32),
    reset_item_job_states: qt_method!(fn(&mut self, item_id: u32)),
    get_item_job_for_seq: qt_method!(fn(&self, item_id: u32, seq: QString) -> u32),
    get_job_seq: qt_method!(fn(&self, job_id: u32) -> QString),
    get_range_index_of_seq: qt_method!(fn(&self, item_id: u32, seq: QString) -> i32),
    get_seq_of_range: qt_method!(fn(&self, item_id: u32, range_index: i32) -> QString),
    get_item_job: qt_method!(fn(&self, item_id: u32) -> u32),
    get_item_jobs: qt_method!(fn(&self, item_id: u32) -> QVariantList),
    get_item_outputs: qt_method!(fn(&self, item_id: u32, ext: QString) -> QString),
    get_item_job_status: qt_method!(fn(&self, item_id: u32) -> QString),
    get_job_status: qt_method!(fn(&self, job_id: u32) -> QString),
    is_library_job: qt_method!(fn(&self, job_id: u32) -> bool),
    get_item_for_job: qt_method!(fn(&self, job_id: u32) -> u32),
    update_job_progress: qt_method!(fn(&mut self, job_id: u32, progress: f64, finished: bool)),
    set_job_processing: qt_method!(fn(&mut self, job_id: u32, progress: f64)),
    set_job_error: qt_method!(fn(&mut self, job_id: u32, err: QString)),
    set_job_error_string: qt_method!(fn(&mut self, job_id: u32, error_string: QString)),
    clear_job_statuses: qt_method!(fn(&mut self)),
    active_job_count: qt_method!(fn(&self) -> usize),

    refresh_outputs: qt_method!(fn(&mut self)),

    search_text: qt_property!(QString; WRITE set_search_text NOTIFY options_changed),
    sort_by_name: qt_property!(bool; WRITE set_sort_by_name NOTIFY options_changed),
    export_folder: qt_property!(QString; WRITE set_export_folder NOTIFY options_changed),
    default_suffix: qt_property!(QString; WRITE set_default_suffix),

    scanning: qt_property!(bool; NOTIFY scanning_changed),

    pub items_changed: qt_signal!(),
    pub options_changed: qt_signal!(),
    pub scanning_changed: qt_signal!(),
    pub current_item_changed: qt_signal!(),
    /// Split recordings were added, `names` lists the files of each one (a line per recording). The answer goes to
    /// `join_split_recordings`
    pub split_recordings_found: qt_signal!(names: QString),
    /// JSON `{ joined: [{ id, parts: [urls], replaced: [ids of the videos of its files] }], errors: [string] }`
    pub split_recordings_joined: qt_signal!(result: QString),
    join_split_recordings: qt_method!(fn(&mut self, join: bool)),

    standalone: Vec<Video>,
    folders: Vec<Folder>,

    next_id: u32,
    pending_scans: Arc<AtomicUsize>,
    /// Split recordings the user is asked about (the urls of their files)
    pending_joins: Vec<Vec<String>>,
    /// Videos added since the last search for split recordings, the only ones it looks at: the user isn't asked again
    /// about the files they kept separate whenever something else is added
    added_since_detect: Vec<String>,
    markers: Vec<marker_import::Marker>,
    marker_file_loaded: bool,

    stabilizer: Arc<StabilizationManager>,
}

impl MediaLibrary {
    pub fn new(stabilizer: Arc<StabilizationManager>) -> Self {
        Self {
            default_suffix: QString::from("_stabilized"),
            next_id: 1,
            stabilizer,
            ..Default::default()
        }
    }

    // ---------------------------------------------------------------------------------------------
    // ------------------------------------------ Model --------------------------------------------
    // ---------------------------------------------------------------------------------------------

    fn matches_search(&self, v: &Video) -> bool {
        let search = self.search_text.to_string().to_lowercase();
        if search.is_empty() { return true; }
        if v.filename.to_lowercase().contains(&search) { return true; }
        if v.timeline_markers.iter().any(|m| m.name.to_lowercase().contains(&search)) { return true; }
        self.outputs(v, None).iter().any(|x| x.filename.to_lowercase().contains(&search))
    }

    fn sorted_videos<'a>(&self, videos: &'a [Video]) -> Vec<&'a Video> {
        let mut ret = videos.iter().filter(|v| self.matches_search(v)).collect::<Vec<_>>();
        if self.sort_by_name {
            ret.sort_by(|a, b| human_sort::compare(&a.filename, &b.filename));
        } else {
            ret.sort_by(|a, b| a.created_at.cmp(&b.created_at).then_with(|| human_sort::compare(&a.filename, &b.filename)));
        }
        ret
    }

    fn video_to_item(&self, v: &Video, parent_id: u32, depth: i32) -> MediaItem {
        let (folder, filename) = self.resolve_output(&v.url, &v.output_path, &v.settings, None);
        let outputs = self.outputs(v, None);
        let job = Self::job_summary(&v.jobs);
        MediaItem {
            item_id: v.id,
            parent_id,
            kind: QString::from("video"),
            depth,
            // A joined video is named like the recording, the camera named its first file
            name: QString::from(v.parts.first().map(|x| x.filename.as_str()).unwrap_or(v.filename.as_str())),
            url: QString::from(v.url.as_str()),
            output_path: QString::from(self.output_path_or_default(&v.url, &v.output_path)),
            display_output_path: QString::from(match outputs.as_slice() {
                [one] => filesystem::display_folder_filename(&one.folder, &one.filename),
                _ => filesystem::display_folder_filename(&folder, &filename)
            }),
            expanded: v.expanded,
            has_children: !v.parts.is_empty(),
            selected: v.selected,
            is_current: self.current_item == v.id,
            created_at: v.created_at,
            duration_ms: v.duration_ms,
            range_count: Self::range_info(&v.settings).0 as i32,
            output_count: outputs.len() as i32,
            lens_profile: QString::from(v.lens_profile.as_str()),
            lens_warning: v.lens_warning,
            scanning: v.scanning,
            stabilized_state: self.stabilized_state(v, &outputs),
            job_status: QString::from(job.status.as_str()),
            job_progress: job.progress,
            error_string: QString::from(job.error.as_str()),
            job_message: QString::from(job.message.as_str()),
            job_id: job.job_id,
            job_count: v.jobs.len() as i32,
            part_count: v.parts.len() as i32,
            ..self.queue_display(v)
        }
    }
    /// The queue state shown on the row of the video (see `MediaItem::queue_state` and `range_bar`)
    fn queue_display(&self, v: &Video) -> MediaItem {
        let state = |seq: &str| v.jobs.iter().find(|x| x.seq == seq).map(Self::key_state).unwrap_or_default();
        let available = self.available_seqs(v);
        let queued = available.iter().filter(|seq| v.jobs.iter().any(|x| &x.seq == *seq)).count();
        let obj = v.settings.as_ref().and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok()).unwrap_or_default();
        let ranges = Self::trim_ranges_ms(&obj);
        let joined = available.len() == 1 && available[0].is_empty();
        let outputs = self.outputs(v, None);
        let output_state = |seq: &str| outputs.iter().find(|x| x.seq == seq).map(|x| Self::output_state_name(Self::output_state(v, x))).unwrap_or_default();
        let bar = if ranges.is_empty() || v.duration_ms <= 0.0 { String::new() } else {
            serde_json::json!(ranges.iter().enumerate().map(|(i, r)| {
                // Joined into one video, all ranges are in the queue with it
                let seq = if joined { String::new() } else { Self::range_uid(&obj, i) };
                let end = if r.1 < 0.0 { v.duration_ms + r.1 } else { r.1 };
                serde_json::json!([(r.0 / v.duration_ms).clamp(0.0, 1.0), (end / v.duration_ms).clamp(0.0, 1.0), state(&seq), output_state(&seq)])
            }).collect::<Vec<_>>()).to_string()
        };
        MediaItem {
            queue_state: QString::from(if queued == 0 { "" } else if queued == available.len() { "all" } else { "some" }),
            queued_count: queued as i32,
            key_count: available.len() as i32,
            range_bar: QString::from(bar),
            ..Default::default()
        }
    }
    /// The state of a key as the UI shows it, see `get_key_states`
    fn key_state(x: &JobState) -> String {
        if x.job_id == 0 || x.loading || x.status.is_empty() { "queued".into() } else { x.status.clone() }
    }
    /// The state of all jobs of a video, shown on its row: the first error or question, otherwise the furthest one in progress
    fn job_summary(jobs: &[JobState]) -> JobState {
        let Some(first) = jobs.first() else { return JobState::default(); };
        let rank = |status: &str| match status { "error" => 6, "question" => 5, "rendering" => 4, "processing" => 3, "queued" => 2, "done" => 1, _ => 0 };
        let mut ret = jobs.iter().max_by_key(|x| rank(&x.status)).cloned().unwrap_or_default();
        // A video with some of its files done and others still queued is still queued
        if ret.status == "done" && jobs.iter().any(|x| x.status != "done") { ret.status = "queued".into(); }
        ret.progress = jobs.iter().map(|x| if x.status == "done" { 1.0 } else { x.progress }).sum::<f64>() / jobs.len() as f64;
        ret.message = jobs.iter().map(|x| x.message.as_str()).find(|x| !x.is_empty()).unwrap_or_default().to_owned();
        // An error or a question is answered for the job that has it, everything else is about the video
        if ret.status != "error" && ret.status != "question" { ret.job_id = first.job_id; }
        ret
    }
    /// Updates the job state shown on the row of the video
    fn update_job_row(&mut self, video_id: u32) {
        let Some(v) = self.video(video_id) else { return; };
        let job = Self::job_summary(&v.jobs);
        let count = v.jobs.len() as i32;
        let queue = self.queue_display(v);
        let stabilized = self.stabilized_state(v, &self.outputs(v, None));
        {
            let mut hashes = self.expected_hashes.lock();
            hashes.retain(|k, _| k.0 != v.url);
            self.store_expected_hashes(&mut hashes, v);
        }
        self.patch_row(video_id, |x| {
            x.stabilized_state = stabilized;
            x.queue_state = queue.queue_state;
            x.queued_count = queue.queued_count;
            x.key_count = queue.key_count;
            x.range_bar = queue.range_bar;
            x.job_id = job.job_id;
            x.job_count = count;
            x.job_status = QString::from(job.status.as_str());
            x.job_progress = job.progress;
            x.error_string = QString::from(job.error.as_str());
            x.job_message = QString::from(job.message.as_str());
        });
    }

    fn build_items(&self) -> Vec<MediaItem> {
        let mut ret = Vec::new();
        let add_video = |ret: &mut Vec<MediaItem>, v: &Video, parent_id: u32, depth: i32| {
            ret.push(self.video_to_item(v, parent_id, depth));
            if v.expanded {
                for x in &v.parts {
                    ret.push(MediaItem {
                        item_id: x.id,
                        parent_id: v.id,
                        kind: QString::from("part"),
                        depth: depth + 1,
                        name: QString::from(x.filename.as_str()),
                        url: QString::from(x.url.as_str()),
                        duration_ms: x.duration_ms,
                        ..Default::default()
                    });
                }
            }
        };

        for v in self.sorted_videos(&self.standalone) {
            add_video(&mut ret, v, 0, 0);
        }
        let search = self.search_text.to_string().to_lowercase();
        for f in &self.folders {
            let videos = self.sorted_videos(&f.videos);
            if !search.is_empty() && videos.is_empty() && !f.name.to_lowercase().contains(&search) { continue; }
            ret.push(MediaItem {
                item_id: f.id,
                kind: QString::from("folder"),
                name: QString::from(f.name.as_str()),
                url: QString::from(f.url.as_str()),
                display_output_path: QString::from(filesystem::display_url(&f.url)),
                expanded: f.expanded,
                has_children: !f.videos.is_empty(),
                selected: Self::is_folder_selected(f),
                ..Default::default()
            });
            if f.expanded {
                for v in videos {
                    add_video(&mut ret, v, f.id, 1);
                }
            }
        }
        ret
    }

    /// Updates the rows in place where it can, instead of resetting the model: after a reset the list creates every row
    /// again, and dropping files did that for every file and again after every scan, which froze the UI for seconds
    fn rebuild(&mut self) {
        {
            let mut hashes = self.expected_hashes.lock();
            hashes.clear();
            for v in self.all_videos() { self.store_expected_hashes(&mut hashes, v); }
        }
        let items = self.build_items();
        {
            let mut q = self.items.borrow_mut();
            let new_ids = items.iter().map(|x| x.item_id).collect::<std::collections::HashSet<_>>();
            let mut i = 0;
            while i < q.row_count() as usize {
                if new_ids.contains(&q[i].item_id) { i += 1; } else { q.remove(i); }
            }
            // Then row by row: unchanged rows stay as they are, new ones are inserted, and only the rows that moved (eg.
            // sorted by the creation time the scan read) are created again
            for (i, itm) in items.into_iter().enumerate() {
                if i < q.row_count() as usize && q[i].item_id == itm.item_id {
                    if q[i] != itm { q.change_line(i, itm); }
                    continue;
                }
                if let Some(j) = (i + 1..q.row_count() as usize).find(|&j| q[j].item_id == itm.item_id) {
                    q.remove(j);
                }
                q.insert(i, itm);
            }
        }
        self.items_changed();
    }

    fn patch_row<F: FnOnce(&mut MediaItem)>(&self, item_id: u32, cb: F) {
        if let Ok(mut q) = self.items.try_borrow_mut() {
            for i in 0..q.row_count() as usize {
                if q[i].item_id == item_id {
                    let mut itm = q[i].clone();
                    cb(&mut itm);
                    q.change_line(i, itm);
                    break;
                }
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // ------------------------------------------ Lookups ------------------------------------------
    // ---------------------------------------------------------------------------------------------

    fn all_videos(&self) -> impl Iterator<Item = &Video> {
        self.standalone.iter().chain(self.folders.iter().flat_map(|f| f.videos.iter()))
    }
    fn all_videos_mut(&mut self) -> impl Iterator<Item = &mut Video> {
        self.standalone.iter_mut().chain(self.folders.iter_mut().flat_map(|f| f.videos.iter_mut()))
    }
    fn video(&self, id: u32) -> Option<&Video> {
        self.all_videos().find(|v| v.id == id)
    }
    fn video_mut(&mut self, id: u32) -> Option<&mut Video> {
        self.all_videos_mut().find(|v| v.id == id)
    }
    fn new_id(&mut self) -> u32 {
        self.next_id += 1;
        self.next_id
    }

    /// Url, settings and output path of a video
    fn item_settings(&self, item_id: u32) -> Option<(&str, &Option<String>, &str)> {
        self.video(item_id).map(|v| (v.url.as_str(), &v.settings, v.output_path.as_str()))
    }

    // ---------------------------------------------------------------------------------------------
    // ------------------------------------------ Adding -------------------------------------------
    // ---------------------------------------------------------------------------------------------

    pub fn is_video_file(filename: &str) -> bool {
        // Hidden files, eg. the `._` files macOS writes next to every file on a memory card, which only hold its metadata
        if filename.starts_with('.') { return false; }
        if let Some(pos) = filename.rfind('.') {
            let ext = filename[pos + 1..].to_ascii_lowercase();
            return VIDEO_EXTENSIONS.contains(&ext.as_str());
        }
        false
    }

    fn to_url(url: &str, is_folder: bool) -> String {
        if url.contains("://") {
            filesystem::normalize_url(url, is_folder)
        } else {
            filesystem::normalize_url(&filesystem::path_to_url(url), is_folder)
        }
    }

    pub fn has_folder(&self, url: QString) -> bool {
        let url = Self::to_url(&url.to_string(), true);
        self.folders.iter().any(|f| f.url == url)
    }

    pub fn add_folder(&mut self, url: QString) {
        let url = Self::to_url(&url.to_string(), true);
        if url.is_empty() || self.folders.iter().any(|f| f.url == url) { return; }

        let mut videos = Vec::new();
        for (filename, file_url) in filesystem::list_folder(&url) {
            if Self::is_video_file(&filename) && !self.all_videos().any(|v| v.url == file_url) {
                videos.push(self.new_video(file_url, filename));
            }
        }
        // The files of a split recording joined before are shown below it
        let part_urls = videos.iter().flat_map(|v| v.parts.iter().map(|x| x.url.clone())).collect::<std::collections::HashSet<_>>();
        videos.retain(|v| !part_urls.contains(&v.url));
        let id = self.new_id();
        let path = filesystem::url_to_path(&url);
        let mut name = path.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or_default().to_string();
        if name.is_empty() { name = filesystem::display_url(&url); }
        self.folders.push(Folder { id, url, name, expanded: true, videos });
        self.rebuild();
        self.scan_pending();
        self.detect_split_recordings();
    }

    pub fn add_files(&mut self, urls: QStringList) {
        let n = urls.len();
        for i in 0..n {
            self.add_url_impl(&urls[i].to_string(), false);
        }
        self.remove_joined_parts();
        self.rebuild();
        self.scan_pending();
        self.detect_split_recordings();
    }

    /// One file or folder. QML should call this instead of passing a JS array as QStringList,
    /// which qmetaobject turns into empty strings.
    pub fn add_url(&mut self, url: QString) {
        self.add_url_impl(&url.to_string(), true);
    }

    /// Adds dropped urls, one per line (see `add_url` why not a list): folders are added as input folders and files as
    /// standalone videos. All of them at once, so the list is updated once and they are scanned in one task, instead of
    /// one per file, which each took a thread of the pool (that loading the clicked video needs) only to wait for the others
    pub fn add_dropped(&mut self, urls: QString) {
        for url in urls.to_string().lines() {
            self.add_url_impl(url, false);
        }
        self.remove_joined_parts();
        self.rebuild();
        self.scan_pending();
        self.detect_split_recordings();
    }

    fn add_url_impl(&mut self, url_str: &str, rebuild: bool) {
        let url_str = url_str.trim();
        if url_str.is_empty() { return; }
        let path = filesystem::url_to_path(&Self::to_url(url_str, false));
        if !path.is_empty() && std::path::Path::new(&path).is_dir() {
            self.add_folder(QString::from(url_str));
            return;
        }
        let url = Self::to_url(url_str, false);
        let filename = filesystem::get_filename(&url);
        if url.is_empty() || !Self::is_video_file(&filename) { return; }
        if self.all_videos().any(|v| v.url == url) { return; }
        let video = self.new_video(url, filename);
        self.standalone.push(video);
        if rebuild {
            self.remove_joined_parts();
            self.rebuild();
            self.scan_pending();
            self.detect_split_recordings();
        }
    }

    /// The files of a joined video are listed below it and not on their own, also when they were added together with it
    /// (eg. all files of a folder dropped at once) or one of them was added again
    fn remove_joined_parts(&mut self) {
        let part_urls = self.all_videos().flat_map(|v| v.parts.iter().map(|x| x.url.clone())).collect::<std::collections::HashSet<_>>();
        if part_urls.is_empty() { return; }
        self.standalone.retain(|v| !part_urls.contains(&v.url));
        for f in self.folders.iter_mut() {
            f.videos.retain(|v| !part_urls.contains(&v.url));
        }
    }

    fn new_video(&mut self, url: String, filename: String) -> Video {
        let id = self.new_id();
        self.added_since_detect.push(url.clone());
        let parts = if core::joined_video::is_joined(&url) {
            core::joined_video::read(&url).unwrap_or_default().into_iter().map(|x| self.new_part(x)).collect()
        } else {
            Vec::new()
        };
        Video {
            id,
            url,
            filename,
            scanning: true,
            // The files of a joined video are listed only on request
            expanded: parts.is_empty(),
            parts,
            ..Default::default()
        }
    }
    fn new_part(&mut self, part: core::joined_video::Part) -> JoinedPart {
        JoinedPart { id: self.new_id(), filename: filesystem::get_filename(&part.url), url: part.url, duration_ms: part.duration_ms }
    }

    // ---------------------------------------------------------------------------------------------
    // ------------------------------------- Split recordings --------------------------------------
    // ---------------------------------------------------------------------------------------------

    /// The recording a file is a part of and the number of the part, for the cameras that split long recordings into
    /// files of a few GB (the names `detectVideoSequence` in VideoArea.qml knows)
    fn split_recording_part(filename: &str) -> Option<(String, u32)> {
        let upper = filename.to_ascii_uppercase();
        let stem = upper.strip_suffix(".MP4")?;
        let digits = |x: &str| !x.is_empty() && x.bytes().all(|c| c.is_ascii_digit());
        if stem.len() == 8 {
            // GoPro HERO6 and newer: GX or GH, the part and the recording number, eg. GX012209, GX022209
            if (stem.starts_with("GX") || stem.starts_with("GH")) && digits(&stem[2..]) {
                return Some((format!("{}{}", &stem[..2], &stem[4..]), stem[2..4].parse().ok()?));
            }
            // GoPro HERO5 and older: GOPR and the recording number, then GP, the part and the recording number
            if stem.starts_with("GOPR") && digits(&stem[4..]) { return Some((format!("GP{}", &stem[4..]), 0)); }
            if stem.starts_with("GP") && digits(&stem[2..]) { return Some((format!("GP{}", &stem[4..]), stem[2..4].parse().ok()?)); }
        }
        // DJI Action: DJI_, the recording number and the part, eg. DJI_0012_001
        let (recording, part) = stem.strip_prefix("DJI_")?.split_once('_')?;
        if recording.len() == 4 && part.len() == 3 && digits(recording) && digits(part) {
            return Some((format!("DJI_{recording}"), part.parse().ok()?));
        }
        None
    }

    /// Newer DJI cameras (eg. Osmo Action 4) name every file after the time it starts and a counter, also the files
    /// of a split recording: DJI_20261005132932_0003_D.MP4, DJI_20261005133310_0004_D.MP4. Returns the kind of
    /// recording (the letter at the end), the counter and the start time in seconds. The files only tell they are
    /// one recording by the next one starting where the previous one ends (see `dji_split_recordings`)
    fn dji_dated_part(filename: &str) -> Option<(String, u32, i64)> {
        let upper = filename.to_ascii_uppercase();
        let stem = upper.strip_suffix(".MP4")?;
        let mut it = stem.strip_prefix("DJI_")?.splitn(3, '_');
        let (time, counter, kind) = (it.next()?, it.next()?, it.next().unwrap_or_default());
        if time.len() != 14 || counter.len() != 4 || !counter.bytes().all(|c| c.is_ascii_digit()) { return None; }
        let start = chrono::NaiveDateTime::parse_from_str(time, "%Y%m%d%H%M%S").ok()?.and_utc().timestamp();
        Some((kind.to_string(), counter.parse().ok()?, start))
    }

    /// The duration of an MP4 file from its header (`mvhd`), a few small reads instead of opening the whole video
    fn mp4_duration_ms(url: &str) -> Option<f64> {
        use std::io::{ Read, Seek, SeekFrom };
        let mut file = filesystem::open_file(url, false, false).ok()?;
        let file_size = file.size as u64;
        let file = file.get_file();
        let (mut pos, mut end) = (0u64, file_size);
        while pos + 8 <= end {
            file.seek(SeekFrom::Start(pos)).ok()?;
            let mut header = [0u8; 8];
            file.read_exact(&mut header).ok()?;
            let mut size = u32::from_be_bytes(header[0..4].try_into().ok()?) as u64;
            let mut header_size = 8;
            if size == 1 {
                let mut large = [0u8; 8];
                file.read_exact(&mut large).ok()?;
                size = u64::from_be_bytes(large);
                header_size = 16;
            } else if size == 0 {
                size = end - pos;
            }
            if size < header_size { return None; }
            match &header[4..8] {
                b"moov" => { end = (pos + size).min(end); pos += header_size; }
                b"mvhd" => {
                    let mut buf = [0u8; 32];
                    file.read_exact(&mut buf).ok()?;
                    let (timescale, duration) = if buf[0] == 1 {
                        (u32::from_be_bytes(buf[20..24].try_into().ok()?), u64::from_be_bytes(buf[24..32].try_into().ok()?))
                    } else {
                        (u32::from_be_bytes(buf[12..16].try_into().ok()?), u32::from_be_bytes(buf[16..20].try_into().ok()?) as u64)
                    };
                    return (timescale > 0).then(|| duration as f64 * 1000.0 / timescale as f64);
                }
                _ => pos += size,
            }
        }
        None
    }

    /// The split recordings of the newer DJI cameras in the files of a folder (see `dji_dated_part`), the ones with any of `added`
    fn dji_split_recordings(&self, files: &[(String, String)], added: &std::collections::HashSet<String>) -> Vec<Vec<String>> {
        let mut kinds = std::collections::BTreeMap::<String, std::collections::BTreeMap<u32, (i64, String)>>::new();
        for (filename, url) in files {
            if let Some((kind, counter, start)) = Self::dji_dated_part(filename) {
                kinds.entry(kind).or_default().insert(counter, (start, url.clone()));
            }
        }
        let mut found = Vec::new();
        for parts in kinds.into_values() {
            let mut chain: Vec<String> = Vec::new();
            let mut prev: Option<(u32, i64, &String)> = None;
            for (counter, (start, url)) in &parts {
                // The next file of the recording starts when the previous one ends: the time in the name is in whole seconds,
                // a new recording started by hand takes longer than that
                let continues = prev.is_some_and(|(prev_counter, prev_start, prev_url)| {
                    if prev_counter + 1 != *counter || *start <= prev_start { return false; }
                    let duration_ms = self.all_videos().find(|v| &v.url == prev_url && v.duration_ms > 0.0).map(|v| v.duration_ms)
                        .or_else(|| Self::mp4_duration_ms(prev_url));
                    duration_ms.is_some_and(|d| ((*start - prev_start) as f64 - d / 1000.0).abs() <= 2.0)
                });
                if !continues {
                    if chain.len() > 1 && chain.iter().any(|x| added.contains(x)) { found.push(std::mem::take(&mut chain)); }
                    chain.clear();
                }
                chain.push(url.clone());
                prev = Some((*counter, *start, url));
            }
            if chain.len() > 1 && chain.iter().any(|x| added.contains(x)) { found.push(chain); }
        }
        found
    }

    /// Finds the split recordings among the videos that were just added, with the other files of them in their folder,
    /// and asks the user whether to join them (`split_recordings_found`)
    fn detect_split_recordings(&mut self) {
        let added = std::mem::take(&mut self.added_since_detect).into_iter().collect::<std::collections::HashSet<_>>();
        let mut recordings = std::collections::BTreeMap::<String, std::collections::BTreeMap<u32, String>>::new();
        let mut folders = std::collections::HashMap::<String, Vec<(String, String)>>::new();
        let mut dji_folders = std::collections::HashSet::<String>::new();
        for v in self.all_videos().filter(|v| added.contains(&v.url)) {
            let folder = filesystem::get_folder(&v.url);
            if Self::dji_dated_part(&v.filename).is_some() {
                folders.entry(folder.clone()).or_insert_with(|| filesystem::list_folder(&folder));
                dji_folders.insert(folder);
                continue;
            }
            let Some((name, _)) = Self::split_recording_part(&v.filename) else { continue; };
            let key = format!("{folder}|{name}");
            if recordings.contains_key(&key) { continue; }
            let files = folders.entry(folder.clone()).or_insert_with(|| filesystem::list_folder(&folder));
            let parts = files.iter().filter_map(|(filename, url)| {
                let (n, i) = Self::split_recording_part(filename)?;
                (n == name).then(|| (i, url.clone()))
            }).collect();
            recordings.insert(key, parts);
        }
        let mut recordings = recordings.into_values().map(|parts| {
            // The parts are numbered one after another, from the first one on
            let mut files = Vec::new();
            for (i, url) in parts {
                if files.is_empty() || parts_continue(&files, i) { files.push((i, url)); } else { break; }
            }
            files.into_iter().map(|x| x.1).collect::<Vec<_>>()
        }).collect::<Vec<_>>();
        for folder in &dji_folders {
            recordings.extend(self.dji_split_recordings(&folders[folder], &added));
        }
        let mut found = Vec::new();
        for files in recordings {
            if files.len() < 2 || self.pending_joins.iter().any(|x| x[0] == files[0]) { continue; }
            // Already joined (eg. one of its files was added again)
            if self.all_videos().any(|v| v.parts.first().is_some_and(|x| x.url == files[0])) { continue; }
            found.push(files);
        }
        fn parts_continue(files: &[(u32, String)], i: u32) -> bool { files.last().is_some_and(|x| x.0 + 1 == i) }
        if found.is_empty() { return; }
        let names = found.iter().map(|x| x.iter().map(|url| filesystem::get_filename(url)).collect::<Vec<_>>().join(", ")).collect::<Vec<_>>().join("\n");
        self.pending_joins.extend(found);
        self.split_recordings_found(QString::from(names));
    }

    /// The answer to `split_recordings_found`: joining writes the list of the files next to them, and the joined video
    /// takes the place of its files in the library
    pub fn join_split_recordings(&mut self, join: bool) {
        let recordings = std::mem::take(&mut self.pending_joins);
        if !join { return; }
        let finished = util::qt_queued_callback_mut(QPointer::from(self as &Self), move |this, result: Vec<Result<(String, Vec<core::joined_video::Part>), String>>| {
            this.add_joined(result);
        });
        core::run_threaded(move || {
            finished(recordings.into_iter().map(|files| -> Result<_, String> {
                let parts = files.iter().map(|url| {
                    let info = rendering::VideoProcessor::get_video_info(url).map_err(|e| format!("{}: {e:?}", filesystem::get_filename(url)))?;
                    Ok(core::joined_video::Part { url: url.clone(), duration_ms: info.duration_ms })
                }).collect::<Result<Vec<_>, String>>()?;
                let filename = filesystem::filename_with_extension(&filesystem::filename_with_suffix(&filesystem::get_filename(&files[0]), "_joined"), core::joined_video::EXTENSION);
                let url = core::joined_video::write(&filesystem::get_folder(&files[0]), &filename, &parts).map_err(|e| format!("{filename}: {e}"))?;
                crate::util::update_file_times(&url, &files[0], None);
                Ok((url, parts))
            }).collect());
        });
    }

    fn add_joined(&mut self, result: Vec<Result<(String, Vec<core::joined_video::Part>), String>>) {
        let mut joined = Vec::new();
        let mut errors = Vec::new();
        for x in result {
            let (url, parts) = match x { Ok(x) => x, Err(e) => { errors.push(e); continue; } };
            let part_urls = parts.iter().map(|x| x.url.clone()).collect::<Vec<_>>();
            let replaced = self.all_videos().filter(|v| part_urls.contains(&v.url)).map(|v| v.id).collect::<Vec<_>>();
            let mut video = self.new_video(url.clone(), filesystem::get_filename(&url));
            if video.parts.is_empty() { video.parts = parts.into_iter().map(|x| self.new_part(x)).collect(); video.expanded = false; }
            // In place of its first file: in its folder, or among the files added alone
            let mut placed = false;
            for f in self.folders.iter_mut() {
                if !placed && f.videos.iter().any(|v| v.url == part_urls[0]) { f.videos.push(video.clone()); placed = true; }
                f.videos.retain(|v| !part_urls.contains(&v.url));
            }
            if !placed { self.standalone.push(video.clone()); }
            self.standalone.retain(|v| !part_urls.contains(&v.url));
            joined.push(serde_json::json!({ "id": video.id, "parts": part_urls, "replaced": replaced }));
        }
        if self.current_item > 0 && self.video(self.current_item).is_none() && self.folders.iter().all(|f| f.id != self.current_item) {
            self.current_item = 0;
            self.current_item_changed();
        }
        self.rebuild();
        self.scan_pending();
        self.split_recordings_joined(QString::from(serde_json::json!({ "joined": joined, "errors": errors }).to_string()));
    }

    pub fn remove_item(&mut self, item_id: u32) -> QVariantList {
        self.remove_ids(&[item_id])
    }
    /// A selected folder is removed as a whole, so it isn't left empty
    pub fn get_removable_selection(&self) -> QVariantList {
        QVariantList::from_iter(self.removable_selection())
    }
    pub fn remove_selected(&mut self) -> QVariantList {
        let ids = self.removable_selection();
        self.remove_ids(&ids)
    }
    fn video_busy(v: &Video) -> bool {
        v.jobs.iter().any(|x| x.is_busy())
    }
    fn removable_selection(&self) -> Vec<u32> {
        let mut ids = Vec::new();
        for f in &self.folders {
            if Self::is_folder_selected(f) && !f.videos.iter().any(Self::video_busy) {
                ids.push(f.id);
                continue;
            }
            for v in &f.videos {
                Self::push_removable_video(&mut ids, v);
            }
        }
        for v in &self.standalone {
            Self::push_removable_video(&mut ids, v);
        }
        ids
    }
    fn push_removable_video(ids: &mut Vec<u32>, v: &Video) {
        if v.selected && !Self::video_busy(v) {
            ids.push(v.id);
        }
    }
    fn collect_video_jobs(v: &Video, job_ids: &mut Vec<u32>) {
        job_ids.extend(v.jobs.iter().map(|x| x.job_id).filter(|x| *x > 0));
        job_ids.extend(v.retired.iter().map(|x| x.job_id));
    }
    fn remove_ids(&mut self, ids: &[u32]) -> QVariantList {
        if ids.is_empty() { return QVariantList::default(); }
        let idset: std::collections::HashSet<u32> = ids.iter().copied().collect();
        let mut job_ids = Vec::new();

        for f in &self.folders {
            if idset.contains(&f.id) {
                for v in &f.videos { Self::collect_video_jobs(v, &mut job_ids); }
            }
        }
        for v in self.all_videos() {
            if idset.contains(&v.id) {
                Self::collect_video_jobs(v, &mut job_ids);
            }
        }

        self.folders.retain(|f| !idset.contains(&f.id));
        self.standalone.retain(|v| !idset.contains(&v.id));
        for f in self.folders.iter_mut() {
            f.videos.retain(|v| !idset.contains(&v.id));
        }

        if self.current_item > 0
            && self.folders.iter().all(|f| f.id != self.current_item)
            && self.video(self.current_item).is_none()
        {
            self.current_item = 0;
            self.current_item_changed();
        }
        self.rebuild();
        QVariantList::from_iter(job_ids)
    }

    pub fn clear(&mut self) {
        self.standalone.clear();
        self.folders.clear();
        self.current_item = 0;
        self.current_item_changed();
        self.rebuild();
    }

    // ---------------------------------------------------------------------------------------------
    // ----------------------------------------- Scanning ------------------------------------------
    // ---------------------------------------------------------------------------------------------

    fn scan_pending(&mut self) {
        let urls = self.all_videos_mut().filter(|v| v.scanning && !v.scan_queued).map(|v| {
            v.scan_queued = true;
            (v.id, v.url.clone())
        }).collect::<Vec<_>>();
        if urls.is_empty() { return; }

        self.pending_scans.fetch_add(urls.len(), SeqCst);
        self.scanning = true;
        self.scanning_changed();

        let lens_db = self.stabilizer.lens_profile_db.clone();
        let pending = self.pending_scans.clone();

        let scanned = util::qt_queued_callback_mut(QPointer::from(self as &Self), move |this, (video_id, result): (u32, ScanResult)| {
            if let Some(v) = this.video_mut(video_id) {
                v.created_at   = result.created_at;
                v.duration_ms  = result.duration_ms;
                v.lens_profile = result.lens_profile;
                v.lens_warning = result.lens_warning;
                v.scanning     = false;
            }
            if let Some(v) = this.video(video_id).cloned() {
                let itm = this.video_to_item(&v, 0, 0);
                this.patch_row(video_id, |x| {
                    x.created_at   = itm.created_at;
                    x.duration_ms  = itm.duration_ms;
                    x.lens_profile = itm.lens_profile;
                    x.lens_warning = itm.lens_warning;
                    x.scanning     = false;
                });
            }
        });
        let finished = util::qt_queued_callback_mut(QPointer::from(self as &Self), move |this, _: ()| {
            if this.pending_scans.load(SeqCst) == 0 {
                this.scanning = false;
                this.scanning_changed();
            }
            this.rebuild();
            this.refresh_outputs();
        });

        // Every add_url call starts its own scan, and dropping many files would then read all of them at once.
        // A memory card serves one read at a time, so the parallel scans only got slower each, one after another is faster.
        static SCAN_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

        core::run_threaded(move || {
            let _lock = SCAN_LOCK.lock();
            for (video_id, url) in urls {
                let mut result = ScanResult::default();
                let mut size = (0, 0);
                let mut fps = 0.0;
                if let Ok(info) = rendering::VideoProcessor::get_video_info(&url) {
                    result.created_at  = info.created_at.unwrap_or_default();
                    result.duration_ms = info.duration_ms;
                    size = (info.width as usize, info.height as usize);
                    fps = info.fps;
                }
                result.lens_warning = true;
                if size.0 > 0 && fps > 0.0 {
                    // The camera and lens of a joined video are the ones of its first file
                    let url = if core::joined_video::is_joined(&url) {
                        core::joined_video::read(&url).ok().and_then(|x| x.first().map(|x| x.url.clone())).unwrap_or(url.clone())
                    } else {
                        url.clone()
                    };
                    if let Ok(mut file) = filesystem::open_file(&url, false, false) {
                        let filesize = file.size;
                        // Only the lens is shown here, so the first metadata sample is usually enough. Reading all of them
                        // (the motion) is left to loading the video, unless the beginning alone doesn't tell the lens.
                        let md = core::gyro_source::GyroSource::probe_telemetry_file(file.get_file(), filesize, &url, size, fps);
                        let found = md.ok().and_then(|md| Self::scanned_lens_profile(&md, &lens_db));
                        let found = found.or_else(|| {
                            let md = core::gyro_source::GyroSource::parse_telemetry_file(file.get_file(), filesize, &url, &Default::default(), size, fps, |_| (), Arc::new(AtomicBool::new(false)));
                            md.ok().and_then(|md| Self::scanned_lens_profile(&md, &lens_db))
                        });
                        if let Some(name) = found {
                            result.lens_profile = name;
                            result.lens_warning = false;
                        }
                    }
                }
                pending.fetch_sub(1, SeqCst);
                scanned((video_id, result));
            }
            finished(());
        });
    }

    /// The name of the lens profile the video would load: its built-in one, or the one matching the camera in the database
    fn scanned_lens_profile(md: &core::gyro_source::FileMetadata, lens_db: &Arc<parking_lot::RwLock<core::lens_profile_database::LensProfileDatabase>>) -> Option<String> {
        if md.lens_profile.as_ref().map(|x| x.is_object()).unwrap_or_default() {
            return Some("Built-in".to_string());
        }
        let id_str = md.camera_identifier.as_ref().map(|x| x.get_identifier_for_autoload()).unwrap_or_default();
        if id_str.is_empty() { return None; }
        {
            let db = lens_db.read();
            if !db.loaded { drop(db); lens_db.write().load_all(); }
        }
        lens_db.read().get_by_id(&id_str).map(|profile| profile.get_display_name())
    }

    /// Checks which of the output files already exist and reads the stabilization hash from them
    pub fn refresh_outputs(&mut self) {
        let to_check = self.all_videos().map(|v| (v.id, self.outputs(v, None).iter().map(|x| x.url()).collect::<Vec<_>>())).collect::<Vec<_>>();
        if to_check.is_empty() { return; }

        let checked = util::qt_queued_callback_mut(QPointer::from(self as &Self), move |this, (video_id, hashes): (u32, Vec<(String, Option<String>)>)| {
            let Some(v) = this.video(video_id) else { return; };
            let outputs = this.outputs(v, None);
            let output_hashes = hashes.into_iter().filter_map(|(url, hash): (String, Option<String>)| {
                let mut hash = hash?;
                if hash.is_empty() {
                    // Without a hash in the file, it was rendered with the settings it had when it was found: changing them
                    // afterwards makes it outdated
                    hash = v.output_hashes.get(&url).cloned().filter(|x| !x.is_empty()).unwrap_or_else(|| {
                        outputs.iter().find(|x| x.url() == url).map(|x| Self::output_hash(&v.settings, x.range_index)).unwrap_or_default()
                    });
                }
                Some((url, hash))
            }).collect();
            let Some(v) = this.video_mut(video_id) else { return; };
            v.output_hashes = output_hashes;
            this.update_stabilized_row(video_id);
        });

        core::run_threaded(move || {
            for (video_id, urls) in to_check {
                let hashes = urls.into_iter().map(|url| {
                    let hash = if !url.is_empty() && filesystem::exists(&url) {
                        Some(rendering::render_queue::stabilization_hash_from_file(&url).unwrap_or_default())
                    } else {
                        None
                    };
                    (url, hash)
                }).collect();
                checked((video_id, hashes));
            }
        });
    }

    // ---------------------------------------------------------------------------------------------
    // ----------------------------------------- Selection -----------------------------------------
    // ---------------------------------------------------------------------------------------------

    pub fn toggle_expanded(&mut self, item_id: u32) {
        if let Some(f) = self.folders.iter_mut().find(|f| f.id == item_id) {
            f.expanded = !f.expanded;
        } else if let Some(v) = self.video_mut(item_id) {
            v.expanded = !v.expanded;
        }
        self.rebuild();
    }

    /// The selection is only the working set the bulk actions are applied to, it says nothing about
    /// the render queue. Being in the queue is tracked separately, by the job of the item.
    fn select_video(v: &mut Video, selected: bool) {
        v.selected = selected;
    }

    pub fn set_selected(&mut self, item_id: u32, selected: bool) {
        self.set_selected_internal(item_id, selected);
        self.update_selection_rows();
    }
    fn set_selected_internal(&mut self, item_id: u32, selected: bool) {
        if let Some(index) = self.folders.iter().position(|f| f.id == item_id) {
            for v in self.folders[index].videos.iter_mut() {
                Self::select_video(v, selected);
            }
        } else if let Some(v) = self.video_mut(item_id) {
            Self::select_video(v, selected);
        }
    }
    /// Plain click: this item becomes the whole selection
    pub fn select_only(&mut self, item_id: u32) {
        for v in self.all_videos_mut() {
            Self::select_video(v, false);
        }
        self.set_selected_internal(item_id, true);
        self.update_selection_rows();
    }
    /// Ctrl+click: add or remove this item from the selection
    pub fn toggle_selected(&mut self, item_id: u32) {
        let selected = if let Some(v) = self.video(item_id) {
            v.selected
        } else if let Some(f) = self.folders.iter().find(|f| f.id == item_id) {
            Self::is_folder_selected(f)
        } else {
            return;
        };
        self.set_selected(item_id, !selected);
    }
    /// Shift+click: select everything between the two items, in the order they are shown in the list
    pub fn select_range(&mut self, from_item_id: u32, to_item_id: u32) {
        if from_item_id == 0 || from_item_id == to_item_id {
            self.select_only(to_item_id);
            return;
        }
        let (from, to) = (self.get_item_index(from_item_id), self.get_item_index(to_item_id));
        if from < 0 || to < 0 {
            self.select_only(to_item_id);
            return;
        }
        let ids = match self.items.try_borrow() {
            Ok(q) => {
                let count = q.row_count() as usize;
                (from.min(to) as usize..=from.max(to) as usize).filter(|i| *i < count).map(|i| q[i].item_id).collect::<Vec<_>>()
            },
            Err(_) => return
        };
        for v in self.all_videos_mut() {
            Self::select_video(v, false);
        }
        for id in ids {
            self.set_selected_internal(id, true);
        }
        self.update_selection_rows();
    }
    /// Selects all videos the list shows (the ones matching the search), or none
    pub fn select_all(&mut self, selected: bool) {
        let shown = self.all_videos().filter(|v| self.matches_search(v)).map(|v| v.id).collect::<std::collections::HashSet<_>>();
        for v in self.all_videos_mut() {
            Self::select_video(v, selected && shown.contains(&v.id));
        }
        self.update_selection_rows();
    }
    fn is_folder_selected(f: &Folder) -> bool {
        !f.videos.is_empty() && f.videos.iter().all(|v| v.selected)
    }
    fn update_selection_rows(&mut self) {
        let mut states = Vec::new();
        for f in &self.folders {
            states.push((f.id, Self::is_folder_selected(f)));
        }
        for v in self.all_videos() {
            states.push((v.id, v.selected));
        }
        for (id, selected) in states {
            self.patch_row(id, |x| x.selected = selected);
        }
        self.items_changed();
    }
    pub fn selected_count(&self) -> usize {
        self.all_videos().filter(|v| v.selected).count()
    }

    pub fn set_current_item(&mut self, item_id: u32) {
        let old = self.current_item;
        self.current_item = item_id;
        self.patch_row(old, |x| x.is_current = false);
        self.patch_row(item_id, |x| x.is_current = true);
        self.current_item_changed();
    }

    /// The next (or previous) video in the order of the list that has trim ranges, 0 if there is none
    pub fn get_adjacent_ranged_item(&self, item_id: u32, forward: bool) -> u32 {
        let mut order = self.sorted_videos(&self.standalone);
        for f in &self.folders { order.extend(self.sorted_videos(&f.videos)); }
        let Some(pos) = order.iter().position(|v| v.id == item_id) else { return 0; };
        let has_ranges = |v: &&Video| v.settings.as_ref().and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok()).is_some_and(|x| !Self::trim_ranges_ms(&x).is_empty());
        let found = if forward { order[pos + 1..].iter().copied().find(has_ranges) } else { order[..pos].iter().rev().copied().find(has_ranges) };
        found.map(|v| v.id).unwrap_or_default()
    }
    pub fn get_item_kind(&self, item_id: u32) -> QString {
        if self.folders.iter().any(|f| f.id == item_id) { return QString::from("folder"); }
        if self.video(item_id).is_some() { return QString::from("video"); }
        QString::default()
    }
    pub fn get_item_url(&self, item_id: u32) -> QString {
        if let Some(f) = self.folders.iter().find(|f| f.id == item_id) { return QString::from(f.url.as_str()); }
        self.item_settings(item_id).map(|(url, _, _)| QString::from(url)).unwrap_or_default()
    }
    pub fn get_item_name(&self, item_id: u32) -> QString {
        if let Some(f) = self.folders.iter().find(|f| f.id == item_id) { return QString::from(f.name.as_str()); }
        if let Some(v) = self.video(item_id) { return QString::from(v.filename.as_str()); }
        QString::default()
    }

    pub fn is_item_url(&self, item_id: u32, url: QString) -> bool {
        let url = Self::to_url(&url.to_string(), false);
        !url.is_empty() && self.item_settings(item_id).map(|(x, _, _)| x == url).unwrap_or_default()
    }
    pub fn find_by_url(&self, url: QString) -> u32 {
        let url = Self::to_url(&url.to_string(), false);
        if url.is_empty() { return 0; }
        self.all_videos().find(|v| v.url == url).map(|v| v.id).unwrap_or_default()
    }
    /// Row of the item in the list model, or -1 if it's not visible (filtered out or in a collapsed folder)
    pub fn get_item_index(&self, item_id: u32) -> i32 {
        if let Ok(q) = self.items.try_borrow() {
            for i in 0..q.row_count() as usize {
                if q[i].item_id == item_id { return i as i32; }
            }
        }
        -1
    }

    // ---------------------------------------------------------------------------------------------
    // --------------------------------------- Trim ranges -----------------------------------------
    // ---------------------------------------------------------------------------------------------

    fn marker_error(message: String) -> QString {
        QString::from(serde_json::json!({ "error": message }).to_string())
    }

    fn marker_videos(&self) -> Vec<marker_import::VideoSpan> {
        self.all_videos().map(|v| marker_import::VideoSpan {
            id: v.id, start: v.created_at as f64, duration_ms: v.duration_ms,
        }).collect()
    }

    fn marker_plan(&self, offset_seconds: f64) -> Result<marker_import::ImportPlan, String> {
        if !self.marker_file_loaded {
            return Err("Choose a markers.json file first.".into());
        }
        marker_import::plan_parsed(&self.markers, &self.marker_videos(), offset_seconds)
    }

    fn marker_preview_json(&self, plan: &marker_import::ImportPlan) -> String {
        let matched: std::collections::HashSet<u32> = plan.sections.iter().map(|s| s.video_id).collect();
        let mut videos = Vec::new();
        let mut untouched = Vec::new();
        for v in self.all_videos() {
            let sections: Vec<serde_json::Value> = plan.sections.iter().filter(|s| s.video_id == v.id).map(|s| {
                let label = s.name.as_deref().filter(|n| !n.trim().is_empty())
                    .or(s.path.as_deref())
                    .unwrap_or("");
                serde_json::json!({
                    "start": s.start, "end": s.end,
                    "name": s.name.clone().unwrap_or_default(),
                    "path": s.path.clone().unwrap_or_default(),
                    "label": label,
                })
            }).collect();
            if sections.is_empty() {
                untouched.push(v.filename.clone());
            } else {
                videos.push(serde_json::json!({
                    "id": v.id, "name": v.filename, "sections": sections,
                }));
            }
        }
        serde_json::json!({
            "videos": videos,
            "unmatched": plan.unmatched,
            "untouched": untouched,
            "sections": plan.sections.len(),
            "matched": matched.len(),
        }).to_string()
    }

    /// Read and validate markers.json files, one url per line (see `add_url` why not a list). The markers of several files are
    /// merged into one set (the same marker in more than one file only once). Preview and import then use the cached markers.
    pub fn load_markers(&mut self, urls: QString) -> QString {
        self.markers.clear();
        self.marker_file_loaded = false;
        let list = urls.to_string();
        let mut urls: Vec<String> = Vec::new();
        // A drop has each file in its urls and again in its text, eg. as a path or encoded differently: one file is one url
        for url in list.lines().map(str::trim).filter(|x| !x.is_empty()) {
            let url = Some(Self::to_url(url, false)).filter(|x| !x.is_empty()).unwrap_or_else(|| url.to_string());
            if !urls.contains(&url) { urls.push(url); }
        }
        if urls.is_empty() { return Self::marker_error("Choose a markers.json file first.".into()); }
        let mut markers: Vec<marker_import::Marker> = Vec::new();
        for url in &urls {
            let name = filesystem::get_filename(url);
            let path = filesystem::url_to_path(&Self::to_url(url, false));
            let json = match std::fs::read_to_string(&path) {
                Ok(json) => json,
                Err(e) => return Self::marker_error(if urls.len() > 1 { format!("Could not read markers file {name}: {e}") } else { format!("Could not read markers file: {e}") }),
            };
            match marker_import::parse(&json) {
                Ok(parsed) => for m in parsed {
                    if !markers.contains(&m) { markers.push(m); }
                },
                Err(e) => return Self::marker_error(if urls.len() > 1 { format!("{name}: {e}") } else { e }),
            }
        }
        let ins = markers.iter().filter(|m| matches!(m, marker_import::Marker::In { .. })).count();
        let outs = markers.iter().filter(|m| matches!(m, marker_import::Marker::Out { .. })).count();
        self.markers = markers;
        self.marker_file_loaded = true;
        QString::from(serde_json::json!({
            "name": filesystem::get_filename(&urls[0]),
            "names": urls.iter().map(|x| filesystem::get_filename(x)).collect::<Vec<_>>(),
            "files": urls.len(),
            "count": self.markers.len(), "ins": ins, "outs": outs,
        }).to_string())
    }

    /// Match cached markers against the current videos without changing the sidebar.
    pub fn preview_markers(&self, offset_seconds: f64) -> QString {
        match self.marker_plan(offset_seconds) {
            Ok(plan) => QString::from(self.marker_preview_json(&plan)),
            Err(e) => Self::marker_error(e),
        }
    }

    /// Whether an offset 1 to 12 whole hours more (`later`) or less (`earlier`) than this one matches any trim range.
    pub fn nearby_marker_matches(&self, offset_seconds: f64) -> QString {
        let matches = |sign: f64| (1..=12).any(|hours| {
            self.marker_plan(offset_seconds + sign * hours as f64 * 3600.0).map(|plan| !plan.sections.is_empty()).unwrap_or_default()
        });
        QString::from(serde_json::json!({ "later": matches(1.0), "earlier": matches(-1.0) }).to_string())
    }

    /// Apply cached markers to the library. Returns a JSON summary for the UI.
    pub fn import_markers(&mut self, offset_seconds: f64) -> QString {
        if self.scanning { return Self::marker_error("Wait for video scanning to finish before importing markers.".into()); }
        let plan = match self.marker_plan(offset_seconds) {
            Ok(plan) => plan,
            Err(e) => return Self::marker_error(e),
        };
        let mut summary: serde_json::Value = serde_json::from_str(&self.marker_preview_json(&plan)).unwrap_or_else(|_| serde_json::json!({}));
        for v in self.all_videos_mut() {
            v.timeline_markers.clear();
        }
        for (id, marker) in plan.timeline {
            if let Some(v) = self.video_mut(id) { v.timeline_markers.push(marker); }
        }
        let mut queue_ids = Vec::new();
        for section in plan.sections {
            if self.add_trim_range(section.video_id, section.start, section.end, section.name, section.path) && !queue_ids.contains(&section.video_id) {
                queue_ids.push(section.video_id);
            }
        }
        self.rebuild();
        self.refresh_outputs();
        summary["queue_ids"] = serde_json::json!(queue_ids);
        QString::from(summary.to_string())
    }

    pub fn get_timeline_markers(&self, item_id: u32) -> QString {
        let video = self.video(item_id);
        QString::from(serde_json::to_string(&video.map(|v| &v.timeline_markers).cloned().unwrap_or_default()).unwrap_or_else(|_| "[]".into()))
    }

    /// Adds a trim range (normalized to 0..1) with an optional name and output path to the settings of the video.
    /// An identical range is not added twice. Returns whether the video has the range now
    fn add_trim_range(&mut self, video_id: u32, start: f64, end: f64, name: Option<String>, path: Option<String>) -> bool {
        let base = self.video(video_id).map(|v| self.output_path_or_default(&v.url, &v.output_path)).unwrap_or_default();
        let Some(v) = self.video_mut(video_id) else { return false; };
        if v.duration_ms <= 0.0 || end <= start { return false; }
        let (start_ms, end_ms) = (start * v.duration_ms, end * v.duration_ms);
        let mut obj = v.settings.as_ref()
            .and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok())
            .filter(|x| x.is_object())
            .unwrap_or_else(|| serde_json::json!({ "title": "Gyroflow data file", "version": 4, "videofile": v.url }));
        let mut ranges = Self::trim_ranges_ms(&obj);
        let mut info = Self::range_info_values(&obj, ranges.len());
        if !ranges.iter().any(|r| (r.0 - start_ms).abs() < 1.0 && (r.1 - end_ms).abs() < 1.0) {
            ranges.push((start_ms, end_ms));
            // The output path of the marker, otherwise its name is added to the path of the video
            let name = name.unwrap_or_default().trim().replace(['/', '\\'], "_");
            let path = path.filter(|x| !x.trim().is_empty()).unwrap_or_else(|| if name.is_empty() { String::new() } else { format!("{base}-{name}") });
            info.push(serde_json::json!({ "output_path": path }));
        }
        // The timeline keeps the ranges sorted, keep the names with them
        let mut combined = ranges.into_iter().zip(info).collect::<Vec<_>>();
        combined.sort_by(|a, b| a.0.0.total_cmp(&b.0.0));
        if let serde_json::Value::Object(ref mut o) = obj {
            o.insert("trim_ranges_ms".into(), serde_json::json!(combined.iter().map(|x| [x.0.0, x.0.1]).collect::<Vec<_>>()));
            o.insert("trim_range_info".into(), serde_json::json!(combined.into_iter().map(|x| x.1).collect::<Vec<_>>()));
            o.remove("trim_ranges");
        }
        Self::assign_range_paths(&mut obj, &base);
        v.settings = Some(obj.to_string());
        let id = v.id;
        self.reconcile_keys(id);
        true
    }
    fn trim_ranges_ms(obj: &serde_json::Value) -> Vec<(f64, f64)> {
        obj.get("trim_ranges_ms").and_then(|x| x.as_array()).map(|x| x.iter().filter_map(|r| {
            let r = r.as_array()?;
            Some((r.first()?.as_f64()?, r.get(1)?.as_f64()?))
        }).collect()).unwrap_or_default()
    }
    /// `trim_range_info` (name and output path of each trim range), as many entries as there are ranges
    fn range_info_values(obj: &serde_json::Value, count: usize) -> Vec<serde_json::Value> {
        let mut info = obj.get("trim_range_info").and_then(|x| x.as_array()).cloned().unwrap_or_default();
        info.resize(count, serde_json::json!({}));
        info
    }
    /// Number of trim ranges, the output path of each, and whether they are exported as separate videos
    fn range_info(settings: &Option<String>) -> (usize, Vec<String>, bool) {
        let Some(obj) = settings.as_ref().and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok()) else { return (0, Vec::new(), true); };
        let count = obj.get("trim_ranges_ms").or_else(|| obj.get("trim_ranges")).and_then(|x| x.as_array()).map(|x| x.len()).unwrap_or_default();
        let paths = Self::range_info_values(&obj, count).iter().map(Self::range_path).collect();
        let separate = obj.get("output").and_then(|x| x.get("export_trims_separately")).and_then(|x| x.as_bool()).unwrap_or(true);
        (count, paths, separate)
    }
    fn range_path(info: &serde_json::Value) -> String {
        info.get("output_path").and_then(|x| x.as_str()).unwrap_or_default().trim().to_owned()
    }
    /// Every trim range has its own output path. A range that doesn't have one yet gets the path of the video
    /// with the next free number (`clip_stabilized-001`, `-002`, ...)
    fn assign_range_paths(obj: &mut serde_json::Value, base: &str) {
        let count = Self::trim_ranges_ms(obj).len().max(obj.get("trim_ranges").and_then(|x| x.as_array()).map(|x| x.len()).unwrap_or_default());
        let mut info = Self::range_info_values(obj, count);
        let mut used = info.iter().map(Self::range_path).filter(|x| !x.is_empty()).collect::<std::collections::HashSet<_>>();
        let mut number = 1;
        for x in info.iter_mut() {
            // The id of the range, its jobs in the render queue are found by it (see `JobState::seq`)
            if !x.is_object() { *x = serde_json::json!({ }); }
            if x.get("uid").and_then(|x| x.as_str()).map_or(true, |x| x.is_empty()) {
                x["uid"] = serde_json::Value::String(format!("{:016x}", fastrand::u64(..)));
            }
            if !Self::range_path(x).is_empty() { continue; }
            let path = loop {
                let path = format!("{base}-{number:0>3}");
                number += 1;
                if !used.contains(&path) { break path; }
            };
            used.insert(path.clone());
            if !x.is_object() { *x = serde_json::json!({ }); }
            x["output_path"] = serde_json::Value::String(path);
        }
        if let serde_json::Value::Object(o) = obj {
            if count > 0 { o.insert("trim_range_info".into(), serde_json::json!(info)); }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // ----------------------------------------- Settings ------------------------------------------
    // ---------------------------------------------------------------------------------------------

    /// Stores the project data of the item, as exported from the main view
    pub fn save_settings(&mut self, item_id: u32, data: QString) {
        let mut data = match serde_json::from_str::<serde_json::Value>(&data.to_string()) {
            Ok(v) if v.is_object() => v,
            _ => return
        };
        if let serde_json::Value::Object(ref mut obj) = data {
            // The motion data itself is always loaded from the video file
            if let Some(serde_json::Value::Object(gyro)) = obj.get_mut("gyro_source") {
                for k in ["file_metadata", "raw_imu", "quaternions", "smoothed_quaternions", "gravity_vectors", "image_orientations"] {
                    gyro.remove(k);
                }
            }
        }
        // A lens profile loaded manually in the main view clears the warning of that video
        let lens_name = data.get("calibration_data").and_then(|x| x.get("name")).and_then(|x| x.as_str()).unwrap_or_default().to_owned();
        let video_id = item_id;
        if !lens_name.is_empty() {
            if let Some(v) = self.video_mut(video_id) {
                if v.lens_warning {
                    v.lens_warning = false;
                    v.lens_profile = lens_name.clone();
                }
            }
            let (profile, warning) = self.video(video_id).map(|v| (v.lens_profile.clone(), v.lens_warning)).unwrap_or_default();
            self.patch_row(video_id, |x| {
                x.lens_profile = QString::from(profile);
                x.lens_warning = warning;
            });
        }

        if let Some(base) = self.video(item_id).map(|v| self.output_path_or_default(&v.url, &v.output_path)) {
            Self::assign_range_paths(&mut data, &base);
        }
        let data = data.to_string();
        // Files without the hash of their settings (rendered before it was written, or found before the video had settings)
        // were rendered with the settings it's opened with first: later changes make them outdated
        let unknown = self.video(item_id).map(|v| self.outputs(v, None).into_iter()
            .filter(|x| v.output_hashes.get(&x.url()).is_some_and(|h| h.is_empty()))
            .map(|x| (x.url(), x.range_index)).collect::<Vec<_>>()).unwrap_or_default();
        let Some(v) = self.video_mut(item_id) else { return; };
        // The trim ranges (and with them the output files) are edited in the timeline of the main view
        let outputs_changed = Self::range_info(&v.settings) != Self::range_info(&Some(data.clone()));
        v.settings = Some(data);
        for (url, range_index) in unknown {
            let hash = Self::output_hash(&v.settings, range_index);
            v.output_hashes.insert(url, hash);
        }
        self.reconcile_keys(item_id);
        if outputs_changed {
            self.rebuild();
            self.refresh_outputs();
        } else {
            // The trim ranges could have moved, and the output files could be outdated now
            self.update_stabilized_row(item_id);
        }
    }

    /// Project data of the item, used to load it in the main view
    pub fn get_project_data(&self, item_id: u32) -> QString {
        self.build_project_data(item_id, false).map(QString::from).unwrap_or_default()
    }
    /// Settings of the rendered item, applied to the already loaded render job (ie. without the video and gyro data)
    /// The job of a trim range with its own settings gets those instead of the ones of the video
    pub fn get_settings_for_job(&self, job_id: u32) -> QString {
        let item_id = self.item_id_for_job(job_id);
        let seq = self.video(item_id).and_then(|v| v.jobs.iter().find(|x| x.job_id == job_id)).map(|x| x.seq.clone()).unwrap_or_default();
        self.get_range_settings(item_id, self.range_index_of_seq(item_id, &seq))
    }
    /// Settings of the video to apply to a render job of one of its trim ranges (-1: the whole video)
    pub fn get_range_settings(&self, item_id: u32, range_index: i32) -> QString {
        let Some(data) = self.build_project_data(item_id, true) else { return QString::default(); };
        let mut obj = serde_json::from_str::<serde_json::Value>(&data).unwrap_or_default();
        if range_index >= 0 {
            if let Some(stab) = Self::range_stabilization(&obj, range_index as usize) {
                obj["stabilization"] = stab;
            }
            // The export settings of the range replace the ones of the video, the output path stays the one of the range
            if let Some(serde_json::Value::Object(mut output)) = Self::range_output(&obj, range_index as usize) {
                for k in ["output_path", "output_folder", "output_filename", "output_folder_bookmark"] { output.remove(k); }
                if !obj["output"].is_object() { obj["output"] = serde_json::json!({ }); }
                for (k, v) in output { obj["output"][k] = v; }
            }
        }
        QString::from(obj.to_string())
    }

    fn build_project_data(&self, item_id: u32, as_preset: bool) -> Option<String> {
        let (url, settings, _) = self.item_settings(item_id)?;
        let url = url.to_owned();
        // Nothing was configured for this video, load it as a plain video file
        let mut obj = settings.as_ref().and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok()).filter(|x| x.is_object())?;
        if let serde_json::Value::Object(ref mut o) = obj {
            // The output path is managed by the media library, but the other export settings (resolution, codec etc.) belong to the item
            if let Some(output) = o.get_mut("output") { Self::strip_output_path(output); }
            if as_preset {
                o.remove("videofile");
                o.remove("videofile_bookmark");
                if let Some(serde_json::Value::Object(gyro)) = o.get_mut("gyro_source") {
                    gyro.remove("filepath");
                    gyro.remove("filepath_bookmark");
                }
            } else {
                // The motion data is loaded from the file in `gyro_source`. Settings that weren't made in the main view
                // (eg. trim ranges from imported markers) don't have it, then it's in the video itself
                let gyro = o.entry("gyro_source").or_insert_with(|| serde_json::json!({ }));
                if gyro.is_object() && gyro.get("filepath").and_then(|x| x.as_str()).map_or(true, |x| x.is_empty()) {
                    gyro["filepath"] = serde_json::Value::String(url.clone());
                }
                o.insert("videofile".into(), serde_json::Value::String(url));
            }
        }
        Some(obj.to_string())
    }

    fn strip_output_path(output: &mut serde_json::Value) {
        if let serde_json::Value::Object(output) = output {
            for k in ["output_path", "output_folder", "output_filename", "output_folder_bookmark"] {
                output.remove(k);
            }
        }
    }
    /// Export settings saved with the item, without the output path. Empty if the item wasn't configured yet
    pub fn get_output_settings(&self, item_id: u32) -> QString {
        self.item_settings(item_id)
            .and_then(|(_, s, _)| s.as_ref())
            .and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok())
            .and_then(|x| x.get("output").cloned())
            .filter(|x| x.is_object())
            .map(|mut x| { Self::strip_output_path(&mut x); QString::from(x.to_string()) })
            .unwrap_or_default()
    }

    /// Applies the stabilization settings (and only those) to all videos in the library
    pub fn apply_stabilization_to_all(&mut self, data: QString, except_item_id: u32) -> usize {
        let new_stab = match serde_json::from_str::<serde_json::Value>(&data.to_string()) {
            Ok(v) => v.get("stabilization").cloned().unwrap_or(v),
            Err(e) => { ::log::warn!("Invalid stabilization settings: {e:?}"); return 0; }
        };
        if !new_stab.is_object() { return 0; }

        fn apply(settings: &mut Option<String>, url: &str, new_stab: &serde_json::Value) {
            let mut obj = settings.as_ref()
                .and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok())
                .filter(|x| x.is_object())
                .unwrap_or_else(|| serde_json::json!({ "title": "Gyroflow data file", "version": 4, "videofile": url }));
            if let serde_json::Value::Object(ref mut obj) = obj {
                obj.insert("stabilization".into(), new_stab.clone());
                // A video with separate settings for its trim ranges gets them for all of its ranges
                if let Some(serde_json::Value::Array(info)) = obj.get_mut("trim_range_info") {
                    for x in info.iter_mut().filter_map(|x| x.as_object_mut()) {
                        if x.contains_key("stabilization") { x.insert("stabilization".into(), new_stab.clone()); }
                    }
                }
            }
            *settings = Some(obj.to_string());
        }

        let mut count = 0;
        let mut ids = Vec::new();
        for v in self.all_videos_mut() {
            let url = v.url.clone();
            if v.id != except_item_id {
                apply(&mut v.settings, &url, &new_stab);
                ids.push(v.id);
                count += 1;
            }
        }
        for id in ids {
            self.update_stabilized_row(id);
        }
        count
    }

    /// Applies the settings selected in the "Apply to render queue" dialog to the items waiting in the render queue,
    /// so their jobs aren't reverted when they are synced with the library again. Returns the ids of the changed items
    pub fn apply_settings_to_queued(&mut self, data: QString) -> QVariantList {
        let mut new_data = match serde_json::from_str::<serde_json::Value>(&data.to_string()) {
            Ok(v) if v.is_object() => v,
            _ => return QVariantList::default()
        };
        // The output path is managed by the media library
        if let Some(output) = new_data.get_mut("output") { Self::strip_output_path(output); }

        fn apply(settings: &mut Option<String>, url: &str, new_data: &serde_json::Value) {
            let mut obj = settings.as_ref()
                .and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok())
                .filter(|x| x.is_object())
                .unwrap_or_else(|| serde_json::json!({ "title": "Gyroflow data file", "version": 4, "videofile": url }));
            if let (serde_json::Value::Object(obj), serde_json::Value::Object(new_data)) = (&mut obj, new_data) {
                for (k, v) in new_data {
                    if k == "version" { continue; }
                    match (obj.get_mut(k), v) {
                        // Groups only contain the selected fields, so replace those and keep the others.
                        // Values are replaced as a whole, so arrays like the trim ranges aren't merged
                        (Some(serde_json::Value::Object(group)), serde_json::Value::Object(fields)) if ["video_info", "gyro_source", "synchronization", "stabilization", "output"].contains(&k.as_str()) => {
                            for (fk, fv) in fields { group.insert(fk.clone(), fv.clone()); }
                        },
                        _ => { obj.insert(k.clone(), v.clone()); }
                    }
                }
            }
            *settings = Some(obj.to_string());
        }

        let mut ids = Vec::new();
        for v in self.all_videos_mut() {
            let url = v.url.clone();
            if v.jobs.iter().any(|x| x.job_id > 0 && (x.status == "queued" || x.status == "processing")) {
                apply(&mut v.settings, &url, &new_data);
                ids.push(v.id);
            }
        }
        for &id in &ids {
            self.update_stabilized_row(id);
            self.reconcile_keys(id);
        }
        QVariantList::from_iter(ids)
    }

    /// The stabilization settings the video is rendered with, including the ones of its trim ranges if they have their own
    /// Stabilization settings of a trim range, if the video has separate settings for each range
    fn range_stabilization(obj: &serde_json::Value, range_index: usize) -> Option<serde_json::Value> {
        Self::range_setting(obj, range_index, "stabilization")
    }
    /// Export settings of a trim range (without the output path), if the video has separate settings for each range
    fn range_output(obj: &serde_json::Value, range_index: usize) -> Option<serde_json::Value> {
        Self::range_setting(obj, range_index, "output")
    }
    /// See `JobState::seq`. Every range gets one when the settings are saved, this is only for settings that never were
    fn range_uid(obj: &serde_json::Value, range_index: usize) -> String {
        obj.get("trim_range_info").and_then(|x| x.get(range_index)).and_then(|x| x.get("uid")).and_then(|x| x.as_str())
            .map(str::to_owned).unwrap_or_else(|| format!("#{range_index}"))
    }
    /// The current index of the trim range with this id, -1 for the whole video and -2 if it doesn't exist anymore
    fn range_index_of_seq(&self, item_id: u32, seq: &str) -> i32 {
        if seq.is_empty() { return -1; }
        let Some(v) = self.video(item_id) else { return -2; };
        self.outputs(v, None).into_iter().find(|x| x.seq == seq).map(|x| x.range_index).unwrap_or(-2)
    }
    fn range_setting(obj: &serde_json::Value, range_index: usize, key: &str) -> Option<serde_json::Value> {
        if obj.get("trim_range_config").and_then(|x| x.as_str()) != Some("separate") { return None; }
        obj.get("trim_range_info")?.get(range_index)?.get(key).filter(|x| x.is_object()).cloned()
    }
    /// Hash of everything that goes into the output file of the trim range `range_index` (-1: the whole video, or all of
    /// its ranges joined into one): the stabilization and export settings (the range's own, if it has them), the
    /// background, the lens, the motion data and its synchronization, the keyframes, and the frames that are rendered.
    /// Not the output path: where the file is doesn't change what's in it. Empty if the video has no settings yet
    fn output_hash(settings: &Option<String>, range_index: i32) -> String {
        let Some(obj) = settings.as_ref().and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok()).filter(|x| x.is_object()) else { return String::new(); };
        let get = |k: &str| obj.get(k).cloned().unwrap_or(serde_json::Value::Null);
        let range = usize::try_from(range_index).ok();

        let stabilization = range.and_then(|i| Self::range_stabilization(&obj, i)).unwrap_or_else(|| get("stabilization"));
        let mut output = get("output");
        if let (Some(own), serde_json::Value::Object(o)) = (range.and_then(|i| Self::range_output(&obj, i)), &mut output) {
            if let serde_json::Value::Object(own) = own { o.extend(own); }
        }
        if let serde_json::Value::Object(o) = &mut output {
            for k in ["output_folder", "output_filename", "output_folder_bookmark", "output_path", "metadata", "export_trims_separately", "trim_range_index", "input_filename", "input_url"] {
                o.remove(k);
            }
        }
        let gyro_source = get("gyro_source");
        let gyro = ["lpf", "mf", "rotation", "acc_rotation", "imu_orientation", "gyro_bias", "integration_method", "sample_index", "optical_correction_enabled", "optical_correction_strength", "ignore_file_motion"]
            .iter().map(|k| (k.to_string(), gyro_source.get(*k).cloned().unwrap_or(serde_json::Value::Null))).collect::<serde_json::Map<_, _>>();

        // The input frames: of the range, of all ranges when they are joined, or of the whole video without ranges
        let info = get("video_info");
        let fps = info.get("fps").and_then(|x| x.as_f64()).unwrap_or_default();
        let duration_ms = info.get("duration_ms").and_then(|x| x.as_f64()).unwrap_or_default();
        let frame = |ms: f64| (ms * fps / 1000.0).round() as i64;
        let ranges = Self::trim_ranges_ms(&obj);
        let frames = match range {
            Some(i) => ranges.get(i).map(|r| vec![*r]).unwrap_or_default(),
            None => ranges,
        }.into_iter().map(|(start, end)| {
            let end = if end < 0.0 { duration_ms + end } else { end };
            [frame(start), frame(end)]
        }).collect::<Vec<_>>();
        let frames = if frames.is_empty() { vec![[0, info.get("num_frames").and_then(|x| x.as_i64()).unwrap_or_else(|| frame(duration_ms))]] } else { frames };

        rendering::render_queue::settings_hash(&serde_json::json!({
            "stabilization": stabilization,
            "output": output,
            "background": {
                "color":   get("background_color"),
                "mode":    get("background_mode"),
                "margin":  get("background_margin"),
                "feather": get("background_margin_feather"),
            },
            "light_refraction_coefficient": get("light_refraction_coefficient"),
            "lens": get("calibration_data"),
            "gyro_source": gyro,
            "offsets": get("offsets"),
            "keyframes": get("keyframes"),
            "frames": frames,
        }))
    }
    fn store_expected_hashes(&self, hashes: &mut std::collections::HashMap<(String, i32), String>, v: &Video) {
        for output in self.outputs(v, None) {
            hashes.insert((v.url.clone(), output.range_index), Self::output_hash(&v.settings, output.range_index));
        }
    }
    /// The hash of the output file a job renders, by the url of its video and its trim range, from the table the library keeps
    pub fn lookup_expected_hash(hashes: &ExpectedHashes, url: &str, range_index: Option<usize>) -> Option<String> {
        let key = (Self::to_url(url, false), range_index.map(|x| x as i32).unwrap_or(-1));
        hashes.lock().get(&key).cloned().filter(|x| !x.is_empty())
    }
    /// Whether the output file exists (`STABILIZED`), and if its settings changed since it was rendered (`STALE`). The hash
    /// it was rendered with is the one in the file, or for a file without it (eg. rendered by an older version or another
    /// app) the one of the settings the video had when the file was found (see `refresh_outputs`)
    fn output_state(v: &Video, output: &OutputFile) -> i32 {
        let Some(hash) = v.output_hashes.get(&output.url()) else { return NOT_STABILIZED; };
        let current = Self::output_hash(&v.settings, output.range_index);
        if !hash.is_empty() && !current.is_empty() && *hash != current { STALE } else { STABILIZED }
    }
    fn output_state_name(state: i32) -> &'static str {
        match state { STABILIZED => "stabilized", STALE => "changed", _ => "" }
    }
    /// Changed when one of the output files is, stabilized when all of them exist
    fn stabilized_state(&self, v: &Video, outputs: &[OutputFile]) -> i32 {
        let states = outputs.iter().map(|x| Self::output_state(v, x)).collect::<Vec<_>>();
        if states.contains(&STALE) {
            STALE
        } else if !states.is_empty() && states.iter().all(|x| *x == STABILIZED) {
            STABILIZED
        } else {
            NOT_STABILIZED
        }
    }
    /// The state of every output file of the video, by its key (see `JobState::seq`): "stabilized", "changed" or missing
    pub fn get_output_states(&self, item_id: u32) -> QString {
        let states = self.video(item_id).map(|v| self.outputs(v, None).iter().filter_map(|x| {
            let state = Self::output_state_name(Self::output_state(v, x));
            (!state.is_empty()).then(|| (x.seq.clone(), serde_json::Value::String(state.to_owned())))
        }).collect::<serde_json::Map<_, _>>()).unwrap_or_default();
        QString::from(serde_json::Value::Object(states).to_string())
    }
    /// The hash the output file of a job is rendered with, called by the render queue when the job starts. The job is found
    /// by its id, or by its video if it isn't registered yet (eg. "Stabilize now", which starts it right away)
    pub fn hash_for_render(&mut self, job_id: u32, url: &str, range_index: Option<usize>) -> Option<String> {
        let range_index = range_index.map(|x| x as i32).unwrap_or(-1);
        let item_id = match self.item_id_for_job(job_id) { 0 => self.find_by_url(QString::from(url)), id => id };
        let v = self.video(item_id)?;
        let hash = Self::output_hash(&v.settings, range_index);
        if hash.is_empty() { return None; }
        if let Some(job) = self.job_mut(job_id) { job.hash = hash.clone(); }
        Some(hash)
    }
    /// The output files were checked or rendered, or the settings changed: the row and the ranges show if they are up to date
    fn update_stabilized_row(&mut self, item_id: u32) {
        if self.video(item_id).is_none() { return; }
        self.update_job_row(item_id);
        self.key_states_changed(item_id);
    }

    // ---------------------------------------------------------------------------------------------
    // --------------------------------------- Output paths ----------------------------------------
    // ---------------------------------------------------------------------------------------------

    /// Just the name of the video with the suffix, so it's relative to the export folder and the extension follows the codec
    fn default_output_filename(input_filename: &str, suffix: &str) -> String {
        let stem = input_filename.rfind('.').map_or(input_filename, |pos| &input_filename[..pos]);
        format!("{stem}{suffix}")
    }
    /// Extension of the rendered file, from the export settings saved with the item
    fn output_extension(input_url: &str, settings: &Option<String>) -> String {
        #[derive(serde::Deserialize)]
        struct Settings { output: Option<serde_json::Value> }
        let mut options = rendering::render_queue::RenderOptions::default();
        if let Some(output) = settings.as_ref().and_then(|x| serde_json::from_str::<Settings>(x).ok()).and_then(|x| x.output) {
            options.update_from_json(&output);
        }
        options.output_extension(&filesystem::get_filename(input_url), None)
    }
    /// The extension of the output path is replaced with the one of the codec, so it's always valid for the export settings
    fn with_output_extension(filename: &str, input_url: &str, ext: &str) -> String {
        format!("{}{ext}", Self::without_output_extension(filename, input_url))
    }
    /// The output path without the extension of a video or image sequence (or of the input file)
    fn without_output_extension<'a>(filename: &'a str, input_url: &str) -> &'a str {
        let input_filename = filesystem::get_filename(input_url);
        let input_ext = input_filename.rfind('.').map(|pos| input_filename[pos + 1..].to_ascii_lowercase()).unwrap_or_default();
        let mut stem = filename;
        if let Some(pos) = filename.rfind('.') {
            let current = filename[pos + 1..].to_ascii_lowercase();
            if ["mp4", "mov", "mxf", "mkv", "avi", "m4v", "exr", "png"].contains(&current.as_str()) || current == input_ext {
                stem = &filename[..pos];
                // Frame number pattern of image sequences
                if let Some(p) = stem.rfind("_%0").filter(|&p| stem[p..].ends_with('d')) { stem = &stem[..p]; }
            }
        }
        stem
    }
    fn output_path_or_default(&self, input_url: &str, output_path: &str) -> String {
        if output_path.is_empty() {
            Self::default_output_filename(&filesystem::get_filename(input_url), &self.default_suffix.to_string())
        } else {
            output_path.to_owned()
        }
    }
    /// The output path can be either absolute, or relative to the export folder (which defaults to the input folder).
    /// The extension comes from `ext` if given, otherwise from the export settings of the item
    fn resolve_output(&self, input_url: &str, output_path: &str, settings: &Option<String>, ext: Option<&str>) -> (String, String) {
        let path = self.output_path_or_default(input_url, output_path);
        let ext = ext.map(|x| x.to_owned()).unwrap_or_else(|| Self::output_extension(input_url, settings));
        let is_absolute = path.starts_with('/') || path.contains("://") || path.get(1..3).map_or(false, |x| x == ":/" || x == ":\\");
        let (folder, filename) = if is_absolute {
            let url = if path.contains("://") { path } else { filesystem::path_to_url(&path) };
            (filesystem::get_folder(&url), filesystem::get_filename(&url))
        } else {
            let base = if self.export_folder.is_empty() { filesystem::get_folder(input_url) } else { self.export_folder.to_string() };
            if !path.contains('/') && !path.contains('\\') {
                (base, path)
            } else {
                let mut full = filesystem::url_to_path(&base);
                if !full.ends_with('/') && !full.ends_with('\\') { full.push('/'); }
                full.push_str(&path.replace('\\', "/"));
                let url = filesystem::path_to_url(&full);
                (filesystem::get_folder(&url), filesystem::get_filename(&url))
            }
        };
        let filename = Self::with_output_extension(&filename, input_url, &ext);
        (folder, filename)
    }

    /// The files the video is exported to: the output path of the video if it's exported as one file (no trim ranges, or
    /// joined), otherwise the output path of each trim range
    fn outputs(&self, v: &Video, ext: Option<&str>) -> Vec<OutputFile> {
        let (count, paths, separate) = Self::range_info(&v.settings);
        if count == 0 || !separate {
            let (folder, filename) = self.resolve_output(&v.url, &v.output_path, &v.settings, ext);
            return vec![OutputFile { range_index: -1, seq: String::new(), folder, filename, own_settings: false }];
        }
        let base = self.output_path_or_default(&v.url, &v.output_path);
        let obj = v.settings.as_ref().and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok()).unwrap_or_default();
        paths.iter().enumerate().map(|(i, path)| {
            // Every range gets a path when the settings are saved, this is only for settings that never were
            let path = if path.is_empty() { format!("{base}-{:0>3}", i + 1) } else { path.clone() };
            let own_settings = Self::range_stabilization(&obj, i).is_some() || Self::range_output(&obj, i).is_some();
            // A range with its own export settings gets the extension of its own codec
            let range_ext = Self::range_output(&obj, i).map(|output| {
                let mut options = rendering::render_queue::RenderOptions::default();
                options.update_from_json(&output);
                options.output_extension(&filesystem::get_filename(&v.url), None)
            });
            let (folder, filename) = self.resolve_output(&v.url, &path, &v.settings, range_ext.as_deref().or(ext));
            OutputFile { range_index: i as i32, seq: Self::range_uid(&obj, i), folder, filename, own_settings }
        }).collect()
    }
    /// Folder and filename (with the extension of the codec) the output path resolves to for the video, for the output path field
    pub fn resolve_output_path(&self, item_id: u32, path: QString, ext: QString) -> QVariantList {
        let (ext, path) = (ext.to_string(), path.to_string());
        let ext = Some(ext.as_str()).filter(|x| !x.is_empty());
        let (folder, filename) = self.item_settings(item_id).map(|(url, settings, _)| self.resolve_output(url, &path, settings, ext)).unwrap_or_default();
        QVariantList::from_iter([QString::from(folder), QString::from(filename)])
    }
    /// The output files of the video as JSON: `[{ range_index, output_folder, output_filename }]`, the way the render queue takes them
    pub fn get_item_outputs(&self, item_id: u32, ext: QString) -> QString {
        let ext = ext.to_string();
        let ext = Some(ext.as_str()).filter(|x| !x.is_empty());
        let outputs = self.video(item_id).map(|v| self.outputs(v, ext)).unwrap_or_default();
        QString::from(serde_json::json!(outputs.iter().map(|x| serde_json::json!({
            "range_index": x.range_index,
            "seq": x.seq,
            "output_folder": x.folder,
            "output_filename": x.filename,
            "own_settings": x.own_settings,
        })).collect::<Vec<_>>()).to_string())
    }

    pub fn get_output_path(&self, item_id: u32) -> QString {
        self.item_settings(item_id).map(|(url, _, path)| QString::from(self.output_path_or_default(url, path))).unwrap_or_default()
    }
    pub fn get_output_folder(&self, item_id: u32) -> QString {
        self.item_settings(item_id).map(|(url, settings, path)| QString::from(self.resolve_output(url, path, settings, None).0)).unwrap_or_default()
    }
    /// The extension follows `ext` (the codec selected in the main view) or, if it's empty, the export settings saved with the item
    pub fn get_output_filename(&self, item_id: u32, ext: QString) -> QString {
        let ext = ext.to_string();
        let ext = Some(ext.as_str()).filter(|x| !x.is_empty());
        self.item_settings(item_id).map(|(url, settings, path)| QString::from(self.resolve_output(url, path, settings, ext).1)).unwrap_or_default()
    }
    pub fn set_output_path(&mut self, item_id: u32, path: QString) {
        let path = path.to_string();
        let Some(v) = self.video_mut(item_id) else { return; };
        // It's stored without the extension, which follows the codec. The output paths of the trim ranges are built from it
        // (`clip_stabilized-001`), with the extension they would end up as `clip_stabilized.mp4-001.mp4`
        v.output_path = Self::without_output_extension(&path, &v.url).to_owned();
        v.output_hashes.clear();
        self.rebuild();
        self.refresh_outputs();
    }
    /// Sets the output path from a folder url and a filename, storing it relative to the export folder if possible
    pub fn set_output_url(&mut self, item_id: u32, folder: QString, filename: QString) {
        let filename = filename.to_string();
        let folder = filesystem::normalize_url(&folder.to_string(), true);
        if filename.is_empty() { return; }

        let input_url = self.item_settings(item_id).map(|(url, _, _)| url.to_owned()).unwrap_or_default();
        if input_url.is_empty() { return; }

        let base = if self.export_folder.is_empty() { filesystem::get_folder(&input_url) } else { self.export_folder.to_string() };
        let path = if folder.is_empty() || filesystem::normalize_url(&base, true) == folder {
            filename
        } else {
            filesystem::url_to_path(&filesystem::get_file_url(&folder, &filename, false))
        };
        self.set_output_path(item_id, QString::from(path));
    }

    pub fn set_export_folder(&mut self, v: QString) {
        self.export_folder = QString::from(filesystem::normalize_url(&v.to_string(), true));
        self.options_changed();
        self.rebuild();
        self.refresh_outputs();
    }
    pub fn set_default_suffix(&mut self, v: QString) {
        if self.default_suffix == v { return; }
        self.default_suffix = v;
        self.rebuild();
        self.refresh_outputs();
    }
    pub fn set_search_text(&mut self, v: QString) {
        self.search_text = v;
        self.options_changed();
        self.rebuild();
    }
    pub fn set_sort_by_name(&mut self, v: bool) {
        self.sort_by_name = v;
        self.options_changed();
        self.rebuild();
    }

    // ---------------------------------------------------------------------------------------------
    // ------------------------------------------- Jobs --------------------------------------------
    // ---------------------------------------------------------------------------------------------

    /// Ids of all videos that should be rendered
    pub fn get_render_items(&self, selected_only: bool) -> QVariantList {
        QVariantList::from_iter(self.all_videos().filter(|v| v.selected || !selected_only).map(|v| v.id).collect::<Vec<_>>())
    }

    /// Selected videos that can be added to the render queue, ie. the ones that don't have jobs yet
    pub fn get_queueable_selection(&self) -> QVariantList {
        QVariantList::from_iter(self.all_videos().filter(|v| v.selected && v.jobs.is_empty()).map(|v| v.id).collect::<Vec<_>>())
    }
    /// Selected videos that have trim ranges, in the order of the list
    pub fn get_ranged_selection(&self) -> QVariantList {
        let mut order = self.sorted_videos(&self.standalone);
        for f in &self.folders { order.extend(self.sorted_videos(&f.videos)); }
        QVariantList::from_iter(order.into_iter().filter(|v| v.selected && !Self::video_trim_ranges(v).1.is_empty()).map(|v| v.id).collect::<Vec<_>>())
    }
    /// The duration of the video and its trim ranges in ms, with an end counted from the end of the video resolved
    fn video_trim_ranges(v: &Video) -> (f64, Vec<(f64, f64)>) {
        let obj = v.settings.as_ref().and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok()).unwrap_or_default();
        let duration = obj.get("video_info").and_then(|x| x.get("duration_ms")).and_then(|x| x.as_f64()).filter(|x| *x > 0.0).unwrap_or(v.duration_ms);
        let ranges = Self::trim_ranges_ms(&obj).into_iter().map(|(start, end)| (start, if end < 0.0 { duration + end } else { end })).collect();
        (duration, ranges)
    }
    /// `{ name, duration_ms, ranges: [[start_ms, end_ms]] }` of the video
    pub fn get_trim_ranges(&self, item_id: u32) -> QString {
        let Some(v) = self.video(item_id) else { return QString::default(); };
        let (duration, ranges) = Self::video_trim_ranges(v);
        QString::from(serde_json::json!({ "name": v.filename, "duration_ms": duration, "ranges": ranges.iter().map(|r| [r.0, r.1]).collect::<Vec<_>>() }).to_string())
    }
    /// The trim ranges of a video with their starts moved `extend_left_ms` earlier, their ends `extend_right_ms` later, and
    /// all of it by `shift_ms` (later if it's positive), within the video. A range that would end before it starts stays as it is
    pub fn modified_trim_range(range: (f64, f64), duration: f64, extend_left_ms: f64, extend_right_ms: f64, shift_ms: f64) -> (f64, f64) {
        let start = (range.0 - extend_left_ms + shift_ms).clamp(0.0, duration);
        let end = (range.1 + extend_right_ms + shift_ms).clamp(0.0, duration);
        if end - start < 1.0 { range } else { (start, end) }
    }
    /// Applies `modified_trim_range` to all trim ranges of the videos (a JSON array of ids). Every range keeps its id, output
    /// path and own settings. Returns the number of videos that changed
    pub fn modify_trim_ranges(&mut self, item_ids: QString, extend_left_ms: f64, extend_right_ms: f64, shift_ms: f64) -> i32 {
        let ids = serde_json::from_str::<Vec<u32>>(&item_ids.to_string()).unwrap_or_default();
        let mut changed = Vec::new();
        for id in ids {
            let Some(v) = self.video_mut(id) else { continue; };
            let (duration, ranges) = Self::video_trim_ranges(v);
            if ranges.is_empty() || duration <= 0.0 { continue; }
            let Some(mut obj) = v.settings.as_ref().and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok()).filter(|x| x.is_object()) else { continue; };
            let modified = ranges.iter().map(|r| Self::modified_trim_range(*r, duration, extend_left_ms, extend_right_ms, shift_ms)).collect::<Vec<_>>();
            if modified == ranges { continue; }
            obj["trim_ranges_ms"] = serde_json::json!(modified.iter().map(|r| [r.0, r.1]).collect::<Vec<_>>());
            if let serde_json::Value::Object(o) = &mut obj { o.remove("trim_ranges"); }
            v.settings = Some(obj.to_string());
            changed.push(id);
        }
        for &id in &changed {
            self.reconcile_keys(id);
            self.update_stabilized_row(id);
        }
        changed.len() as i32
    }
    /// Selected videos that are in the render queue and can be removed from it
    pub fn get_queued_selection(&self) -> QVariantList {
        QVariantList::from_iter(self.all_videos().filter(|v| v.selected && !v.jobs.is_empty()).map(|v| v.id).collect::<Vec<_>>())
    }
    pub fn is_item_queued(&self, item_id: u32) -> bool {
        self.video(item_id).map(|v| !v.jobs.is_empty()).unwrap_or_default()
    }
    /// The render queue is the single source of truth for what's queued: every job that's not in it anymore
    /// (removed in the queue modal, cleared, ...) is removed from its video, and so is the highlight in the list.
    pub fn retain_jobs(&mut self, job_ids: QVariantList) {
        let existing = job_ids.into_iter().filter_map(|x| x.to_qbytearray().to_string().parse::<u32>().ok()).collect::<std::collections::HashSet<_>>();
        let mut changed = Vec::new();
        for v in self.all_videos_mut() {
            // Keys whose job isn't added yet stay
            let count = v.jobs.len();
            v.jobs.retain(|x| x.job_id == 0 || existing.contains(&x.job_id));
            v.retired.retain(|x| existing.contains(&x.job_id));
            if v.jobs.len() != count { changed.push(v.id); }
        }
        if changed.is_empty() { return; }
        for id in changed { self.update_job_row(id); self.key_states_changed(id); }
        self.items_changed();
    }

    fn new_job(job_id: u32, seq: String) -> JobState {
        JobState {
            job_id,
            status: "queued".into(),
            seq,
            ..Default::default()
        }
    }
    /// The video renders with this one job of the whole video, or it's out of the queue if it's 0
    pub fn set_item_job(&mut self, item_id: u32, job_id: u32) {
        self.clear_keys(item_id);
        if job_id > 0 {
            let job = Self::new_job(job_id, String::new());
            if let Some(v) = self.video_mut(item_id) { v.jobs.push(job); }
        }
        self.keys_changed(item_id);
    }
    /// A job of the video in the queue, for `seq` (see `JobState::seq`). The video has one job per seq at most, the queue
    /// is the ordered set of these keys, and the job of a key is never changed to render another one
    pub fn add_item_job(&mut self, item_id: u32, job_id: u32, seq: QString) {
        let seq = seq.to_string();
        if job_id == 0 || self.is_library_job(job_id) { return; }
        if self.video(item_id).map_or(true, |v| v.jobs.iter().any(|x| x.seq == seq)) { return; }
        let job = Self::new_job(job_id, seq);
        let Some(v) = self.video_mut(item_id) else { return; };
        v.jobs.push(job);
        self.update_job_row(item_id);
        self.items_changed();
    }
    /// The jobs of the video render again (eg. after "Reset status"), with the settings it has now
    pub fn reset_item_job_states(&mut self, item_id: u32) {
        let Some(v) = self.video_mut(item_id) else { return; };
        for job in v.jobs.iter_mut() {
            *job = JobState { job_id: job.job_id, status: "queued".into(), seq: job.seq.clone(), loading: job.loading, ..Default::default() };
        }
        self.update_job_row(item_id);
        self.items_changed();
    }
    // ---------------------------------------------------------------------------------------------
    // ------------------------------------- Render queue keys -------------------------------------
    // ---------------------------------------------------------------------------------------------
    // The render queue is an ordered set of keys, a video of the list and what of it is rendered (`JobState::seq`). The
    // keys are kept here and only changed here, so what's queued is always known right away. A key gets a job in the
    // render queue (which renders only that key, the order of the jobs is the order of the set) when the queue can add
    // it: the QML side does the work this asks for (`get_queue_work`) whenever `queue_keys_changed` is emitted.

    /// The keys of the video in its export mode: one per trim range exported as a separate video, otherwise the whole video
    fn available_seqs(&self, v: &Video) -> Vec<String> {
        self.outputs(v, None).into_iter().map(|x| x.seq).collect()
    }
    fn keys_changed(&mut self, item_id: u32) {
        self.update_job_row(item_id);
        self.items_changed();
        self.key_states_changed(item_id);
        self.queue_keys_changed();
    }
    /// Adds the key, its job is added by the queue. False if it's queued already or the video doesn't have it
    pub fn enqueue(&mut self, item_id: u32, seq: QString) -> bool {
        let seq = seq.to_string();
        let Some(v) = self.video(item_id) else { return false; };
        if v.jobs.iter().any(|x| x.seq == seq) || !self.available_seqs(v).contains(&seq) { return false; }
        let job = Self::new_job(0, seq);
        if let Some(v) = self.video_mut(item_id) { v.jobs.push(job); }
        self.keys_changed(item_id);
        true
    }
    /// All keys of the video in its export mode that aren't queued yet
    pub fn enqueue_all(&mut self, item_id: u32) {
        let Some(v) = self.video(item_id) else { return; };
        let missing = self.available_seqs(v).into_iter().filter(|seq| !v.jobs.iter().any(|x| &x.seq == seq)).collect::<Vec<_>>();
        if missing.is_empty() { return; }
        for seq in missing {
            let job = Self::new_job(0, seq);
            if let Some(v) = self.video_mut(item_id) { v.jobs.push(job); }
        }
        self.keys_changed(item_id);
    }
    /// Takes the key out of the queue. False if its job is rendering (or synchronizing for it) right now
    pub fn dequeue(&mut self, item_id: u32, seq: QString) -> bool {
        let seq = seq.to_string();
        let Some(v) = self.video_mut(item_id) else { return false; };
        let Some(index) = v.jobs.iter().position(|x| x.seq == seq) else { return false; };
        if !v.jobs[index].loading && v.jobs[index].job_id > 0 && v.jobs[index].is_busy() { return false; }
        let job = v.jobs.remove(index);
        Self::retire(v, job);
        self.keys_changed(item_id);
        true
    }
    /// The job of a key that's not in the queue anymore. One that's still loading the video renders a key that's waiting
    /// for it instead, otherwise the queue removes it
    fn retire(v: &mut Video, job: JobState) {
        if job.job_id == 0 { return; }
        if job.loading {
            if let Some(waiting) = v.jobs.iter_mut().find(|x| x.job_id == 0) {
                waiting.job_id = job.job_id;
                waiting.loading = true;
                return;
            }
        }
        v.retired.push(RetiredJob { job_id: job.job_id, loading: job.loading });
    }
    /// All keys of the video out of the queue (or with `job_id` > 0, only this job as the one key of the whole video)
    fn clear_keys(&mut self, item_id: u32) {
        let Some(v) = self.video_mut(item_id) else { return; };
        for job in std::mem::take(&mut v.jobs) {
            if job.job_id > 0 { v.retired.push(RetiredJob { job_id: job.job_id, loading: job.loading }); }
        }
    }
    /// The keys follow the settings of the video: when it's switched to one joined video, it's queued if any of its trim
    /// ranges was, and the other way around all of its ranges are. Keys of trim ranges that were deleted are removed
    fn reconcile_keys(&mut self, item_id: u32) {
        let Some(v) = self.video(item_id) else { return; };
        if v.jobs.is_empty() { return; }
        let available = self.available_seqs(v);
        let queued = v.jobs.iter().map(|x| x.seq.clone()).collect::<Vec<_>>();
        if queued.iter().all(|x| available.contains(x)) { return; }
        let joined = available.len() == 1 && available[0].is_empty();
        let mut add = Vec::new();
        if joined && queued.iter().any(|x| !x.is_empty()) {
            add.push(String::new());
        } else if !joined && queued.iter().any(|x| x.is_empty()) {
            add = available.clone();
        }
        let Some(v) = self.video_mut(item_id) else { return; };
        let (keep, gone): (Vec<_>, Vec<_>) = std::mem::take(&mut v.jobs).into_iter().partition(|x| available.contains(&x.seq) || (x.job_id > 0 && !x.loading && x.is_busy()));
        v.jobs = keep;
        for seq in add {
            if !v.jobs.iter().any(|x| x.seq == seq) { v.jobs.push(JobState { status: "queued".into(), seq, ..Default::default() }); }
        }
        for job in gone { Self::retire(v, job); }
        self.keys_changed(item_id);
    }
    /// The queue added the job of the key (`loading`: it's loading the video first)
    pub fn set_key_job(&mut self, item_id: u32, seq: QString, job_id: u32, loading: bool) {
        let seq = seq.to_string();
        let Some(v) = self.video_mut(item_id) else { return; };
        let Some(job) = v.jobs.iter_mut().find(|x| x.seq == seq && x.job_id == 0) else { return; };
        job.job_id = job_id;
        job.loading = loading;
        self.keys_changed(item_id);
    }
    /// The job loaded the video, it can be the base of the other jobs of the video now (or be removed if it's retired)
    pub fn job_loaded(&mut self, job_id: u32) {
        if job_id == 0 { return; }
        let mut item = 0;
        for v in self.all_videos_mut() {
            for x in v.jobs.iter_mut().filter(|x| x.job_id == job_id) { x.loading = false; item = v.id; }
            for x in v.retired.iter_mut().filter(|x| x.job_id == job_id) { x.loading = false; item = v.id; }
        }
        if item > 0 { self.keys_changed(item); }
    }
    /// The queue removed the retired job (or it's left alone, eg. it's rendering)
    pub fn forget_retired(&mut self, item_id: u32, job_id: u32) {
        if let Some(v) = self.video_mut(item_id) { v.retired.retain(|x| x.job_id != job_id); }
    }
    /// What the render queue has to do, JSON `[{ item_id, url, pending: [seq], base_job, loading, retired: [{ job_id, loading }] }]`:
    /// `pending` are the keys without a job, which get one from `base_job` (a job of the video that has it loaded, 0 if
    /// there's none) or by loading the video if no job is `loading` it already
    pub fn get_queue_work(&self) -> QString {
        let work = self.all_videos().filter(|v| v.jobs.iter().any(|x| x.job_id == 0) || !v.retired.is_empty()).map(|v| {
            let base_job = v.jobs.iter().map(|x| (x.job_id, x.loading)).chain(v.retired.iter().map(|x| (x.job_id, x.loading)))
                .find(|x| x.0 > 0 && !x.1).map(|x| x.0).unwrap_or_default();
            let loading = v.jobs.iter().any(|x| x.loading) || v.retired.iter().any(|x| x.loading);
            serde_json::json!({
                "item_id": v.id,
                "url": v.url,
                "pending": v.jobs.iter().filter(|x| x.job_id == 0).map(|x| x.seq.clone()).collect::<Vec<_>>(),
                "base_job": base_job,
                "loading": loading,
                "retired": v.retired.iter().map(|x| serde_json::json!({ "job_id": x.job_id, "loading": x.loading })).collect::<Vec<_>>(),
            })
        }).collect::<Vec<_>>();
        QString::from(serde_json::Value::Array(work).to_string())
    }
    /// Queue state of the keys of the video, JSON `{ seq: status }`: "queued" (also while its job is added or loads the
    /// video), "processing", "rendering", "done", "error" or "question"
    pub fn get_key_states(&self, item_id: u32) -> QString {
        let states = self.video(item_id).map(|v| v.jobs.iter().map(|x| (x.seq.clone(), serde_json::Value::String(Self::key_state(x)))).collect::<serde_json::Map<_, _>>()).unwrap_or_default();
        QString::from(serde_json::Value::Object(states).to_string())
    }

    pub fn get_item_job_for_seq(&self, item_id: u32, seq: QString) -> u32 {
        let seq = seq.to_string();
        self.video(item_id).and_then(|v| v.jobs.iter().find(|x| x.seq == seq)).map(|x| x.job_id).unwrap_or_default()
    }
    pub fn get_job_seq(&self, job_id: u32) -> QString {
        self.all_videos().flat_map(|v| v.jobs.iter()).find(|x| x.job_id == job_id).map(|x| QString::from(x.seq.as_str())).unwrap_or_default()
    }
    pub fn get_range_index_of_seq(&self, item_id: u32, seq: QString) -> i32 {
        self.range_index_of_seq(item_id, &seq.to_string())
    }
    /// The seq of the trim range at this index (empty for the whole video), eg. for a job that was added to the queue elsewhere
    pub fn get_seq_of_range(&self, item_id: u32, range_index: i32) -> QString {
        let Some(v) = self.video(item_id) else { return QString::default(); };
        self.outputs(v, None).into_iter().find(|x| x.range_index == range_index).map(|x| QString::from(x.seq)).unwrap_or_default()
    }
    fn set_jobs(&mut self, item_id: u32, jobs: Vec<JobState>) {
        let Some(v) = self.video_mut(item_id) else { return; };
        v.jobs = jobs;
        self.update_job_row(item_id);
        // Whether an item is queued is read from here in several places, let them know it changed
        self.items_changed();
    }
    pub fn get_item_job(&self, item_id: u32) -> u32 {
        self.video(item_id).and_then(|v| v.jobs.iter().find(|x| x.job_id > 0)).map(|x| x.job_id).unwrap_or_default()
    }
    /// The jobs of the keys of the video that have one
    pub fn get_item_jobs(&self, item_id: u32) -> QVariantList {
        QVariantList::from_iter(self.video(item_id).map(|v| v.jobs.iter().filter(|x| x.job_id > 0).map(|x| x.job_id).collect::<Vec<_>>()).unwrap_or_default())
    }
    /// The status of the video, summarized over all of its jobs
    pub fn get_item_job_status(&self, item_id: u32) -> QString {
        self.video(item_id).map(|v| QString::from(Self::job_summary(&v.jobs).status.as_str())).unwrap_or_default()
    }
    pub fn get_job_status(&self, job_id: u32) -> QString {
        self.all_videos().find_map(|v| v.jobs.iter().find(|x| x.job_id == job_id)).map(|x| QString::from(x.status.as_str())).unwrap_or_default()
    }
    pub fn is_library_job(&self, job_id: u32) -> bool {
        self.item_id_for_job(job_id) > 0
    }
    pub fn get_item_for_job(&self, job_id: u32) -> u32 {
        self.item_id_for_job(job_id)
    }
    fn item_id_for_job(&self, job_id: u32) -> u32 {
        if job_id == 0 { return 0; }
        // Retired jobs are still the video's until the queue removed them, they aren't jobs of others
        self.all_videos().find(|v| v.jobs.iter().any(|x| x.job_id == job_id) || v.retired.iter().any(|x| x.job_id == job_id)).map(|v| v.id).unwrap_or_default()
    }
    fn job_mut(&mut self, job_id: u32) -> Option<&mut JobState> {
        if job_id == 0 { return None; }
        self.all_videos_mut().find_map(|v| v.jobs.iter_mut().find(|x| x.job_id == job_id))
    }

    pub fn update_job_progress(&mut self, job_id: u32, progress: f64, finished: bool) {
        let item_id = self.item_id_for_job(job_id);
        if item_id == 0 { return; }
        let Some(job) = self.job_mut(job_id) else { return; };
        if job.status == "error" || job.status == "question" { return; }
        job.progress = progress;
        job.status = if finished { "done".into() } else { "rendering".into() };
        let (hash, seq) = (job.hash.clone(), job.seq.clone());
        if finished {
            // The rendered file contains the hash of the settings it was rendered with
            if let Some(v) = self.video(item_id) {
                if let Some(output) = self.outputs(v, None).into_iter().find(|x| x.seq == seq) {
                    let url = output.url();
                    let hash = if hash.is_empty() { Self::output_hash(&v.settings, output.range_index) } else { hash };
                    if let Some(v) = self.video_mut(item_id) { v.output_hashes.insert(url, hash); }
                }
            }
            self.update_stabilized_row(item_id);
        }
        self.update_job_row(item_id);
    }
    /// Progress of the loading and synchronization phase, before the rendering starts
    pub fn set_job_processing(&mut self, job_id: u32, progress: f64) {
        let item_id = self.item_id_for_job(job_id);
        let Some(job) = self.job_mut(job_id) else { return; };
        if job.status == "error" || job.status == "question" || job.status == "done" { return; }
        job.progress = progress;
        job.status = "processing".into();
        self.update_job_row(item_id);
    }
    pub fn set_job_error(&mut self, job_id: u32, err: QString) {
        let item_id = self.item_id_for_job(job_id);
        let Some(job) = self.job_mut(job_id) else { return; };
        job.status = "error".into();
        job.error = err.to_string();
        self.update_job_row(item_id);
    }
    /// The error string of the render queue item, which can be an error, a question (`convert_format:`, `file_exists:`)
    /// or just an informational note (`uses_cpu`). An empty string clears the previous one.
    pub fn set_job_error_string(&mut self, job_id: u32, error_string: QString) {
        let item_id = self.item_id_for_job(job_id);
        let err = error_string.to_string();
        let is_question = err.starts_with("convert_format:") || err.starts_with("file_exists:");
        let Some(job) = self.job_mut(job_id) else { return; };
        if err == "uses_cpu" {
            job.message = err;
        } else {
            job.message = String::new();
            job.error = err.clone();
            if is_question {
                job.status = "question".into();
            } else if !err.is_empty() {
                job.status = "error".into();
            } else if job.status == "error" || job.status == "question" {
                job.status = "queued".into();
            }
        }
        self.update_job_row(item_id);
    }
    pub fn clear_job_statuses(&mut self) {
        let mut ids = Vec::new();
        for v in self.all_videos_mut() {
            if !v.jobs.iter().any(|x| x.is_busy()) && !v.jobs.is_empty() {
                v.jobs.clear();
                ids.push(v.id);
            }
        }
        for id in ids { self.update_job_row(id); }
        self.items_changed();
    }
    pub fn active_job_count(&self) -> usize {
        self.all_videos().map(|v| v.jobs.iter().filter(|x| x.is_active()).count()).sum()
    }
}

#[cfg(test)]
mod tests {
    use qmetaobject::QString;
    use super::{ MediaLibrary, Video };

    fn hash(settings: serde_json::Value, range_index: i32) -> String {
        MediaLibrary::output_hash(&Some(settings.to_string()), range_index)
    }
    fn hash_settings() -> serde_json::Value {
        serde_json::json!({
            "video_info": { "fps": 25.0, "duration_ms": 10000.0, "num_frames": 250 },
            "stabilization": { "fov": 1.0, "method": "Default" },
            "output": { "codec": "H.265/HEVC", "bitrate": 100, "output_folder": "file:///a/", "output_filename": "x.mp4" },
            "background_mode": 0, "background_margin": 20.0,
            "trim_ranges_ms": [[1000.0, 2000.0], [5000.0, 6000.0]],
            "trim_range_info": [{ "output_path": "a-001" }, { "output_path": "a-002" }],
        })
    }
    #[test]
    fn output_hash_covers_what_goes_into_the_file() {
        let base = hash_settings();
        let h = hash(base.clone(), 0);
        assert!(!h.is_empty());
        // Where the file is and the order of the keys don't change what's in it
        let mut moved = base.clone();
        moved["output"]["output_folder"] = "file:///b/".into();
        moved["output"]["output_filename"] = "y.mp4".into();
        moved["trim_range_info"][0]["output_path"] = "elsewhere".into();
        assert_eq!(hash(moved, 0), h);
        let reordered: serde_json::Value = serde_json::from_str(&base.to_string().replace("\"fov\":1.0,\"method\":\"Default\"", "\"method\":\"Default\",\"fov\":1.0")).unwrap();
        assert_eq!(hash(reordered, 0), h);
        // Everything that changes the pixels does
        for (path, value) in [("/stabilization/fov", serde_json::json!(1.1)), ("/output/bitrate", serde_json::json!(50)), ("/background_mode", serde_json::json!(1))] {
            let mut changed = base.clone();
            *changed.pointer_mut(path).unwrap() = value;
            assert_ne!(hash(changed, 0), h, "{path}");
        }
        // The frames of the range: its own bounds, not the ones of the other ranges
        let mut moved_range = base.clone();
        moved_range["trim_ranges_ms"][0][1] = 2100.0.into();
        assert_ne!(hash(moved_range.clone(), 0), h);
        assert_eq!(hash(moved_range, 1), hash(base.clone(), 1));
        assert_ne!(hash(base.clone(), 0), hash(base.clone(), 1));
        // Joined into one file, it's all of them
        assert_ne!(hash(base.clone(), -1), h);
        assert_eq!(MediaLibrary::output_hash(&None, 0), "");
    }
    #[test]
    fn a_range_with_its_own_settings_has_its_own_hash() {
        let base = hash_settings();
        let mut own = base.clone();
        own["trim_range_config"] = "separate".into();
        own["trim_range_info"][1]["stabilization"] = serde_json::json!({ "fov": 2.0, "method": "Default" });
        assert_eq!(hash(own.clone(), 0), hash(base.clone(), 0));
        assert_ne!(hash(own, 1), hash(base, 1));
    }

    #[test]
    fn trim_ranges_are_extended_and_moved_within_the_video() {
        let m = |r, l, ri, sh| MediaLibrary::modified_trim_range(r, 10000.0, l, ri, sh);
        assert_eq!(m((2000.0, 4000.0), 500.0, 0.0, 0.0), (1500.0, 4000.0));
        assert_eq!(m((2000.0, 4000.0), 0.0, 500.0, 0.0), (2000.0, 4500.0));
        assert_eq!(m((2000.0, 4000.0), 0.0, 0.0, -1000.0), (1000.0, 3000.0));
        assert_eq!(m((2000.0, 4000.0), 0.0, 0.0, 1000.0), (3000.0, 5000.0));
        // Not before the start or after the end of the video
        assert_eq!(m((500.0, 4000.0), 1000.0, 0.0, 0.0), (0.0, 4000.0));
        assert_eq!(m((8000.0, 9500.0), 0.0, 0.0, 1000.0), (9000.0, 10000.0));
        // A range that would be gone stays as it is
        assert_eq!(m((9000.0, 9500.0), 0.0, 0.0, 2000.0), (9000.0, 9500.0));
    }

    #[test]
    fn hidden_files_are_not_videos() {
        assert!(MediaLibrary::is_video_file("GX012216.MP4"));
        assert!(MediaLibrary::is_video_file("GX012216_joined.ffconcat"));
        assert!(!MediaLibrary::is_video_file("._GX012216_joined.ffconcat"));
        assert!(!MediaLibrary::is_video_file("._GX032218.MP4"));
    }

    #[test]
    fn files_of_a_joined_video_added_with_it_are_not_listed_alone() {
        let mut lib = MediaLibrary::default();
        let part = |url: &str| super::JoinedPart { url: url.into(), ..Default::default() };
        lib.standalone.push(Video { id: 1, url: "file:///a/GX012216_joined.ffconcat".into(), parts: vec![part("file:///a/GX012216.MP4"), part("file:///a/GX022216.MP4")], ..Default::default() });
        lib.standalone.push(Video { id: 2, url: "file:///a/GX012216.MP4".into(), ..Default::default() });
        lib.standalone.push(Video { id: 3, url: "file:///a/GX022216.MP4".into(), ..Default::default() });
        lib.standalone.push(Video { id: 4, url: "file:///a/GX012217.MP4".into(), ..Default::default() });
        lib.remove_joined_parts();
        assert_eq!(lib.standalone.iter().map(|v| v.id).collect::<Vec<_>>(), vec![1, 4]);
    }

    #[test]
    fn dji_files_are_one_recording_when_the_next_starts_where_the_previous_ends() {
        assert_eq!(MediaLibrary::dji_dated_part("DJI_20261005132932_0003_D.MP4").map(|x| (x.0, x.1)), Some(("D".into(), 3)));
        assert_eq!(MediaLibrary::dji_dated_part("._DJI_20261005132932_0003_D.MP4"), None);
        assert_eq!(MediaLibrary::dji_dated_part("DJI_0012_001.MP4"), None);
        // From an Osmo Action 4: 0003 to 0005 is one recording, 0001 and 0002 were started one after another by hand
        let files = [("20261005132544_0001", 55330.0), ("20261005132707_0002", 87120.0), ("20261005132932_0003", 217090.0),
                     ("20261005133310_0004", 217120.0), ("20261005133647_0005", 22500.0), ("20261005152827_0006", 0.0)]
            .map(|(name, duration_ms)| (format!("DJI_{name}_D.MP4"), format!("file:///card/DJI_{name}_D.MP4"), duration_ms));
        let mut lib = MediaLibrary::default();
        for (i, (filename, url, duration_ms)) in files.iter().enumerate() {
            lib.standalone.push(Video { id: i as u32 + 1, url: url.clone(), filename: filename.clone(), duration_ms: *duration_ms, ..Default::default() });
        }
        let list = files.iter().map(|x| (x.0.clone(), x.1.clone())).collect::<Vec<_>>();
        let added = |names: &[usize]| names.iter().map(|i| files[*i].1.clone()).collect();
        let expected = vec![vec![files[2].1.clone(), files[3].1.clone(), files[4].1.clone()]];
        assert_eq!(lib.dji_split_recordings(&list, &added(&[0, 1, 2, 3, 4, 5])), expected);
        assert_eq!(lib.dji_split_recordings(&list, &added(&[4])), expected);
        assert!(lib.dji_split_recordings(&list, &added(&[0, 1])).is_empty());
    }

    fn outputs(settings: serde_json::Value) -> Vec<(i32, String)> {
        let lib = MediaLibrary::default();
        let v = Video { url: "file:///videos/C0001.MP4".into(), filename: "C0001.MP4".into(), settings: Some(settings.to_string()), ..Default::default() };
        lib.outputs(&v, Some(".mp4")).into_iter().map(|x| (x.range_index, x.filename)).collect()
    }

    #[test]
    fn one_output_file_per_trim_range() {
        // No trim ranges: the whole video
        assert_eq!(outputs(serde_json::json!({ })), vec![(-1, "C0001.mp4".into())]);
        // Each range has its own path
        assert_eq!(outputs(serde_json::json!({
            "trim_ranges_ms": [[0, 1000], [2000, 3000]],
            "trim_range_info": [{ "output_path": "C0001-001" }, { "output_path": "runs/second" }]
        })), vec![(0, "C0001-001.mp4".into()), (1, "second.mp4".into())]);
        // Joined into one video
        assert_eq!(outputs(serde_json::json!({ "trim_ranges_ms": [[0, 1000], [2000, 3000]], "output": { "export_trims_separately": false } })), vec![(-1, "C0001.mp4".into())]);
    }

    #[test]
    fn motion_data_is_loaded_from_the_video_by_default() {
        let mut lib = MediaLibrary::default();
        lib.standalone.push(Video { id: 1, url: "file:///videos/GX012176.MP4".into(), settings: Some(serde_json::json!({ "trim_ranges_ms": [[0, 1000]] }).to_string()), ..Default::default() });
        let obj: serde_json::Value = serde_json::from_str(&lib.get_project_data(1).to_string()).unwrap();
        assert_eq!(obj["gyro_source"]["filepath"], "file:///videos/GX012176.MP4");
        // A separate gyro file is kept
        lib.standalone[0].settings = Some(serde_json::json!({ "gyro_source": { "filepath": "file:///videos/log.gcsv" } }).to_string());
        let obj: serde_json::Value = serde_json::from_str(&lib.get_project_data(1).to_string()).unwrap();
        assert_eq!(obj["gyro_source"]["filepath"], "file:///videos/log.gcsv");
    }

    #[test]
    fn gopro_proxies_are_not_videos() {
        assert!(MediaLibrary::is_video_file("GX012176.MP4"));
        assert!(!MediaLibrary::is_video_file("GL012176.LRV"));
        assert!(!MediaLibrary::is_video_file("GL012176.THM"));
    }

    #[test]
    fn ranges_without_a_path_get_the_next_free_number() {
        let mut obj = serde_json::json!({
            "trim_ranges_ms": [[0, 1000], [2000, 3000], [4000, 5000]],
            "trim_range_info": [{ }, { "output_path": "clip_stabilized-001" }]
        });
        MediaLibrary::assign_range_paths(&mut obj, "clip_stabilized");
        let paths = obj["trim_range_info"].as_array().unwrap().iter().map(|x| x["output_path"].as_str().unwrap().to_owned()).collect::<Vec<_>>();
        assert_eq!(paths, vec!["clip_stabilized-002", "clip_stabilized-001", "clip_stabilized-003"]);
    }

    #[test]
    fn a_range_keeps_its_queue_key_when_others_are_removed() {
        let mut obj = serde_json::json!({ "trim_ranges_ms": [[0, 1000], [2000, 3000], [4000, 5000]] });
        MediaLibrary::assign_range_paths(&mut obj, "clip_stabilized");
        let uids = (0..3).map(|i| MediaLibrary::range_uid(&obj, i)).collect::<Vec<_>>();
        assert!(uids.iter().all(|x| x.len() == 16) && uids[0] != uids[1] && uids[1] != uids[2]);
        // Assigning the paths again (every save does) keeps the ids
        MediaLibrary::assign_range_paths(&mut obj, "clip_stabilized");
        assert_eq!((0..3).map(|i| MediaLibrary::range_uid(&obj, i)).collect::<Vec<_>>(), uids);

        // The first range is removed in the timeline: the last one is at index 1 now, and its key still finds it there
        obj["trim_ranges_ms"].as_array_mut().unwrap().remove(0);
        obj["trim_range_info"].as_array_mut().unwrap().remove(0);
        let mut lib = MediaLibrary::default();
        lib.standalone.push(Video { id: 1, url: "file:///videos/C0001.MP4".into(), settings: Some(obj.to_string()), ..Default::default() });
        assert_eq!(lib.range_index_of_seq(1, &uids[2]), 1);
        assert_eq!(lib.range_index_of_seq(1, &uids[0]), -2);
        assert_eq!(lib.range_index_of_seq(1, ""), -1);
        assert_eq!(lib.get_seq_of_range(1, 0).to_string(), uids[1]);
    }

    fn library_with_ranges(ranges: usize, separate: bool) -> (MediaLibrary, Vec<String>) {
        let mut obj = serde_json::json!({
            "trim_ranges_ms": (0..ranges).map(|i| [i as f64 * 2000.0, i as f64 * 2000.0 + 1000.0]).collect::<Vec<_>>(),
            "output": { "export_trims_separately": separate }
        });
        MediaLibrary::assign_range_paths(&mut obj, "C0001_stabilized");
        let uids = (0..ranges).map(|i| MediaLibrary::range_uid(&obj, i)).collect();
        let mut lib = MediaLibrary::default();
        lib.standalone.push(Video { id: 1, url: "file:///videos/C0001.MP4".into(), settings: Some(obj.to_string()), ..Default::default() });
        (lib, uids)
    }
    fn set_mode(lib: &mut MediaLibrary, separate: bool) {
        let mut obj: serde_json::Value = serde_json::from_str(lib.standalone[0].settings.as_ref().unwrap()).unwrap();
        obj["output"]["export_trims_separately"] = serde_json::json!(separate);
        lib.standalone[0].settings = Some(obj.to_string());
        lib.reconcile_keys(1);
    }
    fn keys(lib: &MediaLibrary) -> Vec<(String, u32)> {
        lib.standalone[0].jobs.iter().map(|x| (x.seq.clone(), x.job_id)).collect()
    }

    #[test]
    fn queue_keys_follow_the_export_mode() {
        let (mut lib, uids) = library_with_ranges(2, true);
        assert!(lib.enqueue(1, QString::from(uids[1].as_str())));
        assert!(!lib.enqueue(1, QString::from(uids[1].as_str())), "a key is in the set once");
        assert!(!lib.enqueue(1, QString::from("")), "the whole video isn't a key while the ranges are separate videos");
        lib.set_key_job(1, QString::from(uids[1].as_str()), 11, false);
        assert_eq!(keys(&lib), vec![(uids[1].clone(), 11)]);

        // Joined: the whole video replaces the queued range, whose job is removed by the queue
        set_mode(&mut lib, false);
        assert_eq!(keys(&lib), vec![(String::new(), 0)]);
        assert_eq!(lib.standalone[0].retired.iter().map(|x| x.job_id).collect::<Vec<_>>(), vec![11]);
        let work: serde_json::Value = serde_json::from_str(&lib.get_queue_work().to_string()).unwrap();
        assert_eq!(work[0]["pending"], serde_json::json!([""]));
        assert_eq!(work[0]["base_job"], 11, "the new job is added from the loaded video of the retired one");
        lib.set_key_job(1, QString::from(""), 12, false);
        lib.forget_retired(1, 11);

        // Separate again: all ranges are queued
        set_mode(&mut lib, true);
        assert_eq!(keys(&lib), vec![(uids[0].clone(), 0), (uids[1].clone(), 0)]);
        let states: serde_json::Value = serde_json::from_str(&lib.get_key_states(1).to_string()).unwrap();
        assert_eq!(states, serde_json::json!({ uids[0].clone(): "queued", uids[1].clone(): "queued" }));
    }

    #[test]
    fn deleted_ranges_leave_the_queue_but_rendering_jobs_stay() {
        let (mut lib, uids) = library_with_ranges(3, true);
        lib.enqueue_all(1);
        for (i, uid) in uids.iter().enumerate() { lib.set_key_job(1, QString::from(uid.as_str()), 20 + i as u32, false); }
        lib.standalone[0].jobs[1].status = "rendering".into();
        assert!(!lib.dequeue(1, QString::from(uids[1].as_str())), "a rendering job can't be taken out");

        // Ranges 0 and 1 deleted in the timeline
        let mut obj: serde_json::Value = serde_json::from_str(lib.standalone[0].settings.as_ref().unwrap()).unwrap();
        obj["trim_ranges_ms"].as_array_mut().unwrap().drain(0..2);
        obj["trim_range_info"].as_array_mut().unwrap().drain(0..2);
        lib.standalone[0].settings = Some(obj.to_string());
        lib.reconcile_keys(1);
        assert_eq!(keys(&lib), vec![(uids[1].clone(), 21), (uids[2].clone(), 22)]);
        assert_eq!(lib.standalone[0].retired.iter().map(|x| x.job_id).collect::<Vec<_>>(), vec![20]);
    }

    #[test]
    fn a_loading_job_renders_a_waiting_key_when_its_own_is_dequeued() {
        let (mut lib, uids) = library_with_ranges(2, true);
        lib.enqueue_all(1);
        lib.set_key_job(1, QString::from(uids[0].as_str()), 30, true);
        assert!(lib.dequeue(1, QString::from(uids[0].as_str())));
        assert_eq!(keys(&lib), vec![(uids[1].clone(), 30)]);
        assert!(lib.standalone[0].retired.is_empty());
        // Without a waiting key it's removed once it's loaded
        assert!(lib.dequeue(1, QString::from(uids[1].as_str())));
        assert!(keys(&lib).is_empty());
        let work: serde_json::Value = serde_json::from_str(&lib.get_queue_work().to_string()).unwrap();
        assert_eq!(work[0]["retired"], serde_json::json!([{ "job_id": 30, "loading": true }]));
        lib.job_loaded(30);
        assert!(!lib.standalone[0].retired[0].loading);
    }

    #[test]
    fn default_output_path_is_relative_without_extension() {
        assert_eq!(MediaLibrary::default_output_filename("C0001.MP4", "_stabilized"), "C0001_stabilized");
        assert_eq!(MediaLibrary::default_output_filename("my.clip.mov", "_stabilized"), "my.clip_stabilized");
    }

    #[test]
    fn output_extension_follows_the_codec() {
        let input = "file:///videos/my.clip.MP4";
        assert_eq!(MediaLibrary::with_output_extension("my.clip_stabilized", input, ".mov"), "my.clip_stabilized.mov");
        assert_eq!(MediaLibrary::with_output_extension("out.mp4", input, ".mov"), "out.mov");
        assert_eq!(MediaLibrary::with_output_extension("out.MP4", input, ".mp4"), "out.mp4");
        assert_eq!(MediaLibrary::with_output_extension("out_%05d.png", input, ".mp4"), "out.mp4");
        assert_eq!(MediaLibrary::with_output_extension("out", input, "_%05d.exr"), "out_%05d.exr");
    }

    #[test]
    fn output_path_is_stored_without_extension() {
        let mut lib = MediaLibrary::default();
        lib.standalone.push(Video { id: 1, url: "file:///videos/C0003.MP4".into(), filename: "C0003.MP4".into(), ..Default::default() });
        // The output file of a job restored from the previous session, its trim ranges get their own files next to it
        lib.set_output_url(1, "file:///videos/".into(), "C0003_stabilized.mp4".into());
        assert_eq!(lib.get_output_path(1).to_string(), "C0003_stabilized");
        lib.set_output_path(1, "runs/clip.MOV".into());
        assert_eq!(lib.get_output_path(1).to_string(), "runs/clip");
        lib.set_output_path(1, "my.clip".into());
        assert_eq!(lib.get_output_path(1).to_string(), "my.clip");
    }
}
