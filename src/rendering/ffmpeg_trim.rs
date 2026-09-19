// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Timo Lehnertz

use std::sync::Arc;
use std::sync::atomic::{ AtomicBool, Ordering::Relaxed };

use ffmpeg_next::{ codec, encoder, format, media, rescale, rescale::Rescale, Dictionary, Error, Rational };
use gyroflow_core::filesystem::{ self, FfmpegPathWrapper };

use crate::core::StabilizationManager;
use super::ffmpeg_processor::FFmpegError;
use super::render_queue::RenderOptions;

/// Trims the input file without any stabilization, by copying the packets directly to the output file.
/// Nothing is decoded or encoded, so this is orders of magnitude faster than the regular render.
/// The trim points are not frame accurate, because the output starts at the closest keyframe before the trim start.
pub fn render_trim_only<F>(stab: &StabilizationManager, progress: F, input_file: &gyroflow_core::InputFile, render_options: &RenderOptions, trim_range_ind: Option<usize>, cancel_flag: Arc<AtomicBool>, pause_flag: Arc<AtomicBool>) -> Result<(), FFmpegError>
    where F: Fn((f64, usize, usize, bool, bool)) + Send + Sync + Clone
{
    let (org_trim_ranges, duration_ms, fps, total_frame_count) = {
        let params = stab.params.read();
        (params.trim_ranges.clone(), params.duration_ms, params.fps, params.frame_count)
    };
    let trim_ranges = trim_range_ind.map(|x| vec![org_trim_ranges[x]]).unwrap_or_else(|| org_trim_ranges.clone());
    let trim_ratio = if trim_ranges.is_empty() { 1.0 } else { trim_ranges.iter().fold(0.0, |acc, &x| acc + (x.1 - x.0)) };
    let render_frame_count = (total_frame_count as f64 * trim_ratio).round() as usize;
    let frame_interval_us = if fps > 0.0 { (1_000_000.0 / fps).round() as i64 } else { 0 };

    let ranges_ms: Vec<(Option<f64>, Option<f64>)> = if trim_ranges.is_empty() {
        vec![(None, None)]
    } else {
        trim_ranges.iter().map(|x| (if x.0 > 0.0 { Some(x.0 * duration_ms) } else { None }, if x.1 < 1.0 { Some(x.1 * duration_ms) } else { None })).collect()
    };

    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    let _prevent_system_sleep = keep_awake::inhibit_system("Gyroflow", "Trimming video");
    #[cfg(any(target_os = "ios", target_os = "android"))]
    let _prevent_system_sleep = keep_awake::inhibit_display("Gyroflow", "Trimming video");

    let mut filename = render_options.output_filename.clone();
    let folder = &render_options.output_folder;
    if cfg!(not(any(target_os = "android", target_os = "ios"))) && !filesystem::exists(folder) {
        let path = filesystem::url_to_path(folder);
        if !path.is_empty() {
            let _ = std::fs::create_dir_all(path);
        }
    }
    if org_trim_ranges.len() > 1 {
        if let Some(ind) = trim_range_ind {
            if let Some(pos) = filename.rfind('.') {
                filename.insert_str(pos, &format!("-{:0>3}", ind + 1));
            }
        }
    }
    let mut render_filename = filename.clone();
    if cfg!(not(any(target_os = "android", target_os = "ios"))) {
        render_filename = format!("{filename}.tmp");
    }

    ffmpeg_next::init()?;
    super::init_log();

    let mut in_file = FfmpegPathWrapper::new(&input_file.url, false).map_err(|e| FFmpegError::CannotOpenInputFile((input_file.url.clone(), e)))?;
    let mut input_options = Dictionary::new();
    if in_file.path.starts_with("fd:") {
        input_options.set("fd", &in_file.path[3..]);
        in_file.path = "fd:".into();
    }
    let mut ictx = format::input_with_dictionary(&in_file.path, input_options)?;

    let render_url = filesystem::get_file_url(folder, &render_filename, true);
    let mut out_file = FfmpegPathWrapper::new(&render_url, true).map_err(|e| FFmpegError::CannotOpenOutputFile((render_url.clone(), e)))?;
    let mut output_options = Dictionary::new();
    if out_file.path.starts_with("fd:") {
        output_options.set("fd", &out_file.path[3..]);
        out_file.path = "fd:".into();
    }
    let mut output_format = if let Some(pos) = filename.rfind('.') { &filename[pos+1..] } else { "mp4" }.to_ascii_lowercase();
    if output_format == "mkv" { output_format = String::from("matroska"); }

    let mut octx = format::output_as_with(&out_file.path, &output_format, output_options)?;

    let num_streams = ictx.nb_streams() as usize;
    let mut stream_mapping = vec![-1isize; num_streams];
    let mut ist_time_bases = vec![Rational(0, 0); num_streams];
    let mut is_av = Vec::new();
    let mut output_index = 0usize;
    let mut video_ost_index = -1isize;

    let mut metadata = ictx.metadata().to_owned();
    for (k, v) in render_options.get_metadata_dict().iter() {
        metadata.set(k, v);
    }

    for (i, stream) in ictx.streams().enumerate() {
        if let Some(timecode) = stream.metadata().get("timecode") {
            if metadata.get("timecode").is_none() {
                metadata.set("timecode", timecode);
            }
        }

        let medium = stream.parameters().medium();
        let include = match medium {
            media::Type::Video => video_ost_index < 0, // Limit to first video stream
            media::Type::Audio => render_options.audio,
            media::Type::Data => render_options.preserve_other_tracks,
            _ => false
        };
        if !include { continue; }

        stream_mapping[i] = output_index as isize;
        ist_time_bases[i] = stream.time_base();
        is_av.push(medium == media::Type::Video || medium == media::Type::Audio);
        if medium == media::Type::Video {
            video_ost_index = output_index as isize;
        }

        let mut ost = octx.add_stream(encoder::find(codec::Id::None))?;
        ost.set_parameters(stream.parameters());
        if medium != media::Type::Data {
            // We need to set codec_tag to 0 lest we run into incompatible codec tag issues when muxing into a different container format.
            // Data streams (e.g. GoPro/Sony metadata tracks) are often carried by a container-specific tag with no formal codec id,
            // so resetting their tag makes the muxer unable to find one at all ("Could not find tag for codec none in stream").
            unsafe { (*ost.parameters().as_mut_ptr()).codec_tag = 0; }
        }
        ost.set_time_base(stream.time_base());
        ost.set_avg_frame_rate(stream.avg_frame_rate());
        if medium == media::Type::Video {
            ost.set_rate(stream.rate());
        }
        output_index += 1;
    }
    if video_ost_index < 0 {
        return Err(FFmpegError::InternalError(Error::StreamNotFound));
    }

    let start_ms = ranges_ms.first().and_then(|x| x.0);
    let mut updated_creation_time = None;
    if let Some(start_ms) = start_ms {
        if start_ms > 0.0 {
            for (k, v) in metadata.iter() {
                if k == "creation_time" {
                    if let Ok(v) = chrono::DateTime::parse_from_rfc3339(v) {
                        if let Some(v) = v.checked_add_signed(chrono::TimeDelta::try_milliseconds(start_ms.round() as i64).unwrap()) {
                            updated_creation_time = Some(v.to_rfc3339());
                        }
                    }
                    break;
                }
            }
        }
    }
    if let Some(updated_creation_time) = updated_creation_time {
        metadata.set("creation_time", &updated_creation_time);
    }
    log::debug!("Output metadata: {:?}", &metadata);
    octx.set_metadata(metadata);
    octx.write_header()?;

    let ost_time_bases: Vec<Rational> = octx.streams().map(|x| x.time_base()).collect();

    let mut written_offset_us = 0i64;
    let mut frames = 0usize;
    progress((0.0, 0, render_frame_count, false, false));

    for range in &ranges_ms {
        if cancel_flag.load(Relaxed) { break; }

        if let Some(start) = range.0 {
            let position = (start as i64).rescale((1, 1000), rescale::TIME_BASE);
            ictx.seek(position, ..position)?;
        }
        let end_us = range.1.map(|x| (x * 1000.0).round() as i64);

        let mut first_ts_us = None;
        let mut last_ts_us = 0i64;
        let mut finished = vec![false; output_index];
        let mut pending = is_av.iter().filter(|x| **x).count();

        for (stream, mut packet) in ictx.packets() {
            if cancel_flag.load(Relaxed) { break; }

            let ist_index = stream.index();
            let ost_index = stream_mapping[ist_index];
            if ost_index < 0 { continue; }
            let ost_index = ost_index as usize;

            let tb_in = ist_time_bases[ist_index];
            let ts_us = packet.dts().or(packet.pts()).map(|x| x.rescale(tb_in, (1, 1_000_000))).unwrap_or_default();

            if let Some(end_us) = end_us {
                if ts_us > end_us {
                    if !finished[ost_index] {
                        finished[ost_index] = true;
                        if is_av[ost_index] { pending -= 1; }
                    }
                    if pending == 0 { break; }
                    continue;
                }
            }

            let first = *first_ts_us.get_or_insert(ts_us);
            last_ts_us = last_ts_us.max(ts_us);

            let tb_out = ost_time_bases[ost_index];
            let shift = (written_offset_us - first).rescale((1, 1_000_000), tb_out);
            packet.rescale_ts(tb_in, tb_out);
            packet.set_pts(packet.pts().map(|x| x + shift));
            packet.set_dts(packet.dts().map(|x| x + shift));
            packet.set_position(-1);
            packet.set_stream(ost_index);
            packet.write_interleaved(&mut octx)?;

            if ost_index as isize == video_ost_index {
                frames += 1;
                // The trim points are aligned to the keyframes, so we can end up with more frames than estimated
                let total = render_frame_count.max(frames + 1);
                progress((frames as f64 / total as f64, frames, total, false, false));

                while pause_flag.load(Relaxed) {
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
            }
        }

        written_offset_us += last_ts_us - first_ts_us.unwrap_or_default() + frame_interval_us;
    }

    octx.write_trailer()?;

    drop(octx);
    drop(out_file);

    let output_url = filesystem::get_file_url(folder, &filename, false);

    if render_filename != filename {
        let output_url_temp = filesystem::get_file_url(folder, &render_filename, false);
        if let Err(e) = std::fs::rename(&filesystem::url_to_path(&output_url_temp), &filesystem::url_to_path(&output_url)) {
            ::log::error!("Failed to rename file from {output_url_temp} to {output_url}: {e:?}");
        }
    }

    if trim_range_ind.is_none() || trim_range_ind == Some(org_trim_ranges.len() - 1) {
        let total = frames.max(render_frame_count);
        progress((1.0, total, total, true, false));
    }

    crate::util::update_file_times(&output_url, &input_file.url, start_ms);

    Ok(())
}
