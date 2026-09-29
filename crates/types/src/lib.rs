//! Types shared by the Rust core and the web UI.
//!
//! The TypeScript copies in `packages/types/src/generated` are produced from
//! this crate by `cargo test -p aiexposure-types`; CI fails if they drift.
//! See `docs/spec.md`, "Event format and local schema".

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use ts_rs::TS;

/// An item counts as "AI content encountered" at or above this `p_ai`.
pub const AI_ITEM_THRESHOLD: f64 = 0.7;

/// The category head runs only on items at or above this `p_ai`.
pub const CATEGORY_THRESHOLD: f64 = 0.5;

/// Rollup category for items without one (below [`CATEGORY_THRESHOLD`] or
/// unanalyzable). `daily_rollup.category` is `NOT NULL`, so this stands in.
pub const UNCATEGORIZED: &str = "uncategorized";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, TS)]
#[serde(rename_all = "lowercase")]
#[ts(export)]
pub enum Surface {
    Browser,
    App,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, TS)]
#[serde(rename_all = "lowercase")]
#[ts(export)]
pub enum Media {
    Image,
    Video,
    Text,
    Mixed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, TS)]
#[serde(rename_all = "lowercase")]
#[ts(export)]
pub enum Confidence {
    High,
    Medium,
    Low,
}

/// Per-signal scores in `[0, 1]`; `None` when that signal was not available.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct Signals {
    pub provenance: Option<f64>,
    pub visual: Option<f64>,
    pub context: Option<f64>,
}

/// One analyzed content item.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct Event {
    /// ULID.
    pub id: String,
    pub started_at: DateTime<Utc>,
    #[ts(type = "number")]
    pub dwell_ms: u64,
    pub surface: Surface,
    /// Bundle ID (macOS) or executable name (Windows).
    pub app: String,
    /// `None` for native apps.
    pub domain: Option<String>,
    pub media: Media,
    /// `None` when the item was unanalyzable (e.g. DRM black frames).
    pub p_ai: Option<f64>,
    pub confidence: Option<Confidence>,
    pub signals: Signals,
    pub category: Option<String>,
    pub model_version: String,
}

impl Event {
    pub fn is_unanalyzable(&self) -> bool {
        self.p_ai.is_none()
    }

    /// `dwell_ms × p_ai`, rounded; 0 for unanalyzable items.
    pub fn ai_exposure_ms(&self) -> u64 {
        self.p_ai
            .map_or(0, |p| (self.dwell_ms as f64 * p).round() as u64)
    }

    pub fn is_ai_item(&self) -> bool {
        self.p_ai.is_some_and(|p| p >= AI_ITEM_THRESHOLD)
    }

    /// Rollup platform key: the domain for browser items, else the app.
    pub fn platform(&self) -> &str {
        self.domain.as_deref().unwrap_or(&self.app)
    }

    pub fn rollup_category(&self) -> &str {
        self.category.as_deref().unwrap_or(UNCATEGORIZED)
    }
}

/// One row of `daily_rollup`: totals for one local day, platform and category.
///
/// `total_ms` is all tracked time, including unanalyzable time, so
/// analyzed time is `total_ms - unanalyzable_ms`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct DailyRollup {
    /// Local date, serialized as `YYYY-MM-DD`.
    #[ts(type = "string")]
    pub day: NaiveDate,
    pub platform: String,
    pub category: String,
    #[ts(type = "number")]
    pub total_ms: u64,
    #[ts(type = "number")]
    pub ai_ms: u64,
    pub items: u32,
    /// Items with `p_ai >= AI_ITEM_THRESHOLD`.
    pub ai_items: u32,
    #[ts(type = "number")]
    pub unanalyzable_ms: u64,
    /// Unix ms of the last successful sync of this row, if any.
    #[ts(type = "number | null")]
    pub synced_at: Option<i64>,
}

impl DailyRollup {
    pub fn new(day: NaiveDate, platform: impl Into<String>, category: impl Into<String>) -> Self {
        Self {
            day,
            platform: platform.into(),
            category: category.into(),
            total_ms: 0,
            ai_ms: 0,
            items: 0,
            ai_items: 0,
            unanalyzable_ms: 0,
            synced_at: None,
        }
    }

