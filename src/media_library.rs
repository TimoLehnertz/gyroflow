// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2025 Adrian <adrian.eddy at gmail>

use qmetaobject::*;

use crate::{ core, marker_import, rendering, util };
use crate::core::StabilizationManager;
use core::filesystem;
use std::sync::Arc;
use std::sync::atomic::{ AtomicBool, AtomicUsize, Ordering::SeqCst };
use std::cell::RefCell;

const VIDEO_EXTENSIONS: &[&str] = &[ "mp4", "mov", "mxf", "mkv", "webm", "insv", "avi", "m4v", "mts", "m2ts", "lrv", "braw", "r3d", "nev" ];

// Stabilized state
const NOT_STABILIZED: i32 = 0;
const STABILIZED:     i32 = 1;
const STALE:          i32 = 2;

#[derive(Default, Clone, SimpleListItem, Debug)]
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
    pub marker_unmatched: bool,
    pub scanning: bool,
    pub stabilized_state: i32,
    pub job_status: QString, // "" | queued | processing | rendering | done | error | question
    pub job_progress: f64,
    pub error_string: QString,
    pub job_message: QString,
    /// First job of the video, all of them are returned by `get_item_jobs`
    pub job_id: u32,
    pub job_count: i32,
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
    /// The trim range the job renders, -1 if it renders the whole video (or all of its ranges joined)
    range_index: i32
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
    marker_unmatched: bool,
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
    jobs: Vec<JobState>
}

/// A file the video is exported to: one per trim range if they are exported as separate videos, otherwise one for the whole video
#[derive(Clone, Debug)]
struct OutputFile {
    range_index: i32,
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

#[derive(Default, QObject)]
pub struct MediaLibrary {
    base: qt_base_class!(trait QObject),

    pub items: qt_property!(RefCell<SimpleListModel<MediaItem>>; NOTIFY items_changed),

    add_folder: qt_method!(fn(&mut self, url: QString)),
    add_files: qt_method!(fn(&mut self, urls: QStringList)),
    add_url: qt_method!(fn(&mut self, url: QString)),
    add_dropped: qt_method!(fn(&mut self, urls: QStringList)),
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
    get_item_url: qt_method!(fn(&self, item_id: u32) -> QString),
    get_item_name: qt_method!(fn(&self, item_id: u32) -> QString),
    is_item_url: qt_method!(fn(&self, item_id: u32, url: QString) -> bool),
    find_by_url: qt_method!(fn(&self, url: QString) -> u32),
    get_item_index: qt_method!(fn(&self, item_id: u32) -> i32),

    load_markers: qt_method!(fn(&mut self, url: QString) -> QString),
    preview_markers: qt_method!(fn(&self, offset_seconds: f64) -> QString),
    import_markers: qt_method!(fn(&mut self, offset_seconds: f64) -> QString),
    get_timeline_markers: qt_method!(fn(&self, item_id: u32) -> QString),

    save_settings: qt_method!(fn(&mut self, item_id: u32, data: QString)),
    get_project_data: qt_method!(fn(&self, item_id: u32) -> QString),
    get_settings_for_job: qt_method!(fn(&self, job_id: u32) -> QString),
    get_range_settings: qt_method!(fn(&self, item_id: u32, range_index: i32) -> QString),
    apply_stabilization_to_all: qt_method!(fn(&mut self, data: QString, except_item_id: u32) -> usize),
    apply_settings_to_queued: qt_method!(fn(&mut self, data: QString) -> QVariantList),
    settings_hash: qt_method!(fn(&self, item_id: u32) -> QString),
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
    set_item_jobs: qt_method!(fn(&mut self, item_id: u32, job_ids: QVariantList, range_indexes: QVariantList)),
    add_item_job: qt_method!(fn(&mut self, item_id: u32, job_id: u32, range_index: i32)),
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

    standalone: Vec<Video>,
    folders: Vec<Folder>,

