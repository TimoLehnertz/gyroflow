// SPDX-License-Identifier: GPL-3.0-or-later

use serde::{Deserialize, Serialize};
use std::path::{Component, Path};

#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Marker {
    In {
        timestamp: f64,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        path: Option<String>,
    },
    Out {
        timestamp: f64,
    },
    Marker {
        timestamp: f64,
        name: String,
        #[serde(default)]
        color: Option<String>,
    },
}

impl Marker {
    fn timestamp(&self) -> f64 {
        match self {
            Self::In { timestamp, .. }
            | Self::Out { timestamp }
            | Self::Marker { timestamp, .. } => *timestamp,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct VideoSpan {
    pub id: u32,
    pub start: f64,
    pub duration_ms: f64,
}

#[derive(Clone, Debug)]
pub struct SectionPlan {
    pub video_id: u32,
    pub start: f64,
    pub end: f64,
    pub name: Option<String>,
    pub path: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct TimelineMarker {
    pub position: f64,
    pub name: String,
    pub color: Option<String>,
}

#[derive(Default, Debug)]
pub struct ImportPlan {
    pub sections: Vec<SectionPlan>,
    pub timeline: Vec<(u32, TimelineMarker)>,
    pub unmatched: Vec<String>,
}

fn video_at(videos: &[VideoSpan], timestamp: f64) -> Option<&VideoSpan> {
    videos
        .iter()
        .filter(|v| {
            v.start > 0.0
                && v.duration_ms > 0.0
                && timestamp >= v.start
                && timestamp < v.start + v.duration_ms / 1000.0
        })
        .max_by(|a, b| a.start.total_cmp(&b.start))
}

fn shifted(videos: &[VideoSpan], offset_seconds: f64) -> Vec<VideoSpan> {
    if offset_seconds == 0.0 {
        return videos.to_vec();
    }
    videos
        .iter()
        .map(|v| VideoSpan { start: v.start - offset_seconds, ..*v })
        .collect()
}

fn valid_relative_path(path: &str) -> bool {
    !path.trim().is_empty()
        && !path.contains('\\')
        && Path::new(path)
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
}

pub fn parse(json: &str) -> Result<Vec<Marker>, String> {
    let markers: Vec<Marker> =
        serde_json::from_str(json).map_err(|e| format!("Invalid markers JSON: {e}"))?;
    for marker in &markers {
        if !marker.timestamp().is_finite() || marker.timestamp() < 0.0 {
            return Err("Marker timestamps must be non-negative Unix seconds.".into());
        }
        match marker {
            Marker::In {
                path: Some(path), ..
            } if !valid_relative_path(path) => {
                return Err(format!("Invalid relative output path: {path}"));
            }
            Marker::Marker { name, .. } if name.trim().is_empty() => {
                return Err("Timeline markers need a name.".into());
            }
            _ => {}
        }
    }
    Ok(markers)
}

/// `offset_seconds` is subtracted from each video's creation time. Use a positive value when the
/// camera stored local wall-clock time as UTC (for example 7200 for CEST).
pub fn plan(json: &str, videos: &[VideoSpan], offset_seconds: f64) -> Result<ImportPlan, String> {
    let markers = parse(json)?;
    plan_parsed(&markers, videos, offset_seconds)
}

pub fn plan_parsed(markers: &[Marker], videos: &[VideoSpan], offset_seconds: f64) -> Result<ImportPlan, String> {
    let offset_seconds = if offset_seconds.is_finite() { offset_seconds } else { 0.0 };
    let videos = shifted(videos, offset_seconds);
    let mut plan = ImportPlan::default();
    let mut ins = Vec::new();
    let mut outs = Vec::new();
    for (index, marker) in markers.iter().enumerate() {
        match marker {
            Marker::In { .. } => ins.push(index),
            Marker::Out { .. } => outs.push(index),
            Marker::Marker {
                timestamp,
                name,
                color,
            } => {
                if let Some(video) = video_at(&videos, *timestamp) {
                    plan.timeline.push((
                        video.id,
                        TimelineMarker {
                            position: (*timestamp - video.start) * 1000.0 / video.duration_ms,
                            name: name.clone(),
                            color: color.clone(),
                        },
                    ));
                } else {
                    plan.unmatched.push(format!("{} ({timestamp})", name));
                }
            }
        }
    }
    ins.sort_by(|a, b| markers[*a].timestamp().total_cmp(&markers[*b].timestamp()));
    outs.sort_by(|a, b| markers[*a].timestamp().total_cmp(&markers[*b].timestamp()));
    let mut used_out = vec![false; markers.len()];
    for (position, index) in ins.iter().enumerate() {
        let (timestamp, name, path) = match &markers[*index] {
            Marker::In {
                timestamp,
                name,
                path,
            } => (timestamp, name, path),
            _ => unreachable!(),
        };
        let video = match video_at(&videos, *timestamp) {
            Some(video) => video,
            None => {
                plan.unmatched.push(format!(
                    "in {} ({timestamp})",
                    name.as_deref().unwrap_or("")
                ));
                continue;
            }
        };
        let video_end = video.start + video.duration_ms / 1000.0;
        let next_in = ins
            .get(position + 1)
            .map(|next| markers[*next].timestamp())
            .unwrap_or(f64::INFINITY);
        let mut end = video_end;
        if let Some(out_index) = outs.iter().copied().find(|x| {
            !used_out[*x]
                && markers[*x].timestamp() > *timestamp
                && markers[*x].timestamp() < next_in
                && markers[*x].timestamp() <= end
        }) {
            used_out[out_index] = true;
            end = markers[out_index].timestamp();
        }
        if end > *timestamp {
            plan.sections.push(SectionPlan {
                video_id: video.id,
                start: ((*timestamp - video.start) * 1000.0 / video.duration_ms).clamp(0.0, 1.0),
                end: ((end - video.start) * 1000.0 / video.duration_ms).clamp(0.0, 1.0),
                name: name.clone(),
                path: path.clone(),
            });
        }
    }
    for index in outs {
        if !used_out[index] {
            plan.unmatched
                .push(format!("out ({})", markers[index].timestamp()));
        }
    }
    Ok(plan)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn matches_sections_and_timeline() {
        let videos = [VideoSpan {
            id: 3,
            start: 1000.0,
            duration_ms: 20_000.0,
        }];
        let json = r##"[{"type":"in","timestamp":1002,"name":"first.mp4"},{"type":"out","timestamp":1005},{"type":"in","timestamp":1010,"path":"cuts/second.mp4"},{"type":"marker","timestamp":1012,"name":"jump","color":"#ff0000"},{"type":"in","timestamp":1100},{"type":"marker","timestamp":1200,"name":"lost"}]"##;
        let result = plan(json, &videos, 0.0).unwrap();
        assert_eq!(result.sections.len(), 2);
        assert_eq!(result.sections[0].start, 0.1);
        assert_eq!(result.sections[0].end, 0.25);
        assert_eq!(result.sections[1].end, 1.0);
        assert_eq!(result.timeline[0].1.name, "jump");
        assert_eq!(result.unmatched.len(), 2);
    }
    #[test]
    fn each_start_without_an_out_runs_to_video_end() {
        let videos = [VideoSpan {
            id: 1,
            start: 1000.0,
            duration_ms: 10_000.0,
        }];
        let result = plan(
            r#"[{"type":"in","timestamp":1001},{"type":"in","timestamp":1003}]"#,
            &videos,
            0.0,
        )
        .unwrap();
        assert_eq!(result.sections.len(), 2);
        assert_eq!(result.sections[0].end, 1.0);
        assert_eq!(result.sections[1].end, 1.0);
    }
    #[test]
    fn out_closes_most_recent_in() {
        let videos = [VideoSpan {
            id: 1,
            start: 1000.0,
            duration_ms: 10_000.0,
        }];
        let result = plan(
            r#"[{"type":"in","timestamp":1001},{"type":"in","timestamp":1003},{"type":"out","timestamp":1005}]"#,
            &videos,
            0.0,
        )
        .unwrap();
        assert_eq!(result.sections.len(), 2);
        assert_eq!(result.sections[0].end, 1.0);
        assert_eq!(result.sections[1].end, 0.5);
    }
    #[test]
    fn rejects_absolute_and_parent_paths() {
        for path in ["/tmp/out.mp4", "../out.mp4"] {
            let json = format!(r#"[{{"type":"in","timestamp":1000,"path":"{path}"}}]"#);
            assert!(plan(&json, &[], 0.0).is_err());
        }
    }
    #[test]
    fn offset_matches_local_time_tagged_as_utc() {
        let videos = [
            VideoSpan { id: 1, start: 1_789_929_953.0, duration_ms: 25_000.0 },
            VideoSpan { id: 2, start: 1_789_929_998.0, duration_ms: 40_080.0 },
        ];
        let json = r#"[{"type":"in","timestamp":1789922758.983,"name":"Yan martin mende","path":"dobbin sprint/senior men/Yan martin mende.mp4"},{"type":"out","timestamp":1789922772.306},{"type":"in","timestamp":1789922819.564,"name":"Jemand anderes","path":"dobbin sprint/senior men/Jemand anderes.mp4"},{"type":"out","timestamp":1789922834.636}]"#;
        assert_eq!(plan(json, &videos, 0.0).unwrap().sections.len(), 0);
        let result = plan(json, &videos, 7200.0).unwrap();
        assert_eq!(result.sections.len(), 2);
        assert_eq!(result.unmatched.len(), 0);
        assert_eq!(result.sections[0].video_id, 1);
        assert_eq!(result.sections[1].video_id, 2);
        assert!((result.sections[0].start - 5.983 / 25.0).abs() < 1e-6);
        assert!((result.sections[0].end - 19.306 / 25.0).abs() < 1e-6);
        assert!((result.sections[1].start - 21.564 / 40.08).abs() < 1e-4);
        assert!((result.sections[1].end - 36.636 / 40.08).abs() < 1e-4);
    }
}
