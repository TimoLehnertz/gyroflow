// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2025 Adrian <adrian.eddy at gmail>

use qmetaobject::*;

use crate::{ core, rendering, util };
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
    pub kind: QString, // folder | video | section
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
    pub trim_start: f64,
    pub trim_end: f64,
    pub lens_profile: QString,
    pub lens_warning: bool,
    pub scanning: bool,
    pub stabilized_state: i32,
    pub job_status: QString, // "" | queued | rendering | done | error
    pub job_progress: f64,
    pub error_string: QString,
    pub job_id: u32,
}

#[derive(Default, Clone, Debug)]
struct JobState {
    job_id: u32,
    status: String,
    progress: f64,
    error: String,
    /// Hash of the stabilization settings this job was queued with
    hash: String
}

#[derive(Default, Clone, Debug)]
struct Section {
    id: u32,
    name: String,
    trim_start: f64,
    trim_end: f64,
    settings: Option<String>,
    output_path: String,
    output_hash: Option<String>,
    selected: bool,
    job: JobState
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
    scanning: bool,
    scan_queued: bool,
    settings: Option<String>,
    output_path: String,
    output_hash: Option<String>,
    expanded: bool,
    selected: bool,
    sections: Vec<Section>,
    job: JobState
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
    add_dropped: qt_method!(fn(&mut self, urls: QStringList)),
    remove_item: qt_method!(fn(&mut self, item_id: u32) -> QVariantList),
    clear: qt_method!(fn(&mut self)),
    has_folder: qt_method!(fn(&self, url: QString) -> bool),

    toggle_expanded: qt_method!(fn(&mut self, item_id: u32)),
    set_selected: qt_method!(fn(&mut self, item_id: u32, selected: bool)),
    select_only: qt_method!(fn(&mut self, item_id: u32)),
    select_all: qt_method!(fn(&mut self, selected: bool)),
    selected_count: qt_method!(fn(&self) -> usize),

    set_current_item: qt_method!(fn(&mut self, item_id: u32)),
    current_item: qt_property!(u32; NOTIFY current_item_changed),
    get_item_kind: qt_method!(fn(&self, item_id: u32) -> QString),
    get_item_url: qt_method!(fn(&self, item_id: u32) -> QString),
    get_item_name: qt_method!(fn(&self, item_id: u32) -> QString),
    get_trim_start: qt_method!(fn(&self, item_id: u32) -> f64),
    get_trim_end: qt_method!(fn(&self, item_id: u32) -> f64),
    is_item_url: qt_method!(fn(&self, item_id: u32, url: QString) -> bool),
    find_by_url: qt_method!(fn(&self, url: QString) -> u32),

    add_section: qt_method!(fn(&mut self, video_id: u32, trim_start: f64, trim_end: f64) -> u32),
    set_section_trim: qt_method!(fn(&mut self, item_id: u32, trim_start: f64, trim_end: f64)),

    save_settings: qt_method!(fn(&mut self, item_id: u32, data: QString)),
    get_project_data: qt_method!(fn(&self, item_id: u32) -> QString),
    get_settings_for_job: qt_method!(fn(&self, job_id: u32) -> QString),
    apply_stabilization_to_all: qt_method!(fn(&mut self, data: QString, except_item_id: u32) -> usize),
    settings_hash: qt_method!(fn(&self, item_id: u32) -> QString),

    get_output_path: qt_method!(fn(&self, item_id: u32) -> QString),
    get_output_folder: qt_method!(fn(&self, item_id: u32) -> QString),
    get_output_filename: qt_method!(fn(&self, item_id: u32) -> QString),
    set_output_path: qt_method!(fn(&mut self, item_id: u32, path: QString)),
    set_output_url: qt_method!(fn(&mut self, item_id: u32, folder: QString, filename: QString)),