    next_id: u32,
    pending_scans: Arc<AtomicUsize>,
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
            name: QString::from(v.filename.as_str()),
            url: QString::from(v.url.as_str()),
            output_path: QString::from(self.output_path_or_default(&v.url, &v.output_path)),
            display_output_path: QString::from(match outputs.as_slice() {
                [one] => filesystem::display_folder_filename(&one.folder, &one.filename),
                _ => filesystem::display_folder_filename(&folder, &filename)
            }),
            expanded: v.expanded,
            has_children: false,
            selected: v.selected,
            is_current: self.current_item == v.id,
            created_at: v.created_at,
            duration_ms: v.duration_ms,
            range_count: Self::range_info(&v.settings).0 as i32,
            output_count: outputs.len() as i32,
            lens_profile: QString::from(v.lens_profile.as_str()),
            lens_warning: v.lens_warning,
            marker_unmatched: v.marker_unmatched,
            scanning: v.scanning,
            stabilized_state: self.stabilized_state(v, &outputs),
            job_status: QString::from(job.status.as_str()),
            job_progress: job.progress,
            error_string: QString::from(job.error.as_str()),
            job_message: QString::from(job.message.as_str()),
            job_id: job.job_id,
            job_count: v.jobs.len() as i32,
        }
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
        self.patch_row(video_id, |x| {
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

    fn rebuild(&mut self) {
        let items = self.build_items();
        self.items.borrow_mut().reset_data(items);
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
        let id = self.new_id();
        let path = filesystem::url_to_path(&url);
        let mut name = path.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or_default().to_string();
        if name.is_empty() { name = filesystem::display_url(&url); }
        self.folders.push(Folder { id, url, name, expanded: true, videos });
        self.rebuild();
        self.scan_pending();
    }

    pub fn add_files(&mut self, urls: QStringList) {
        let n = urls.len();
        for i in 0..n {
            self.add_url_impl(&urls[i].to_string(), false);
        }
        self.rebuild();
        self.scan_pending();
    }

    /// One file or folder. QML should call this instead of passing a JS array as QStringList,
    /// which qmetaobject turns into empty strings.
    pub fn add_url(&mut self, url: QString) {
        self.add_url_impl(&url.to_string(), true);
    }

    /// Adds dropped urls, folders are added as input folders and files as standalone videos
    pub fn add_dropped(&mut self, urls: QStringList) {
        let n = urls.len();
        for i in 0..n {
            self.add_url_impl(&urls[i].to_string(), false);
        }
        self.rebuild();
        self.scan_pending();
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
            self.rebuild();
            self.scan_pending();
        }
    }

    fn new_video(&mut self, url: String, filename: String) -> Video {
        let id = self.new_id();
        Video {
            id,
            url,
            filename,
            scanning: true,
            expanded: true,
            ..Default::default()
        }
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

        core::run_threaded(move || {
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
                    if let Ok(mut file) = filesystem::open_file(&url, false, false) {
                        let filesize = file.size;
                        let md = core::gyro_source::GyroSource::parse_telemetry_file(file.get_file(), filesize, &url, &Default::default(), size, fps, |_| (), Arc::new(AtomicBool::new(false)));
                        if let Ok(md) = md {
                            if md.lens_profile.as_ref().map(|x| x.is_object()).unwrap_or_default() {
                                result.lens_profile = "Built-in".to_string();
                                result.lens_warning = false;
                            } else {
                                let id_str = md.camera_identifier.as_ref().map(|x| x.get_identifier_for_autoload()).unwrap_or_default();
                                if !id_str.is_empty() {
                                    {
                                        let db = lens_db.read();
                                        if !db.loaded { drop(db); lens_db.write().load_all(); }
                                    }
                                    let db = lens_db.read();
                                    if let Some(profile) = db.get_by_id(&id_str) {
                                        result.lens_profile = profile.get_display_name();
                                        result.lens_warning = false;
                                    }
                                }
                            }
                        }
                    }
                }
                pending.fetch_sub(1, SeqCst);
                scanned((video_id, result));
            }
            finished(());
        });
    }

    /// Checks which of the output files already exist and reads the stabilization hash from them
    pub fn refresh_outputs(&mut self) {
        let to_check = self.all_videos().map(|v| (v.id, self.outputs(v, None).iter().map(|x| x.url()).collect::<Vec<_>>())).collect::<Vec<_>>();
        if to_check.is_empty() { return; }

        let checked = util::qt_queued_callback_mut(QPointer::from(self as &Self), move |this, (video_id, hashes): (u32, Vec<(String, Option<String>)>)| {
            let Some(v) = this.video_mut(video_id) else { return; };
            v.output_hashes = hashes.into_iter().filter_map(|(url, hash)| Some((url, hash?))).collect();
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
    pub fn select_all(&mut self, selected: bool) {
        for v in self.all_videos_mut() {
            Self::select_video(v, selected);
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

    /// Read and validate a markers.json file. Preview and import then use the cached markers.
    pub fn load_markers(&mut self, url: QString) -> QString {
        self.markers.clear();
        self.marker_file_loaded = false;
        let path = filesystem::url_to_path(&Self::to_url(&url.to_string(), false));
        let json = match std::fs::read_to_string(&path) {
            Ok(json) => json,
            Err(e) => return Self::marker_error(format!("Could not read markers file: {e}")),
        };
        match marker_import::parse(&json) {
            Ok(markers) => {
                let ins = markers.iter().filter(|m| matches!(m, marker_import::Marker::In { .. })).count();
                let outs = markers.iter().filter(|m| matches!(m, marker_import::Marker::Out { .. })).count();
                self.markers = markers;
                self.marker_file_loaded = true;
                QString::from(serde_json::json!({
                    "name": filesystem::get_filename(&url.to_string()),
                    "count": self.markers.len(), "ins": ins, "outs": outs,
                }).to_string())
            }
            Err(e) => Self::marker_error(e),
        }
    }

    /// Match cached markers against the current videos without changing the sidebar.
    pub fn preview_markers(&self, offset_seconds: f64) -> QString {
        match self.marker_plan(offset_seconds) {
            Ok(plan) => QString::from(self.marker_preview_json(&plan)),
            Err(e) => Self::marker_error(e),
        }
    }

    /// Apply cached markers to the library. Returns a JSON summary for the UI.
    pub fn import_markers(&mut self, offset_seconds: f64) -> QString {
        if self.scanning { return Self::marker_error("Wait for video scanning to finish before importing markers.".into()); }
        let plan = match self.marker_plan(offset_seconds) {
            Ok(plan) => plan,
            Err(e) => return Self::marker_error(e),
        };
        let mut summary: serde_json::Value = serde_json::from_str(&self.marker_preview_json(&plan)).unwrap_or_else(|_| serde_json::json!({}));
        let matched = plan.sections.iter().map(|s| s.video_id).collect::<std::collections::HashSet<_>>();
        for v in self.all_videos_mut() {
            v.marker_unmatched = !matched.contains(&v.id);
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
        let Some(v) = self.video_mut(item_id) else { return; };
        // The trim ranges (and with them the output files) are edited in the timeline of the main view
        let outputs_changed = Self::range_info(&v.settings) != Self::range_info(&Some(data.clone()));
        v.settings = Some(data);
        self.refresh_job_hash(item_id);
        if outputs_changed {
            self.rebuild();
            self.refresh_outputs();
        } else {
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
        let range_index = self.video(item_id).and_then(|v| v.jobs.iter().find(|x| x.job_id == job_id)).map(|x| x.range_index).unwrap_or(-1);
        self.get_range_settings(item_id, range_index)
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
            self.refresh_job_hash(id);
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
            self.refresh_job_hash(id);
        }
        QVariantList::from_iter(ids)
    }

    /// The stabilization settings the video is rendered with, including the ones of its trim ranges if they have their own
    fn effective_stabilization(settings: &Option<String>) -> serde_json::Value {
        let Some(obj) = settings.as_ref().and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok()) else { return serde_json::Value::Null; };
        let stab = obj.get("stabilization").cloned().unwrap_or(serde_json::Value::Null);
        let ranges = (0..Self::trim_ranges_ms(&obj).len()).filter_map(|i| Self::range_stabilization(&obj, i)).collect::<Vec<_>>();
        if ranges.is_empty() { stab } else { serde_json::json!({ "stabilization": stab, "trim_ranges": ranges }) }
    }
    /// Stabilization settings of a trim range, if the video has separate settings for each range
    fn range_stabilization(obj: &serde_json::Value, range_index: usize) -> Option<serde_json::Value> {
        Self::range_setting(obj, range_index, "stabilization")
    }
    /// Export settings of a trim range (without the output path), if the video has separate settings for each range
    fn range_output(obj: &serde_json::Value, range_index: usize) -> Option<serde_json::Value> {
        Self::range_setting(obj, range_index, "output")
    }
    fn range_setting(obj: &serde_json::Value, range_index: usize, key: &str) -> Option<serde_json::Value> {
        if obj.get("trim_range_config").and_then(|x| x.as_str()) != Some("separate") { return None; }
        obj.get("trim_range_info")?.get(range_index)?.get(key).filter(|x| x.is_object()).cloned()
    }
    pub fn settings_hash(&self, item_id: u32) -> QString {
        let settings = self.item_settings(item_id).map(|(_, s, _)| s.clone()).unwrap_or_default();
        QString::from(rendering::render_queue::stabilization_settings_hash(&Self::effective_stabilization(&settings)))
    }
    /// Stabilized when all output files exist and were rendered with the current settings, changed when one of them wasn't
    fn stabilized_state(&self, v: &Video, outputs: &[OutputFile]) -> i32 {
        let current = rendering::render_queue::stabilization_settings_hash(&Self::effective_stabilization(&v.settings));
        let hashes = outputs.iter().map(|x| v.output_hashes.get(&x.url())).collect::<Vec<_>>();
        // Files rendered by older versions don't have the hash, we can't tell if they are up to date
        if hashes.iter().any(|x| x.map_or(false, |hash| !hash.is_empty() && *hash != current)) {
            STALE
        } else if !hashes.is_empty() && hashes.iter().all(|x| x.is_some()) {
            STABILIZED
        } else {
            NOT_STABILIZED
        }
    }
    /// The jobs of a queued video are kept in sync with its settings, so they also render with the new hash
    fn refresh_job_hash(&mut self, item_id: u32) {
        let hash = self.settings_hash(item_id).to_string();
        if let Some(v) = self.video_mut(item_id) {
            for job in v.jobs.iter_mut().filter(|x| x.status == "queued") { job.hash = hash.clone(); }
        }
    }
    fn update_stabilized_row(&mut self, item_id: u32) {
        if let Some(v) = self.video(item_id) {
            let state = self.stabilized_state(v, &self.outputs(v, None));
            self.patch_row(item_id, |x| x.stabilized_state = state);
        }
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
        format!("{stem}{ext}")
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
            return vec![OutputFile { range_index: -1, folder, filename, own_settings: false }];
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
            OutputFile { range_index: i as i32, folder, filename, own_settings }
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
        v.output_path = path;
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
            let count = v.jobs.len();
            v.jobs.retain(|x| x.job_id > 0 && existing.contains(&x.job_id));
            if v.jobs.len() != count { changed.push(v.id); }
        }
        if changed.is_empty() { return; }
        for id in changed { self.update_job_row(id); }
        self.items_changed();
    }

    fn new_job(&self, item_id: u32, job_id: u32, range_index: i32) -> JobState {
        JobState {
            job_id,
            status: "queued".into(),
            hash: self.settings_hash(item_id).to_string(),
            range_index,
            ..Default::default()
        }
    }
    /// The video renders with this one job (or none if it's 0). It renders the whole video until it's split into its trim ranges
    pub fn set_item_job(&mut self, item_id: u32, job_id: u32) {
        let jobs = if job_id > 0 { vec![self.new_job(item_id, job_id, -1)] } else { Vec::new() };
        self.set_jobs(item_id, jobs);
    }
    /// The jobs of the video after it was split into its trim ranges, `range_indexes` are the ranges of the jobs
    pub fn set_item_jobs(&mut self, item_id: u32, job_ids: QVariantList, range_indexes: QVariantList) {
        let parse = |x: &QVariant| x.to_qbytearray().to_string().parse::<i64>().unwrap_or(-1);
        let ranges = range_indexes.into_iter().map(parse).collect::<Vec<_>>();
        let jobs = job_ids.into_iter().map(parse).enumerate().filter(|(_, id)| *id > 0)
            .map(|(i, id)| self.new_job(item_id, id as u32, ranges.get(i).copied().unwrap_or(-1) as i32))
            .collect();
        self.set_jobs(item_id, jobs);
    }
    /// A job of the video that was added to the render queue elsewhere (eg. restored from the previous session)
    pub fn add_item_job(&mut self, item_id: u32, job_id: u32, range_index: i32) {
        if job_id == 0 || self.is_library_job(job_id) { return; }
        let job = self.new_job(item_id, job_id, range_index);
        let Some(v) = self.video_mut(item_id) else { return; };
        // A job of the whole video replaces the others, and the other way around
        v.jobs.retain(|x| (x.range_index < 0) == (range_index < 0));
        v.jobs.push(job);
        self.update_job_row(item_id);
        self.items_changed();
    }
    fn set_jobs(&mut self, item_id: u32, jobs: Vec<JobState>) {
        let Some(v) = self.video_mut(item_id) else { return; };
        v.jobs = jobs;
        self.update_job_row(item_id);
        // Whether an item is queued is read from here in several places, let them know it changed
        self.items_changed();
    }
    pub fn get_item_job(&self, item_id: u32) -> u32 {
        self.video(item_id).and_then(|v| v.jobs.first()).map(|x| x.job_id).unwrap_or_default()
    }
    pub fn get_item_jobs(&self, item_id: u32) -> QVariantList {
        QVariantList::from_iter(self.video(item_id).map(|v| v.jobs.iter().map(|x| x.job_id).collect::<Vec<_>>()).unwrap_or_default())
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
        self.all_videos().find(|v| v.jobs.iter().any(|x| x.job_id == job_id)).map(|v| v.id).unwrap_or_default()
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
        let (hash, range_index) = (job.hash.clone(), job.range_index);
        if finished {
            // The rendered file contains the hash of the settings it was rendered with
            if let Some(v) = self.video(item_id) {
                if let Some(output) = self.outputs(v, None).into_iter().find(|x| x.range_index == range_index) {
                    let url = output.url();
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
    use super::{ MediaLibrary, Video };

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
}
