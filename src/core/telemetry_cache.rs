// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Gyroflow contributors

//! The motion data parsed from a file, kept for the next stabilizer that loads the same file. Parsing it is what takes long
//! (eg. 20-50 s for a joined DJI recording on an SD card), and the main view and the render queue each load a video in a
//! stabilizer of their own: the queue loads it again when a job of it is rendered, also when it was loaded in the main
//! view just before, and the main view when it opens a video the queue loaded. With this, only the first of them parses it.
//!
//! The data is the result of the parser, before a stabilizer uses it, so it's the same for every one of them. It's looked
//! up by everything the parser gets (the file, its size and modification time, the load options, the video size and frame
//! rate), a change in any of them parses the file again. Only motion data recorded in the video itself is kept: the parser
//! also reads files next to it (eg. a .gcsv with the same name, the .csv of a RunCam, the parts of a RED clip), which can
//! change without the video changing. A file that has none isn't kept either, it may have been unreadable at the time.
//!
//! Only used by the app (see `set_enabled`), the plugins and the command line load a video once.

use std::collections::HashMap;
use std::sync::{ Arc, atomic::{ AtomicBool, Ordering::SeqCst } };
use std::path::{ Path, PathBuf };
use std::time::{ Duration, SystemTime };
use parking_lot::Mutex;
use crate::gyro_source::{ FileLoadOptions, FileMetadata };
use crate::{ filesystem, joined_video };

/// Cameras that record the motion data in the video, the beginning of `FileMetadata::detected_source`
const EMBEDDED_SOURCES: &[&str] = &["DJI", "GoPro", "Sony", "Insta360"];
/// The files telemetry-parser looks for next to a video without motion data (see `Input::from_stream_with_options`)
const SIDECAR_EXTENSIONS: &[&str] = &["jsonl", "gcsv", "bbl", "bfl", "csv", "JSONL", "GCSV", "BBL", "BFL", "CSV"];

/// The memory the kept data may use (eg. a joined DJI recording of 8 minutes has 30 MB), the least recently used is dropped first
const MAX_BYTES: usize = 512 * 1024 * 1024;

#[derive(Clone, PartialEq, Eq, Hash, Debug)]
struct Key {
    url: String,
    /// Size and modification time of the file, and of the parts of a joined video
    files: Vec<(u64, Option<SystemTime>)>,
    sample_index: Option<usize>,
    /// The parser only uses the project version for the gyro offset of RED projects before version 4: the main view loads
    /// with the current version, the render queue without one
    legacy_project: bool,
    size: (usize, usize),
    /// Frame rate in µfps, the main view and the render queue read it from the video separately
    fps: i64,
}
struct Entry {
    md: Arc<FileMetadata>,
    bytes: usize,
    last_used: u64,
}
#[derive(Default)]
struct Cache {
    entries: HashMap<Key, Entry>,
    /// One per file being parsed: a second load of it waits for the first one and takes its result
    loading: HashMap<Key, Arc<Mutex<()>>>,
    counter: u64,
}

lazy_static::lazy_static! {
    static ref CACHE: Mutex<Cache> = Mutex::new(Cache::default());
}
static ENABLED: AtomicBool = AtomicBool::new(false);

pub fn set_enabled(enabled: bool) {
    ENABLED.store(enabled, SeqCst);
}

fn local_path(url: &str) -> Option<PathBuf> {
    if cfg!(any(target_os = "android", target_os = "ios")) { return None; }
    let path = filesystem::url_to_path(url);
    if path.is_empty() { None } else { Some(PathBuf::from(path)) }
}

fn file_info(url: &str) -> Option<(u64, Option<SystemTime>)> {
    let path = local_path(url)?;
    filesystem::start_accessing_url(url, false);
    let md = std::fs::metadata(&path);
    filesystem::stop_accessing_url(url, false);
    let md = md.ok()?;
    if !md.is_file() { return None; }
    Some((md.len(), md.modified().ok()))
}

/// Whether the parser may read the motion data of the video from a file next to it
fn has_sidecar(url: &str) -> bool {
    let Some(path) = local_path(url) else { return true; };
    SIDECAR_EXTENSIONS.iter().any(|ext| Path::new(&path).with_extension(ext).exists())
}

fn key(url: &str, options: &FileLoadOptions, size: (usize, usize), fps: f64) -> Option<Key> {
    let mut files = vec![file_info(url)?];
    if joined_video::is_joined(url) {
        let parts = joined_video::read(url).ok()?;
        for part in parts {
            if has_sidecar(&part.url) { return None; }
            files.push(file_info(&part.url)?);
        }
    } else if has_sidecar(url) {
        return None;
    }
    Some(Key {
        url: url.to_owned(),
        files,
        sample_index: options.sample_index,
        legacy_project: options.project_version > 0 && options.project_version < 4,
        size,
        fps: (fps * 1_000_000.0).round() as i64,
    })
}

