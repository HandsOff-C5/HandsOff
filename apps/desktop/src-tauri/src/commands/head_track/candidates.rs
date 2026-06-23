use serde::{Deserialize, Serialize};
use std::process::Command;

use super::event::HeadPoint;

pub(super) const DEFAULT_RADIUS: f64 = 240.0;

#[derive(Debug, Clone, Deserialize)]
struct DriverWindowList {
    windows: Vec<DriverWindow>,
}

#[derive(Debug, Clone, Deserialize)]
struct DriverWindow {
    app_name: String,
    title: String,
    pid: u32,
    window_id: u32,
    is_on_screen: bool,
    z_index: i64,
    bounds: Option<WindowBounds>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
struct WindowBounds {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Debug, Clone)]
pub(super) struct AttentionWindow {
    surface: SurfaceSnapshot,
    bounds: WindowBounds,
    z_index: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct SurfaceSnapshot {
    id: String,
    title: String,
    app: String,
    pid: Option<u32>,
    window_id: Option<u32>,
    availability: &'static str,
    access_status: &'static str,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub(super) struct AttentionCandidate {
    surface: SurfaceSnapshot,
    score: f64,
    distance: f64,
}

#[derive(Debug, Clone)]
struct RankedCandidate {
    candidate: AttentionCandidate,
    z_index: i64,
}

pub(super) fn cua_attention_windows() -> Result<Vec<AttentionWindow>, String> {
    let output = Command::new("cua-driver")
        .args(["call", "list_windows", r#"{"on_screen_only":true}"#])
        .output()
        .map_err(|error| format!("cua-driver failed to start: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "cua-driver failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let list: DriverWindowList = serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("Could not parse CUA windows: {error}"))?;
    Ok(list
        .windows
        .into_iter()
        .filter_map(attention_window_from_driver)
        .collect())
}

fn attention_window_from_driver(window: DriverWindow) -> Option<AttentionWindow> {
    let bounds = window.bounds?;
    if window.app_name.to_ascii_lowercase().contains("cua driver") {
        return None;
    }
    Some(AttentionWindow {
        surface: SurfaceSnapshot {
            id: format!("{}:{}", window.pid, window.window_id),
            title: if window.title.is_empty() {
                window.app_name.clone()
            } else {
                window.title
            },
            app: window.app_name,
            pid: Some(window.pid),
            window_id: Some(window.window_id),
            availability: if window.is_on_screen {
                "available"
            } else {
                "unknown"
            },
            access_status: "accessible",
        },
        bounds,
        z_index: window.z_index,
    })
}

pub(super) fn rank_attention_candidates(
    point: HeadPoint,
    windows: &[AttentionWindow],
    radius: f64,
) -> Vec<AttentionCandidate> {
    if radius <= 0.0 {
        return vec![];
    }
    let mut ranked = windows
        .iter()
        .filter(|window| is_rankable(window))
        .filter_map(|window| {
            let distance = round3(distance_to_bounds(point, window.bounds));
            if distance > radius {
                return None;
            }
            Some(RankedCandidate {
                candidate: AttentionCandidate {
                    surface: window.surface.clone(),
                    score: round3(1.0 - distance / radius),
                    distance,
                },
                z_index: window.z_index,
            })
        })
        .collect::<Vec<_>>();

    ranked.sort_by(|a, b| {
        b.candidate
            .score
            .total_cmp(&a.candidate.score)
            .then_with(|| a.candidate.distance.total_cmp(&b.candidate.distance))
            .then_with(|| b.z_index.cmp(&a.z_index))
            .then_with(|| a.candidate.surface.id.cmp(&b.candidate.surface.id))
    });

    ranked.into_iter().map(|ranked| ranked.candidate).collect()
}

fn is_rankable(window: &AttentionWindow) -> bool {
    window.surface.availability == "available"
        && window.surface.access_status == "accessible"
        && window.bounds.width > 0.0
        && window.bounds.height > 0.0
}

// Diagnostic: one line per window showing its bounds, distance to the head point,
// and whether it survives the rankability + radius gate. Mirrors the exact checks
// in `rank_attention_candidates` so the head-track log explains why each window
// was kept or dropped (the empty-candidate symptom is usually every line `drop`).
pub(super) fn distance_report(point: HeadPoint, windows: &[AttentionWindow], radius: f64) -> Vec<String> {
    windows
        .iter()
        .map(|window| {
            let distance = round3(distance_to_bounds(point, window.bounds));
            let kept = is_rankable(window) && distance <= radius;
            format!(
                "  {app} [{id}] bounds=({x:.0},{y:.0},{w:.0},{h:.0}) dist={distance:.0} avail={avail}/{access} {verdict}",
                app = window.surface.app,
                id = window.surface.id,
                x = window.bounds.x,
                y = window.bounds.y,
                w = window.bounds.width,
                h = window.bounds.height,
                avail = window.surface.availability,
                access = window.surface.access_status,
                verdict = if kept { "KEEP" } else { "drop" },
            )
        })
        .collect()
}

fn distance_to_bounds(point: HeadPoint, bounds: WindowBounds) -> f64 {
    let nearest_x = clamp(point.x, bounds.x, bounds.x + bounds.width);
    let nearest_y = clamp(point.y, bounds.y, bounds.y + bounds.height);
    (point.x - nearest_x).hypot(point.y - nearest_y)
}

fn clamp(value: f64, min: f64, max: f64) -> f64 {
    value.min(max).max(min)
}

fn round3(value: f64) -> f64 {
    (value * 1000.0).round() / 1000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn surface(id: &str) -> SurfaceSnapshot {
        SurfaceSnapshot {
            id: id.to_string(),
            title: id.to_string(),
            app: "Codex".to_string(),
            pid: Some(42),
            window_id: Some(7),
            availability: "available",
            access_status: "accessible",
        }
    }

    fn window(id: &str, bounds: WindowBounds, z_index: i64) -> AttentionWindow {
        AttentionWindow {
            surface: surface(id),
            bounds,
            z_index,
        }
    }

    #[test]
    fn ranks_accessible_windows_by_distance_then_z_index() {
        let candidates = rank_attention_candidates(
            HeadPoint { x: 100.0, y: 100.0 },
            &[
                window(
                    "a:1",
                    WindowBounds {
                        x: 0.0,
                        y: 200.0,
                        width: 100.0,
                        height: 100.0,
                    },
                    1,
                ),
                window(
                    "b:2",
                    WindowBounds {
                        x: 200.0,
                        y: 0.0,
                        width: 100.0,
                        height: 100.0,
                    },
                    2,
                ),
                window(
                    "outside:3",
                    WindowBounds {
                        x: 251.0,
                        y: 0.0,
                        width: 100.0,
                        height: 100.0,
                    },
                    3,
                ),
            ],
            100.0,
        );

        assert_eq!(
            candidates
                .iter()
                .map(|candidate| candidate.surface.id.as_str())
                .collect::<Vec<_>>(),
            vec!["b:2", "a:1"]
        );
        assert_eq!(candidates[0].score, 0.0);
        assert_eq!(candidates[0].distance, 100.0);
    }

    #[test]
    fn returns_empty_candidates_when_no_window_is_in_the_neighborhood() {
        let candidates = rank_attention_candidates(
            HeadPoint { x: 0.0, y: 0.0 },
            &[window(
                "far:1",
                WindowBounds {
                    x: 500.0,
                    y: 500.0,
                    width: 100.0,
                    height: 100.0,
                },
                1,
            )],
            100.0,
        );

        assert!(candidates.is_empty());
    }

    #[test]
    fn maps_driver_windows_with_bounds_to_surface_candidates() {
        let window = attention_window_from_driver(DriverWindow {
            app_name: "Notes".to_string(),
            title: "".to_string(),
            pid: 42,
            window_id: 7,
            is_on_screen: true,
            z_index: 1,
            bounds: Some(WindowBounds {
                x: 0.0,
                y: 0.0,
                width: 100.0,
                height: 100.0,
            }),
        })
        .expect("window with bounds should map");

        assert_eq!(window.surface.id, "42:7");
        assert_eq!(window.surface.title, "Notes");
        assert_eq!(window.surface.access_status, "accessible");
    }

    #[test]
    fn skips_cua_driver_windows_before_ranking() {
        let window = attention_window_from_driver(DriverWindow {
            app_name: "CUA Driver".to_string(),
            title: "Driver Overlay".to_string(),
            pid: 42,
            window_id: 7,
            is_on_screen: true,
            z_index: 1,
            bounds: Some(WindowBounds {
                x: 0.0,
                y: 0.0,
                width: 100.0,
                height: 100.0,
            }),
        });

        assert!(window.is_none());
    }
}
