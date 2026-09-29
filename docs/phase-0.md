# Phase 0 status

Tracks the Phase 0 steps from `docs/spec.md`, "Build order". Items marked
**manual** need an account owner and can't be done from the repo.

| # | Step | Status |
| --- | --- | --- |
| 0.1 | Monorepo and CI | Done: see layout below; CI runs on macOS, Windows and Ubuntu |
| 0.2 | Apple Developer Program, Azure Artifact Signing | **Manual**, not started |
| 0.3 | Supabase projects, R2 bucket, sign-in domain, migrations from CI | Repo side done (config, first migration, RLS tests, deploy workflow); **manual** account setup below |
| 0.4 | Feed-crop capture script, labeling guide, benchmark size target | Done: `tools/feed-crops/`; collection itself starts now |
| 0.5 | Shared event and rollup types | Done: `crates/types` → `packages/types` |

## Layout

| Path | What |
| --- | --- |
| `crates/types` | Shared `Event`, `DailyRollup` and friends. `cargo test -p aiexposure-types` regenerates the TypeScript copies in `packages/types/src/generated`; CI fails if they are stale. |
| `crates/core` | Rust core (empty until Phase 1). |
| `apps/desktop` | Tauri 2 shell (`src-tauri`) and Vite + TypeScript UI. No commands or permissions granted yet; strict CSP. |
| `packages/types` | `@aiexposure/types`, the TypeScript side of `crates/types`. |
| `extension` | MV3 companion skeleton: `nativeMessaging`, per-site optional host permissions only. |
| `supabase` | CLI config, migrations and pgTAP RLS tests. |
| `tools/feed-crops` | Dataset capture script and labeling guide (not shipped). |

## Local commands

```sh
pnpm install
pnpm --filter @aiexposure/desktop tauri dev   # run the app
cargo test --workspace                        # Rust tests (also regenerates bindings)
pnpm typecheck
pnpm db:start && pnpm db:test                 # local Postgres (Docker) + RLS tests
```

The UI has no framework yet; pick one at step 1.8 if the dashboard needs it.

## Manual setup for 0.2 and 0.3

1. **Apple Developer Program** (organization enrollment needs a D-U-N-S
   number) and **Azure Artifact Signing** (business verification). Both take
   days to weeks; start now.
2. **Supabase**: create `aiexposure-dev` and `aiexposure-prod-us` projects.
   In each, set the JWT expiry to 900 s, enable refresh token rotation, and
   add `aiexposure://callback` to the redirect URL allowlist (see
   `supabase/config.toml`). The EU project waits for the launch-market decision.
3. **GitHub environments**: create `supabase-dev` and `supabase-prod-us`
   (the latter with required reviewers), each with secrets
   `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD` and `SUPABASE_PROJECT_REF`.
   `db-deploy.yml` then migrates dev on every merge to `main` that touches
   `supabase/migrations`, and prod-US on manual dispatch. Until the secrets
   exist the workflow skips with a warning.
4. **Cloudflare R2**: create a bucket for signed model and app update files
   (used from 4.7); no public write access.
5. **Domain** for the sign-in page (the passkey relying party), separate from
   the web dashboard's static origin.

## Spec gaps found while scaffolding

Decisions for the owners; none block Phase 1.

- **Signals aren't stored.** The event JSON has `signals`, and the Activity
  view shows them, but the `events` table has no column for them. Add them in
  1.3 (e.g. three nullable `REAL` columns) or drop them from the Activity view.
- **Rollup semantics** chosen in `crates/types`: `total_ms` includes
  unanalyzable time (so coverage = `(total_ms - unanalyzable_ms) / total_ms`),
  `items` counts unanalyzable items too, and items with no category roll up
  under `uncategorized` because `daily_rollup.category` is `NOT NULL`.
- **Loopback redirect.** Supabase's redirect allowlist takes exact URLs, so a
  random loopback port can't be listed. The config uses `aiexposure://callback`
  as the primary redirect, as the spec's fallback allows; confirm in 2.3.
- **Schema holes for 4.3** (the tests cover the rules as written, not these):
  - The version trigger only guards `UPDATE`; a client can `DELETE` a blob and
    re-insert an older version.
  - The device cap only runs on `INSERT`; setting `revoked_at` back to `NULL`
    re-activates a device past the cap.
  - Nothing creates `profiles` rows; add an `auth.users` insert trigger when a
    feature needs them.
