//! AI Exposure core: foreground watcher, capture, inference and the
//! encrypted local store. Empty until Phase 1 (see `docs/spec.md`, "Build order").
//!
//! Privacy rules from `CLAUDE.md` apply to everything added here: frames stay
//! in RAM and are zeroized after inference, and only allowlisted windows are
//! ever captured.

pub use aiexposure_types as types;