fn estimated_bytes(md: &FileMetadata) -> usize {
    use std::mem::size_of_val;
    fn vec<T>(v: &[T]) -> usize { std::mem::size_of_val(v) }
    // A node of a BTreeMap holds up to 11 entries and is about half full
    fn map<K, V>(v: &std::collections::BTreeMap<K, V>) -> usize { v.len() * (std::mem::size_of::<K>() + std::mem::size_of::<V>()) * 3 / 2 }
    let mut bytes = std::mem::size_of::<FileMetadata>()
        + vec(&md.raw_imu)
        + map(&md.quaternions)
        + md.gravity_vectors.as_ref().map_or(0, map)
        + md.image_orientations.as_ref().map_or(0, map)
        + map(&md.lens_positions)
        + map(&md.lens_params)
        + vec(&md.per_frame_time_offsets)
        + vec(&md.camera_stab_data)
        + vec(&md.mesh_correction.frames)
        + md.additional_data.to_string().len();
    for x in &md.camera_stab_data {
        bytes += size_of_val(x.ibis_spline.points()) + size_of_val(x.ois_spline.points());
    }
    for x in &md.mesh_correction.tables {
        bytes += vec(&x.forward) + vec(&x.inverse) + vec(&x.refinement);
    }
    for x in &md.mesh_correction.frames {
        bytes += vec(&x.focal_plane);
    }
    for x in &md.legacy_mesh_correction {
        bytes += size_of_val(x) + vec(&x.0) + vec(&x.1);
    }
    for x in &md.lens_breathing {
        bytes += size_of_val(x) + vec(&x.scale);
    }
    bytes
}

fn take(cache: &mut Cache, key: &Key) -> Option<Arc<FileMetadata>> {
    cache.counter += 1;
    let counter = cache.counter;
    cache.entries.get_mut(key).map(|e| { e.last_used = counter; e.md.clone() })
}

fn insert(cache: &mut Cache, key: Key, md: Arc<FileMetadata>, bytes: usize) {
    cache.entries.remove(&key);
    // The file changed, the data of its older version isn't loaded anymore
    cache.entries.retain(|k, _| k.url != key.url || k.files == key.files);
    while !cache.entries.is_empty() && cache.entries.values().map(|e| e.bytes).sum::<usize>() + bytes > MAX_BYTES {
        if let Some(oldest) = cache.entries.iter().min_by_key(|(_, e)| e.last_used).map(|(k, _)| k.clone()) {
            cache.entries.remove(&oldest);
        }
    }
    cache.counter += 1;
    let last_used = cache.counter;
    cache.entries.insert(key, Entry { md, bytes, last_used });
}

/// The motion data of the file: the kept one if it was parsed before, otherwise the result of `parse` (kept for the next
/// load, unless it was cancelled). While another load parses the same file, this waits for it, or until it's cancelled
pub fn get_or_parse<F>(url: &str, options: &FileLoadOptions, size: (usize, usize), fps: f64, cancel_flag: &Arc<AtomicBool>, parse: F) -> Result<FileMetadata, crate::GyroflowCoreError>
    where F: FnOnce() -> Result<FileMetadata, crate::GyroflowCoreError>
{
    if !ENABLED.load(SeqCst) { return parse(); }
    let Some(key) = key(url, options, size, fps) else { return parse(); };
    // The copy is made after unlocking, it takes a while for a long video
    let cached = |url: &str, md: Arc<FileMetadata>| {
        ::log::info!("Motion data of {url} taken from the cache");
        Ok((*md).clone())
    };

    let loading = {
        let mut cache = CACHE.lock();
        if let Some(md) = take(&mut cache, &key) {
            drop(cache);
            return cached(url, md);
        }
        Loading { arc: cache.loading.entry(key.clone()).or_default().clone(), key: key.clone() }
    };
    let _guard = loop {
        if let Some(guard) = loading.arc.try_lock_for(Duration::from_millis(100)) { break guard; }
        if cancel_flag.load(SeqCst) { return Ok(FileMetadata::default()); }
    };
    // Parsed by the load it waited for
    let md = take(&mut CACHE.lock(), &key);
    if let Some(md) = md {
        return cached(url, md);
    }

    let start = std::time::Instant::now();
    let result = parse();

    if let Ok(md) = &result {
        let embedded = md.detected_source.as_deref().is_some_and(|x| EMBEDDED_SOURCES.iter().any(|y| x == *y || x.starts_with(&format!("{y} "))));
        // The parsers return what they read until then when it's cancelled
        if embedded && md.has_motion() && !cancel_flag.load(SeqCst) {
            let bytes = estimated_bytes(md);
            if bytes <= MAX_BYTES {
                let md = Arc::new(md.clone());
                insert(&mut CACHE.lock(), key, md, bytes);
                ::log::info!("Motion data of {url} parsed in {} ms, kept in the cache ({} MB)", start.elapsed().as_millis(), bytes / 1024 / 1024);
            }
        }
    }
    result
}

/// The lock of a file being parsed, removed when no load has it anymore
struct Loading {
    arc: Arc<Mutex<()>>,
    key: Key,
}
impl Drop for Loading {
    fn drop(&mut self) {
        let mut cache = CACHE.lock();
        // The one in `loading` and this one, the other loads clone it while `CACHE` is locked
        if Arc::strong_count(&self.arc) <= 2 {
            cache.loading.remove(&self.key);
        }
    }
}
