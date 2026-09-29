# AI Exposure Desktop App

A desktop app that measures how much of a user's viewing time is AI-generated content. All screen analysis happens on-device; only end-to-end encrypted daily aggregates are synced. The full technical spec is in `docs/spec.md` — read it before making architectural decisions.

## Team and status

- Team: 2 developers. Dev A owns the Rust core, models and crypto; Dev B owns the app shell, backend, browser extension and distribution.
- Status: Phase 0 repo work done (monorepo, CI, first migration with RLS tests, shared types, feed-crop tooling); account setup for 0.2/0.3 is manual. See `docs/phase-0.md` for layout, commands and open spec gaps. Next: Phase 1.
- Target: closed beta in roughly 16–18 weeks (rough estimate, revise after Phase 1).

## Non-negotiable privacy rules

Never write code that violates these, even temporarily or in tests against real data:

1. Captured frames never touch disk and never leave the device. Zeroize frame buffers after inference; no temp files, no crash dumps containing frame data.
2. Only allowlisted windows are captured. Banking, password managers, health portals and private/incognito windows are blocked by default.
3. The server receives only end-to-end encrypted daily aggregates. No URLs, window titles, captions or images are ever sent.
4. The user can pause, inspect, export and delete everything at any time.
5. User content never enters model training unless a user explicitly donates a flagged item.

## Decided stack (don't re-litigate without a reason)

| Layer | Choice |
| --- | --- |
| App shell | Tauri 2 (Rust core + web UI). UI only calls read-only query and settings commands via a capability allowlist; never capture APIs. Strict CSP, no remote scripts. |
| macOS capture | ScreenCaptureKit, single-window filter |
| Windows capture | Windows.Graphics.Capture |
| Linux capture | PipeWire via xdg-desktop-portal (post-beta) |
| Foreground tracking | NSWorkspace + AX API (macOS); GetForegroundWindow + UI Automation (Windows) |
| Inference | ONNX Runtime: CoreML on macOS; Windows ML on Windows 11 24H2+, DirectML fallback on older builds (DirectML is in maintenance mode); CPU fallback everywhere |
| Models | One shared image encoder + AI-detection head + zero-shot category head. Start from an open-source detector, fine-tune on our labeled feed crops. Encoder full fine-tune quarterly, heads monthly. INT8, ≤100 MB. |
| Local store | SQLite + SQLCipher (WAL mode); 256-bit key in OS keychain via the `keyring` crate |
| Browser companion | MV3 extension + native messaging (extension-ID allowlist, schema-validated messages); per-site host permissions, never `<all_urls>` |
| Auth | Supabase Auth, PKCE in the system browser via a sign-in page on our own domain. Passkeys (Supabase beta). Never render login or passkey ceremonies inside the Tauri webview. Access token in memory only; refresh token in keychain. |
| Backend | Supabase Postgres with RLS, constraints and triggers. One project per region (US, EU). Writes go directly to `rollup_blobs` (no Edge Function on the write path). Only Edge Function: `delete-account`. Service-role key only in Edge Functions. |
| E2EE sync | Per-user 256-bit data key; XChaCha20-Poly1305 blobs padded to 4/16/64 KB buckets; AAD = (user_id, device_id, day, version). Data key wrapped by passkey PRF key + 24-word recovery key; Argon2id passphrase fallback. Use audited libraries (RustCrypto / libsodium), never custom crypto primitives. |
| Model + app updates | Cloudflare R2 (no egress fees), signed files, SHA-256 check before load, keep previous version for rollback |
| Web dashboard | Static site on a separate origin; decrypts in browser; strict CSP + SRI |
| Code signing | Apple Developer ID + notarization (distribute outside the Mac App Store); Azure Artifact Signing on Windows |

## Pipeline summary

Gate (allowlist check) → 1 Hz 64×64 probe + dHash → on change, capture window and crop to content → ensemble (provenance from extension, visual head, context from captions/OCR) → fuse into `p_ai` + confidence band → zeroize frame → write one event row. Category head runs only when `p_ai ≥ 0.5`. Black frames (DRM) are recorded as `unanalyzable`, never as human.

Performance budget: ≤3% average CPU, ≤2 ms probe, ≤40 ms inference on NPU/GPU (≤150 ms CPU), ≤250 MB RAM, ≤5% extra battery drain per hour.

## Sync rules

- Sync is opt-in. Users without sync never talk to the backend (except model/app update downloads).
- Sync when a day's rollup changed, at most every 6 hours, plus on quit and after local midnight, with a random per-device offset.
- One encrypted blob per device per day; after 90 days compact into monthly blobs.
- Exponential backoff with jitter. The app is local-first: backend outages only delay sync.

## Working conventions

- Repo layout: `crates/types` (shared types), `crates/core` (Rust core), `apps/desktop` (Tauri shell + UI), `packages/types` (generated TS types), `extension`, `supabase`, `tools/feed-crops`.
- Shared types live in `crates/types`; never hand-edit `packages/types/src/generated`. Regenerate with `cargo test -p aiexposure-types` and commit the result.
- Checks before pushing: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`, `pnpm typecheck`, and `pnpm db:start && pnpm db:test` for schema changes.
- New Tauri commands must be read-only queries or settings, and each is granted explicitly in `apps/desktop/src-tauri/capabilities/`.
- Every change to the server schema needs RLS tests proving user A cannot read or write user B's rows.
- Crypto module ships with published test vectors; any change to the blob format or key wrapping needs a note for the external crypto review.
- Platform-specific code (capture, permissions, inference providers, signing) must be tested on real macOS and Windows machines, not just CI.

## Open questions

- Target launch markets (sets data residency and consent wording).
- Timeline per phase with 2 developers.
- Which open-source detector to start from, and benchmark size for Phase 1.

## Background: longer-term platform plan

Desktop is the first platform because it allows permissioned window capture. Later phases from the original strategy: Android (MediaProjection or carefully disclosed AccessibilityService, with Play Store declarations), iPhone (Share Sheet extension + user-initiated analysis, since iOS doesn't allow automated cross-app screen analysis), and Safari/Chrome web extensions.
