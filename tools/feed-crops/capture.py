#!/usr/bin/env python3
"""Capture feed crops for the labeled benchmark (spec step 0.4).

Run this on a team machine while scrolling a feed. It grabs one screen
region (the feed column) once per interval, and saves a crop only when the
content changed, using the same dHash gate as the app's 1 Hz probe.

This is a team data-collection tool, not part of the app. Crops contain
third-party content: they are written under tools/feed-crops/data/ (ignored
by git) and must go to the private dataset bucket, never to the repo. Never
point it at a region showing private messages, banking or other personal data.

    python capture.py --platform instagram --region 600,120,720,900
    python capture.py --platform tiktok --monitor 1 --interval 0.5

Stop with Ctrl+C. See LABELING.md for what happens next.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import time
import uuid
from pathlib import Path

from PIL import Image

HASH_SIZE = 8  # 64-bit dHash, as in the app's probe.
DEFAULT_THRESHOLD = 10  # Hamming distance that counts as "content changed".
DATA_DIR = Path(__file__).resolve().parent / "data" / "raw"


def dhash(image: Image.Image, size: int = HASH_SIZE) -> int:
    """Difference hash: compare horizontally adjacent pixels of a small grayscale thumbnail."""
    small = image.convert("L").resize((size + 1, size), Image.Resampling.LANCZOS)
    pixels = small.tobytes()
    bits = 0
    for row in range(size):
        for col in range(size):
            left = pixels[row * (size + 1) + col]
            right = pixels[row * (size + 1) + col + 1]
            bits = (bits << 1) | (left > right)
    return bits


def hamming(a: int, b: int) -> int:
    return (a ^ b).bit_count()


def is_blank(image: Image.Image) -> bool:
    """True for (near-)uniform frames, e.g. DRM video that captures as black."""
    lo, hi = image.convert("L").getextrema()
    return hi - lo < 8


def parse_region(value: str) -> dict[str, int]:
    try:
        left, top, width, height = (int(v) for v in value.split(","))
    except ValueError:
        raise argparse.ArgumentTypeError("region must be LEFT,TOP,WIDTH,HEIGHT") from None
    if width <= 0 or height <= 0:
        raise argparse.ArgumentTypeError("region width and height must be positive")
    return {"left": left, "top": top, "width": width, "height": height}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--platform", required=True, help="feed being captured, e.g. instagram, tiktok, youtube, x")
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--region", type=parse_region, help="LEFT,TOP,WIDTH,HEIGHT in screen pixels")
    where.add_argument("--monitor", type=int, help="whole monitor number (1 = primary)")
    parser.add_argument("--interval", type=float, default=1.0, help="seconds between probes (default 1.0)")
    parser.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD, help="dHash distance to save a new crop")
    parser.add_argument("--out", type=Path, default=DATA_DIR, help="output directory (default data/raw)")
    args = parser.parse_args(argv)

    import mss  # Imported late so --help and the hash helpers work without it.

    session = f"{dt.datetime.now(dt.timezone.utc):%Y%m%dT%H%M%SZ}-{uuid.uuid4().hex[:6]}"
    out_dir = args.out / session
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = out_dir / "manifest.jsonl"

    saved = 0
    last_hash: int | None = None
    with mss.mss() as screen, manifest_path.open("a", encoding="utf-8") as manifest:
        region = args.region or screen.monitors[args.monitor]
        print(f"Capturing {args.platform} into {out_dir}. Ctrl+C to stop.", file=sys.stderr)
        try:
            while True:
                started = time.monotonic()
                shot = screen.grab(region)
                image = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
                if not is_blank(image):
                    current = dhash(image)
                    if last_hash is None or hamming(current, last_hash) > args.threshold:
                        last_hash = current
                        saved += 1
                        name = f"{saved:05d}.png"
                        image.save(out_dir / name, optimize=True)
                        record = {
                            "file": name,
                            "session": session,
                            "platform": args.platform,
                            "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
                            "width": image.width,
                            "height": image.height,
                            "dhash": f"{current:016x}",
                        }
                        manifest.write(json.dumps(record) + "\n")
                        manifest.flush()
                time.sleep(max(0.0, args.interval - (time.monotonic() - started)))
        except KeyboardInterrupt:
            pass
    print(f"Saved {saved} crops to {out_dir}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
