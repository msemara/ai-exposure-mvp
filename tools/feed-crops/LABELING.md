# Feed-crop dataset: capture, labeling and benchmark target

Spec step 0.4. This dataset feeds the Phase 1 baseline model (1.4), the
shared-encoder decision at Gate 1, and fusion calibration (3.4). It is on the
critical path, so collection starts in week 1.

## What we collect

Crops of real feeds as a user sees them: compressed, cropped, with UI chrome,
captions and overlays. Only team members' own sessions and public datasets.
**No user content, ever** (CLAUDE.md rule 5).

1. Install: `pip install -r tools/feed-crops/requirements.txt`.
2. Open the feed in a browser window and note the feed column's screen
   rectangle (LEFT,TOP,WIDTH,HEIGHT).
3. Run `python tools/feed-crops/capture.py --platform <name> --region L,T,W,H`
   and scroll normally. A crop is saved only when the content changes (dHash
   distance > 10), blank/black frames are skipped, and each session gets a
   folder with `manifest.jsonl`.
4. Upload the session folder to the private dataset bucket, then delete the
   local copy. `tools/feed-crops/data/` is git-ignored; never commit crops.

Platforms to cover: Instagram, TikTok (web), YouTube (Shorts and home),
Facebook, X, Reddit, Pinterest. Capture both still posts and video (a crop of
a playing video is a `video_frame`).

## Labels

Import crops into [Label Studio](https://labelstud.io) with
`label-studio.xml` from this folder. Each crop gets:

| Field | Values | Notes |
| --- | --- | --- |
| `origin` | `ai`, `human`, `unsure` | Required. See evidence rules below. |
| `evidence` | `platform_label`, `c2pa`, `creator_disclosure`, `known_ai_account`, `known_human_source`, `generator_watermark`, `visual_judgment` | Required, multi-select. |
| `ai_extent` | `fully_generated`, `edited`, `composite` | Only when `origin = ai`. |
| `media` | `image`, `video_frame`, `text` | What fills most of the crop. |
| `category` | see `label-studio.xml` | Draft list for the zero-shot head (2.5). |
| `quality` | `ok`, `mostly_ui`, `occluded`, `duplicate` | Anything but `ok` is excluded from the benchmark. |

**Evidence rules.** People are poor at spotting AI images by eye, so the
benchmark must not rest on annotator impressions:

- `ai` requires at least one hard signal: a platform AI label, a C2PA manifest,
  the creator saying it is AI, a known AI-only account, or a visible generator
  watermark. Check the original post when needed.
- `human` requires a known human source (e.g. a news agency photo, a creator's
  behind-the-scenes, pre-2022 content) or no AI signal after checking the post
  and the account.
- Anything decided only by `visual_judgment` is labeled `unsure`. Unsure crops
  may be used for training experiments but never in the test set.

**Agreement.** A second person labels a random 10% of crops. Target Cohen's
κ ≥ 0.7 on `origin`; below that, fix the guide before labeling more.

## Benchmark size target (Phase 1)

| Split | Target | Why |
| --- | --- | --- |
| Test (frozen) | 4,000 crops: 2,000 `ai`, 2,000 `human`, hard evidence only | Overall recall/precision to about ±1.6 pp (95% CI at 0.85) |
| — per platform | ≥ 250 `ai` and ≥ 250 `human` on each of the top 4 platforms | per-platform numbers to about ±4.5 pp |
| — video frames | ≥ 800 of the 4,000 | video needs its own number, since frames are blurrier |
| Train + validation | ≥ 6,000 feed crops, plus public AI-image datasets | fine-tuning the detection head; grows monthly |

Rules that keep the benchmark honest:

- **Split by source, not by crop.** All crops from the same post or account go
  to the same split; near-duplicates (dHash distance ≤ 10) never straddle
  splits.
- **Freeze the test set** once it reaches target, and version it
  (`bench-YYYY-MM`). Report every model against the same frozen version.
- **Keep generators balanced**: note the generator when known, so we can see
  whether a model only knows last year's generators.

At about 1 minute per crop (checking the post for evidence), the 4,000-crop
test set is roughly 70 person-hours; plan it across both developers and any
helpers from week 1.

## Storage and access

Crops live only in a private bucket with access limited to the team. They are
third-party content: use them for evaluation and training only, don't publish
them, and delete a crop on request from its owner. Confirm with counsel before
the dataset is used beyond internal benchmarking.