    get_render_items: qt_method!(fn(&self, selected_only: bool) -> QVariantList),
    set_item_job: qt_method!(fn(&mut self, item_id: u32, job_id: u32)),
    get_item_job: qt_method!(fn(&self, item_id: u32) -> u32),
    get_item_job_status: qt_method!(fn(&self, item_id: u32) -> QString),
    is_library_job: qt_method!(fn(&self, job_id: u32) -> bool),
    update_job_progress: qt_method!(fn(&mut self, job_id: u32, progress: f64, finished: bool)),
    set_job_error: qt_method!(fn(&mut self, job_id: u32, err: QString)),
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
        if self.output_filename_of(&v.url, &v.output_path).to_lowercase().contains(&search) { return true; }
        v.sections.iter().any(|s| {
            s.name.to_lowercase().contains(&search) || self.output_filename_of(&v.url, &s.output_path).to_lowercase().contains(&search)
        })
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
        let (folder, filename) = self.resolve_output(&v.url, &v.output_path);
        MediaItem {
            item_id: v.id,
            parent_id,
            kind: QString::from("video"),
            depth,
            name: QString::from(v.filename.as_str()),
            url: QString::from(v.url.as_str()),
            output_path: QString::from(self.output_path_or_default(&v.url, &v.output_path)),
            display_output_path: QString::from(filesystem::display_folder_filename(&folder, &filename)),
            expanded: v.expanded,
            has_children: !v.sections.is_empty(),
            selected: v.selected,
            is_current: self.current_item == v.id,
            created_at: v.created_at,
            duration_ms: v.duration_ms,
            trim_start: 0.0,
            trim_end: 1.0,
            lens_profile: QString::from(v.lens_profile.as_str()),
            lens_warning: v.lens_warning,
            scanning: v.scanning,
            stabilized_state: self.stabilized_state(&v.settings, &v.output_hash),
            job_status: QString::from(v.job.status.as_str()),
            job_progress: v.job.progress,
            error_string: QString::from(v.job.error.as_str()),
            job_id: v.job.job_id,
        }
    }
    fn section_to_item(&self, s: &Section, v: &Video, depth: i32) -> MediaItem {
        let (folder, filename) = self.resolve_output(&v.url, &s.output_path);
        MediaItem {
            item_id: s.id,
            parent_id: v.id,
            kind: QString::from("section"),
            depth,
            name: QString::from(s.name.as_str()),
            url: QString::from(v.url.as_str()),
            output_path: QString::from(self.output_path_or_default(&v.url, &s.output_path)),
            display_output_path: QString::from(filesystem::display_folder_filename(&folder, &filename)),
            expanded: false,
            has_children: false,
            selected: s.selected,
            is_current: self.current_item == s.id,
            created_at: v.created_at,
            duration_ms: v.duration_ms * (s.trim_end - s.trim_start).max(0.0),
            trim_start: s.trim_start,
            trim_end: s.trim_end,
            lens_profile: QString::from(v.lens_profile.as_str()),
            lens_warning: v.lens_warning,
            scanning: false,
            stabilized_state: self.stabilized_state(&s.settings, &s.output_hash),
            job_status: QString::from(s.job.status.as_str()),
            job_progress: s.job.progress,
            error_string: QString::from(s.job.error.as_str()),
            job_id: s.job.job_id,
        }
    }

    fn build_items(&self) -> Vec<MediaItem> {
        let mut ret = Vec::new();
        let add_video = |ret: &mut Vec<MediaItem>, v: &Video, parent_id: u32, depth: i32| {
            ret.push(self.video_to_item(v, parent_id, depth));
            if v.expanded {
                for s in &v.sections {
                    ret.push(self.section_to_item(s, v, depth + 1));
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
    /// Returns the video containing the section and the section itself
    fn section(&self, id: u32) -> Option<(&Video, &Section)> {
        for v in self.all_videos() {
            if let Some(s) = v.sections.iter().find(|s| s.id == id) {
                return Some((v, s));
            }
        }
        None
    }
    fn section_mut(&mut self, id: u32) -> Option<&mut Section> {
        self.all_videos_mut().find_map(|v| v.sections.iter_mut().find(|s| s.id == id))
    }
    fn new_id(&mut self) -> u32 {
        self.next_id += 1;
        self.next_id
    }

    /// Settings, output path and the job of any video or section
    fn item_settings(&self, item_id: u32) -> Option<(&str, &Option<String>, &str, &JobState)> {
        if let Some(v) = self.video(item_id) {
            return Some((v.url.as_str(), &v.settings, v.output_path.as_str(), &v.job));
        }
        if let Some((v, s)) = self.section(item_id) {
            return Some((v.url.as_str(), &s.settings, s.output_path.as_str(), &s.job));
        }
        None
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
        for url in urls.into_iter() {
            let url = Self::to_url(&url.to_string(), false);
            let filename = filesystem::get_filename(&url);
            if url.is_empty() || !Self::is_video_file(&filename) { continue; }
            if self.all_videos().any(|v| v.url == url) { continue; }
            let v = self.new_video(url, filename);
            self.standalone.push(v);
        }
        self.rebuild();
        self.scan_pending();
    }

    /// Adds dropped urls, folders are added as input folders and files as standalone videos
    pub fn add_dropped(&mut self, urls: QStringList) {
        let mut files = Vec::new();
        for url in urls.into_iter() {
            let url_str = url.to_string();
            let path = filesystem::url_to_path(&Self::to_url(&url_str, false));
            if !path.is_empty() && std::path::Path::new(&path).is_dir() {
                self.add_folder(QString::from(url_str));
            } else {
                files.push(url.clone());
            }
        }
        if !files.is_empty() {
            self.add_files(QStringList::from_iter(files));
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
        let mut job_ids = Vec::new();
        let mut collect = |v: &Video| {
            if v.job.job_id > 0 { job_ids.push(v.job.job_id); }
            for s in &v.sections {
                if s.job.job_id > 0 { job_ids.push(s.job.job_id); }
            }
        };
        if let Some(f) = self.folders.iter().find(|f| f.id == item_id) {
            for v in &f.videos { collect(v); }
            self.folders.retain(|f| f.id != item_id);
        } else if let Some(v) = self.video(item_id) {
            collect(v);
            self.standalone.retain(|v| v.id != item_id);
            for f in self.folders.iter_mut() {
                f.videos.retain(|v| v.id != item_id);
            }
        } else if let Some((_, s)) = self.section(item_id) {
            if s.job.job_id > 0 { job_ids.push(s.job.job_id); }
            for v in self.all_videos_mut() {
                v.sections.retain(|s| s.id != item_id);
            }
        }
        if self.current_item == item_id {
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
        let mut to_check = Vec::new();
        for v in self.all_videos() {
            to_check.push((v.id, self.resolve_output(&v.url, &v.output_path)));
            for s in &v.sections {
                to_check.push((s.id, self.resolve_output(&v.url, &s.output_path)));
            }
        }
        if to_check.is_empty() { return; }

        let checked = util::qt_queued_callback_mut(QPointer::from(self as &Self), move |this, (item_id, hash): (u32, Option<String>)| {
            let mut settings = None;
            if let Some(v) = this.video_mut(item_id) {
                v.output_hash = hash;
                settings = Some((v.settings.clone(), v.output_hash.clone()));
            } else if let Some(s) = this.section_mut(item_id) {
                s.output_hash = hash;
                settings = Some((s.settings.clone(), s.output_hash.clone()));
            }
            if let Some((settings, hash)) = settings {
                let state = this.stabilized_state(&settings, &hash);
                this.patch_row(item_id, |x| x.stabilized_state = state);
            }
        });

        core::run_threaded(move || {
            for (item_id, (folder, filename)) in to_check {
                let url = filesystem::get_file_url(&folder, &filename.replace("_%05d", "_00001"), false);
                if !url.is_empty() && filesystem::exists(&url) {
                    let hash = rendering::render_queue::stabilization_hash_from_file(&url).unwrap_or_default();
                    checked((item_id, Some(hash)));
                } else {
                    checked((item_id, None));
                }
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

    pub fn set_selected(&mut self, item_id: u32, selected: bool) {
        if let Some(index) = self.folders.iter().position(|f| f.id == item_id) {
            for v in self.folders[index].videos.iter_mut() {
                v.selected = selected;
                for s in v.sections.iter_mut() { s.selected = selected; }
            }
        } else if let Some(v) = self.video_mut(item_id) {
            v.selected = selected;
            for s in v.sections.iter_mut() { s.selected = selected; }
        } else if let Some(s) = self.section_mut(item_id) {
            s.selected = selected;
        }
        self.update_selection_rows();
    }
    pub fn select_only(&mut self, item_id: u32) {
        self.select_all(false);
        self.set_selected(item_id, true);
    }
    pub fn select_all(&mut self, selected: bool) {
        for v in self.all_videos_mut() {
            v.selected = selected;
            for s in v.sections.iter_mut() { s.selected = selected; }
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
            for s in &v.sections { states.push((s.id, s.selected)); }
        }
        for (id, selected) in states {
            self.patch_row(id, |x| x.selected = selected);
        }
        self.items_changed();
    }
    pub fn selected_count(&self) -> usize {
        self.all_videos().map(|v| {
            if v.sections.is_empty() {
                if v.selected { 1 } else { 0 }
            } else {
                v.sections.iter().filter(|s| s.selected).count()
            }
        }).sum()
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
        if self.section(item_id).is_some() { return QString::from("section"); }
        QString::default()
    }
    pub fn get_item_url(&self, item_id: u32) -> QString {
        if let Some(f) = self.folders.iter().find(|f| f.id == item_id) { return QString::from(f.url.as_str()); }
        self.item_settings(item_id).map(|(url, _, _, _)| QString::from(url)).unwrap_or_default()
    }
    pub fn get_item_name(&self, item_id: u32) -> QString {
        if let Some(f) = self.folders.iter().find(|f| f.id == item_id) { return QString::from(f.name.as_str()); }
        if let Some(v) = self.video(item_id) { return QString::from(v.filename.as_str()); }
        if let Some((_, s)) = self.section(item_id) { return QString::from(s.name.as_str()); }
        QString::default()
    }
    pub fn get_trim_start(&self, item_id: u32) -> f64 { self.section(item_id).map(|(_, s)| s.trim_start).unwrap_or(0.0) }
    pub fn get_trim_end  (&self, item_id: u32) -> f64 { self.section(item_id).map(|(_, s)| s.trim_end)  .unwrap_or(1.0) }

    pub fn is_item_url(&self, item_id: u32, url: QString) -> bool {
        let url = Self::to_url(&url.to_string(), false);
        !url.is_empty() && self.item_settings(item_id).map(|(x, _, _, _)| x == url).unwrap_or_default()
    }
    pub fn find_by_url(&self, url: QString) -> u32 {
        let url = Self::to_url(&url.to_string(), false);
        if url.is_empty() { return 0; }
        self.all_videos().find(|v| v.url == url).map(|v| v.id).unwrap_or_default()
    }

    // ---------------------------------------------------------------------------------------------
    // ----------------------------------------- Sections ------------------------------------------
    // ---------------------------------------------------------------------------------------------

    pub fn add_section(&mut self, video_id: u32, trim_start: f64, trim_end: f64) -> u32 {
        let id = self.new_id();
        let suffix = self.default_suffix.to_string();
        if let Some(v) = self.video_mut(video_id) {
            // Inherit from the last created section, or from the video itself if it's the first one
            let settings = v.sections.last().map(|s| s.settings.clone()).unwrap_or_else(|| v.settings.clone());
            let num = v.sections.len() + 1;
            let output_path = Self::filename_with_index(&Self::default_output_filename(&v.filename, &suffix), num);
            v.expanded = true;
            v.sections.push(Section {
                id,
                name: format!("Section {num}"),
                trim_start,
                trim_end,
                settings,
                output_path,
                ..Default::default()
            });
        } else {
            return 0;
        }
        self.rebuild();
        self.refresh_outputs();
        id
    }
    pub fn set_section_trim(&mut self, item_id: u32, trim_start: f64, trim_end: f64) {
        if let Some(s) = self.section_mut(item_id) {
            s.trim_start = trim_start;
            s.trim_end = trim_end;
        }
        self.rebuild();
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
        let video_id = if self.video(item_id).is_some() { item_id } else { self.section(item_id).map(|(v, _)| v.id).unwrap_or_default() };
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

        // The trim range of a section is edited in the timeline of the main view
        let new_trim = self.section(item_id).and_then(|(v, _)| {
            let ranges = data.get("trim_ranges_ms")?.as_array()?;
            let range = ranges.first()?.as_array()?;
            let duration_ms = if v.duration_ms > 0.0 { v.duration_ms } else { return None; };
            Some((range.first()?.as_f64()? / duration_ms, range.get(1)?.as_f64()? / duration_ms))
        });

        let data = data.to_string();
        if let Some(v) = self.video_mut(item_id) {
            v.settings = Some(data);
        } else if let Some(s) = self.section_mut(item_id) {
            s.settings = Some(data);
            if let Some((start, end)) = new_trim {
                if end > start {
                    s.trim_start = start;
                    s.trim_end = end;
                }
            }
        } else {
            return;
        }
        self.update_stabilized_row(item_id);
        if new_trim.is_some() { self.rebuild(); }
    }

    /// Project data of the item, used to load it in the main view
    pub fn get_project_data(&self, item_id: u32) -> QString {
        self.build_project_data(item_id, false).map(QString::from).unwrap_or_default()
    }
    /// Settings of the rendered item, applied to the already loaded render job (ie. without the video and gyro data)
    pub fn get_settings_for_job(&self, job_id: u32) -> QString {
        let item_id = self.item_id_for_job(job_id);
        self.build_project_data(item_id, true).map(QString::from).unwrap_or_default()
    }

    fn build_project_data(&self, item_id: u32, as_preset: bool) -> Option<String> {
        let (url, settings, _, _) = self.item_settings(item_id)?;
        let url = url.to_owned();
        let section = self.section(item_id).map(|(v, s)| (v.duration_ms, s.trim_start, s.trim_end));
        let parsed = settings.as_ref().and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok()).filter(|x| x.is_object());
        if parsed.is_none() && section.is_none() {
            return None; // Nothing was configured for this video, load it as a plain video file
        }
        let mut obj = parsed.unwrap_or_else(|| serde_json::json!({ "title": "Gyroflow data file", "version": 4 }));
        if let serde_json::Value::Object(ref mut o) = obj {
            o.remove("output"); // The output path is managed by the media library
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
            if let Some((duration_ms, start, end)) = section {
                if duration_ms > 0.0 {
                    o.insert("trim_ranges_ms".into(), serde_json::json!([[start * duration_ms, end * duration_ms]]));
                } else {
                    o.remove("trim_ranges_ms");
                    o.insert("trim_ranges".into(), serde_json::json!([[start, end]]));
                }
            }
        }
        Some(obj.to_string())
    }

    /// Applies the stabilization settings (and only those) to all videos and sections in the library
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
            for s in v.sections.iter_mut() {
                if s.id == except_item_id { continue; }
                apply(&mut s.settings, &url, &new_stab);
                ids.push(s.id);
                count += 1;
            }
        }
        for id in ids {
            self.update_stabilized_row(id);
        }
        count
    }

    fn effective_stabilization(settings: &Option<String>) -> serde_json::Value {
        settings.as_ref()
            .and_then(|x| serde_json::from_str::<serde_json::Value>(x).ok())
            .and_then(|x| x.get("stabilization").cloned())
            .unwrap_or(serde_json::Value::Null)
    }
    pub fn settings_hash(&self, item_id: u32) -> QString {
        let settings = self.item_settings(item_id).map(|(_, s, _, _)| s.clone()).unwrap_or_default();
        QString::from(rendering::render_queue::stabilization_settings_hash(&Self::effective_stabilization(&settings)))
    }
    fn stabilized_state(&self, settings: &Option<String>, output_hash: &Option<String>) -> i32 {
        match output_hash {
            None => NOT_STABILIZED,
            // Files rendered by older versions don't have the hash, we can't tell if they are up to date
            Some(hash) if hash.is_empty() => STABILIZED,
            Some(hash) => {
                if *hash == rendering::render_queue::stabilization_settings_hash(&Self::effective_stabilization(settings)) { STABILIZED } else { STALE }
            }
        }
    }
    fn update_stabilized_row(&mut self, item_id: u32) {
        if let Some((_, settings, _, _)) = self.item_settings(item_id) {
            let settings = settings.clone();
            let hash = if let Some(v) = self.video(item_id) { v.output_hash.clone() } else { self.section(item_id).and_then(|(_, s)| s.output_hash.clone()) };
            let state = self.stabilized_state(&settings, &hash);
            self.patch_row(item_id, |x| x.stabilized_state = state);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // --------------------------------------- Output paths ----------------------------------------
    // ---------------------------------------------------------------------------------------------

    fn default_output_filename(input_filename: &str, suffix: &str) -> String {
        filesystem::filename_with_suffix(input_filename, suffix)
    }
    fn filename_with_index(filename: &str, index: usize) -> String {
        match filename.rfind('.') {
            Some(pos) => format!("{}_{}{}", &filename[..pos], index, &filename[pos..]),
            None => format!("{filename}_{index}")
        }
    }
    fn output_path_or_default(&self, input_url: &str, output_path: &str) -> String {
        if output_path.is_empty() {
            Self::default_output_filename(&filesystem::get_filename(input_url), &self.default_suffix.to_string())
        } else {
            output_path.to_owned()
        }
    }
    fn output_filename_of(&self, input_url: &str, output_path: &str) -> String {
        self.resolve_output(input_url, output_path).1
    }
    /// The output path can be either absolute, or relative to the export folder (which defaults to the input folder)
    fn resolve_output(&self, input_url: &str, output_path: &str) -> (String, String) {
        let path = self.output_path_or_default(input_url, output_path);
        let is_absolute = path.starts_with('/') || path.contains("://") || path.get(1..3).map_or(false, |x| x == ":/" || x == ":\\");
        if is_absolute {
            let url = if path.contains("://") { path } else { filesystem::path_to_url(&path) };
            return (filesystem::get_folder(&url), filesystem::get_filename(&url));
        }
        let base = if self.export_folder.is_empty() { filesystem::get_folder(input_url) } else { self.export_folder.to_string() };
        if !path.contains('/') && !path.contains('\\') {
            return (base, path);
        }
        let mut full = filesystem::url_to_path(&base);
        if !full.ends_with('/') && !full.ends_with('\\') { full.push('/'); }
        full.push_str(&path.replace('\\', "/"));
        let url = filesystem::path_to_url(&full);
        (filesystem::get_folder(&url), filesystem::get_filename(&url))
    }

    pub fn get_output_path(&self, item_id: u32) -> QString {
        self.item_settings(item_id).map(|(url, _, path, _)| QString::from(self.output_path_or_default(url, path))).unwrap_or_default()
    }
    pub fn get_output_folder(&self, item_id: u32) -> QString {
        self.item_settings(item_id).map(|(url, _, path, _)| QString::from(self.resolve_output(url, path).0)).unwrap_or_default()
    }
    pub fn get_output_filename(&self, item_id: u32) -> QString {
        self.item_settings(item_id).map(|(url, _, path, _)| QString::from(self.resolve_output(url, path).1)).unwrap_or_default()
    }
    pub fn set_output_path(&mut self, item_id: u32, path: QString) {
        let path = path.to_string();
        if let Some(v) = self.video_mut(item_id) {
            v.output_path = path;
            v.output_hash = None;
        } else if let Some(s) = self.section_mut(item_id) {
            s.output_path = path;
            s.output_hash = None;
        } else {
            return;
        }
        self.rebuild();
        self.refresh_outputs();
    }
    /// Sets the output path from a folder url and a filename, storing it relative to the export folder if possible
    pub fn set_output_url(&mut self, item_id: u32, folder: QString, filename: QString) {
        let filename = filename.to_string();
        let folder = filesystem::normalize_url(&folder.to_string(), true);
        if filename.is_empty() { return; }

        let input_url = self.item_settings(item_id).map(|(url, _, _, _)| url.to_owned()).unwrap_or_default();
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

    /// Ids of all items that should be rendered. A video with sections is rendered as its sections
    pub fn get_render_items(&self, selected_only: bool) -> QVariantList {
        let mut ret = Vec::new();
        for v in self.all_videos() {
            if v.sections.is_empty() {
                if v.selected || !selected_only { ret.push(v.id); }
            } else {
                for s in &v.sections {
                    if s.selected || !selected_only { ret.push(s.id); }
                }
            }
        }
        QVariantList::from_iter(ret)
    }

    pub fn set_item_job(&mut self, item_id: u32, job_id: u32) {
        let job = JobState {
            job_id,
            status: if job_id > 0 { "queued".into() } else { String::new() },
            progress: 0.0,
            error: String::new(),
            hash: self.settings_hash(item_id).to_string()
        };
        if let Some(v) = self.video_mut(item_id) {
            v.job = job.clone();
        } else if let Some(s) = self.section_mut(item_id) {
            s.job = job.clone();
        } else {
            return;
        }
        self.patch_row(item_id, |x| {
            x.job_id = job.job_id;
            x.job_status = QString::from(job.status.as_str());
            x.job_progress = 0.0;
            x.error_string = QString::default();
        });
    }
    pub fn get_item_job(&self, item_id: u32) -> u32 {
        self.item_settings(item_id).map(|(_, _, _, job)| job.job_id).unwrap_or_default()
    }
    pub fn get_item_job_status(&self, item_id: u32) -> QString {
        self.item_settings(item_id).map(|(_, _, _, job)| QString::from(job.status.as_str())).unwrap_or_default()
    }
    pub fn is_library_job(&self, job_id: u32) -> bool {
        job_id > 0 && self.all_videos().any(|v| v.job.job_id == job_id || v.sections.iter().any(|s| s.job.job_id == job_id))
    }
    fn item_id_for_job(&self, job_id: u32) -> u32 {
        for v in self.all_videos() {
            if v.job.job_id == job_id { return v.id; }
            for s in &v.sections {
                if s.job.job_id == job_id { return s.id; }
            }
        }
        0
    }
    fn job_mut(&mut self, job_id: u32) -> Option<&mut JobState> {
        for v in self.standalone.iter_mut().chain(self.folders.iter_mut().flat_map(|f| f.videos.iter_mut())) {
            if v.job.job_id == job_id { return Some(&mut v.job); }
            if let Some(s) = v.sections.iter_mut().find(|s| s.job.job_id == job_id) {
                return Some(&mut s.job);
            }
        }
        None
    }

    pub fn update_job_progress(&mut self, job_id: u32, progress: f64, finished: bool) {
        let item_id = self.item_id_for_job(job_id);
        if item_id == 0 { return; }
        let mut is_error = false;
        if let Some(job) = self.job_mut(job_id) {
            is_error = job.status == "error";
            if !is_error {
                job.progress = progress;
                job.status = if finished { "done".into() } else { "rendering".into() };
            }
        }
        if is_error { return; }
        let status = if finished { "done" } else { "rendering" };
        self.patch_row(item_id, |x| {
            x.job_progress = progress;
            x.job_status = QString::from(status);
        });
        if finished {
            // The rendered file contains the hash of the settings it was rendered with
            let hash = self.job_mut(job_id).map(|x| x.hash.clone()).unwrap_or_default();
            if let Some(v) = self.video_mut(item_id) {
                v.output_hash = Some(hash);
            } else if let Some(s) = self.section_mut(item_id) {
                s.output_hash = Some(hash);
            }
            self.update_stabilized_row(item_id);
        }
    }
    pub fn set_job_error(&mut self, job_id: u32, err: QString) {
        let item_id = self.item_id_for_job(job_id);
        if item_id == 0 { return; }
        let err = err.to_string();
        if let Some(job) = self.job_mut(job_id) {
            job.status = "error".into();
            job.error = err.clone();
        }
        self.patch_row(item_id, |x| {
            x.job_status = QString::from("error");
            x.error_string = QString::from(err.as_str());
        });
    }
    pub fn clear_job_statuses(&mut self) {
        let mut ids = Vec::new();
        for v in self.all_videos_mut() {
            if v.job.status != "rendering" { v.job = Default::default(); ids.push(v.id); }
            for s in v.sections.iter_mut() {
                if s.job.status != "rendering" { s.job = Default::default(); ids.push(s.id); }
            }
        }
        for id in ids {
            self.patch_row(id, |x| {
                x.job_id = 0;
                x.job_status = QString::default();
                x.job_progress = 0.0;
                x.error_string = QString::default();
            });
        }
    }
    pub fn active_job_count(&self) -> usize {
        self.all_videos().map(|v| {
            (if v.job.status == "queued" || v.job.status == "rendering" { 1 } else { 0 }) +
            v.sections.iter().filter(|s| s.job.status == "queued" || s.job.status == "rendering").count()
        }).sum()
    }
}
