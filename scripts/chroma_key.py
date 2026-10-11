# /// script
# requires-python = ">=3.9"
# dependencies = ["pillow>=10", "numpy>=1.24"]
# ///
"""Remove a solid key-color background and write an RGBA PNG.

By default every key-colored pixel is removed, including background pockets enclosed by
the subject (the generation prompt forbids the key color inside the subject). With
--keep-holes only background connected to the image border is removed, so key-colored
details inside the subject survive. Edge pixels get a soft alpha and are un-mixed
from the key color to remove color spill.

Usage:
  uv run chroma_key.py IN.png OUT.png [--key auto|green|magenta|blue|#RRGGBB]
                                      [--tolerance 60] [--softness 80] [--trim] [--keep-holes]
"""
from __future__ import annotations

import argparse
import sys
from collections import deque

import numpy as np
from PIL import Image

PRESETS = {
    "green": (0, 255, 0),
    "magenta": (255, 0, 255),
    "blue": (0, 0, 255),
}


def parse_key(spec: str, rgb: np.ndarray) -> np.ndarray:
    if spec == "auto":
        # Median of a thin border ring: robust to a subject that touches one edge.
        b = max(2, min(rgb.shape[:2]) // 100)
        ring = np.concatenate([
            rgb[:b].reshape(-1, 3), rgb[-b:].reshape(-1, 3),
            rgb[:, :b].reshape(-1, 3), rgb[:, -b:].reshape(-1, 3),
        ])
        return np.median(ring, axis=0)
    if spec in PRESETS:
        return np.array(PRESETS[spec], dtype=np.float64)
    s = spec.lstrip("#")
    if len(s) != 6:
        sys.exit(f"bad --key: {spec}")
    return np.array([int(s[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64)


def border_connected(mask: np.ndarray) -> np.ndarray:
    """Flood fill from every border pixel that is in `mask`."""
    h, w = mask.shape
    seen = np.zeros_like(mask)
    q: deque[tuple[int, int]] = deque()
    for y in range(h):
        for x in (0, w - 1):
            if mask[y, x] and not seen[y, x]:
                seen[y, x] = True
                q.append((y, x))
    for x in range(w):
        for y in (0, h - 1):
            if mask[y, x] and not seen[y, x]:
                seen[y, x] = True
                q.append((y, x))
    while q:
        y, x = q.popleft()
        for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
            if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True
                q.append((ny, nx))
    return seen


def dilate(mask: np.ndarray, r: int) -> np.ndarray:
    out = mask.copy()
    for _ in range(r):
        m = out.copy()
        m[1:] |= out[:-1]
        m[:-1] |= out[1:]
        m[:, 1:] |= out[:, :-1]
        m[:, :-1] |= out[:, 1:]
        out = m
    return out


def key_out(img: Image.Image, key_spec: str, tol: float, soft: float, keep_holes: bool = False) -> tuple[Image.Image, np.ndarray]:
    rgb = np.asarray(img.convert("RGB"), dtype=np.float64)
    key = parse_key(key_spec, rgb)
    dist = np.linalg.norm(rgb - key, axis=2)

    # Background region: pixels within tolerance (only border-connected ones with keep_holes).
    near = dist < tol + soft
    bg_core = border_connected(dist < tol) if keep_holes else dist < tol
    # Soft band: pixels near the key color and touching the removed region.
    edge = near & ~bg_core & dilate(bg_core, 3)

    alpha = np.ones(dist.shape)
    alpha[bg_core] = 0.0
    alpha[edge] = np.clip((dist[edge] - tol) / soft, 0.0, 1.0)

    # Un-mix spill: observed = a*fg + (1-a)*key  ->  fg = (observed - (1-a)*key) / a
    fg = rgb.copy()
    a = alpha[edge][:, None]
    safe = np.maximum(a, 0.05)
    fg[edge] = np.clip((rgb[edge] - (1 - a) * key) / safe, 0, 255)
    fg[bg_core] = 0  # no key color hiding under alpha=0 (avoids fringes when filtered)

    rgba = np.dstack([fg, alpha * 255]).round().astype(np.uint8)
    return Image.fromarray(rgba, "RGBA"), key


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--key", default="auto", help="auto (sample the border), green, magenta, blue, or #RRGGBB")
    ap.add_argument("--tolerance", type=float, default=60, help="RGB distance treated as pure background")
    ap.add_argument("--softness", type=float, default=80, help="extra distance blended as a soft edge")
    ap.add_argument("--trim", action="store_true", help="crop to the opaque bounding box")
    ap.add_argument("--keep-holes", action="store_true", help="only remove background connected to the border")
    args = ap.parse_args()

    out, key = key_out(Image.open(args.input), args.key, args.tolerance, args.softness, args.keep_holes)
    if args.trim:
        bbox = out.getchannel("A").getbbox()
        if bbox:
            out = out.crop(bbox)
    out.save(args.output)
    a = np.asarray(out.getchannel("A"))
    print(f"key=#{int(key[0]):02X}{int(key[1]):02X}{int(key[2]):02X} "
          f"transparent={np.mean(a == 0):.1%} size={out.size[0]}x{out.size[1]} -> {args.output}")


if __name__ == "__main__":
    main()