    /// Adds one event. The caller picks the row: the event's local day,
    /// [`Event::platform`] and [`Event::rollup_category`].
    pub fn add(&mut self, event: &Event) {
        self.total_ms += event.dwell_ms;
        self.items += 1;
        if event.is_unanalyzable() {
            self.unanalyzable_ms += event.dwell_ms;
        } else {
            self.ai_ms += event.ai_exposure_ms();
            if event.is_ai_item() {
                self.ai_items += 1;
            }
        }
    }

    pub fn analyzed_ms(&self) -> u64 {
        self.total_ms - self.unanalyzable_ms
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec_event() -> Event {
        // The example from docs/spec.md.
        serde_json::from_str(
            r#"{
              "id": "01J9Z3K7Q8",
              "started_at": "2026-09-27T19:01:05Z",
              "dwell_ms": 12400,
              "surface": "browser",
              "app": "com.google.Chrome",
              "domain": "instagram.com",
              "media": "video",
              "p_ai": 0.91,
              "confidence": "high",
              "signals": { "provenance": null, "visual": 0.88, "context": 0.90 },
              "category": "fitness",
              "model_version": "vis-0.3.1"
            }"#,
        )
        .unwrap()
    }

    #[test]
    fn spec_example_round_trips() {
        let event = spec_event();
        assert_eq!(event.surface, Surface::Browser);
        assert_eq!(event.confidence, Some(Confidence::High));
        assert_eq!(event.signals.provenance, None);
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["started_at"], "2026-09-27T19:01:05Z");
        assert_eq!(json["media"], "video");
        assert_eq!(serde_json::from_value::<Event>(json).unwrap(), event);
    }

    #[test]
    fn exposure_and_thresholds() {
        let mut event = spec_event();
        assert_eq!(event.ai_exposure_ms(), 11284);
        assert!(event.is_ai_item());
        assert_eq!(event.platform(), "instagram.com");

        event.p_ai = Some(AI_ITEM_THRESHOLD);
        assert!(event.is_ai_item());

        event.p_ai = None;
        event.domain = None;
        event.category = None;
        assert!(event.is_unanalyzable());
        assert_eq!(event.ai_exposure_ms(), 0);
        assert!(!event.is_ai_item());
        assert_eq!(event.platform(), "com.google.Chrome");
        assert_eq!(event.rollup_category(), UNCATEGORIZED);
    }

    #[test]
    fn rollup_counts_unanalyzable_as_tracked_not_analyzed() {
        let analyzed = spec_event();
        let mut blacked_out = spec_event();
        blacked_out.p_ai = None;
        blacked_out.dwell_ms = 600;

        let day = NaiveDate::from_ymd_opt(2026, 9, 27).unwrap();
        let mut row = DailyRollup::new(day, "instagram.com", "fitness");
        row.add(&analyzed);
        row.add(&blacked_out);

        assert_eq!(row.total_ms, 13000);
        assert_eq!(row.unanalyzable_ms, 600);
        assert_eq!(row.analyzed_ms(), 12400);
        assert_eq!(row.ai_ms, 11284);
        assert_eq!((row.items, row.ai_items), (2, 1));
        assert_eq!(serde_json::to_value(&row).unwrap()["day"], "2026-09-27");
    }

    /// Writes the constants next to the ts-rs bindings so the UI shares them.
    #[test]
    fn export_constants() {
        let dir = std::env::var("TS_RS_EXPORT_DIR").unwrap_or_else(|_| "bindings".into());
        std::fs::create_dir_all(&dir).unwrap();
        let ts = format!(
            "// This file was generated by crates/types (export_constants). Do not edit this file manually.\n\
             export const AI_ITEM_THRESHOLD = {AI_ITEM_THRESHOLD};\n\
             export const CATEGORY_THRESHOLD = {CATEGORY_THRESHOLD};\n\
             export const UNCATEGORIZED = \"{UNCATEGORIZED}\";\n"
        );
        std::fs::write(format!("{dir}/constants.ts"), ts).unwrap();
    }
}
