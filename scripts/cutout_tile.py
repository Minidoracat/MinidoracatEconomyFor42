# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10", "numpy", "scipy"]
# ///
"""Checkerboard-aware cutout for gpt-image-2 outputs.

    uv run clean.py <in.png> <out.png>

RGBA input: alpha > 128 is the figure (every piece kept, specks < 20 px dropped).
RGB input on a checkerboard: a pixel is background when it is neutral and light AND the
connected region it belongs to follows the checkerboard grid (period ~25.5 px, phase fitted on
the border) - so the enclosed gaps between the legs and inside the hair go too, while the white
dress (no grid pattern) stays. Edges: 1 px erosion + 0.6 px blur, bbox crop.
"""
import sys
import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

def fit_grid(tone: np.ndarray, axis: int):
    """Least-squares period/offset of the tone transitions along `axis` (0 = rows -> x grid)."""
    lines = [tone[5], tone[12], tone[-6], tone[-13]] if axis == 0 else [tone[:, 5], tone[:, 12], tone[:, -6], tone[:, -13]]
    periods, offsets = [], []
    for line in lines:
        pos = np.where(line[1:] != line[:-1])[0] + 1
        if len(pos) < 6:
            continue
        k = np.arange(len(pos))
        p, o = np.polyfit(k, pos, 1)
        periods.append(p)
        offsets.append(o % p)
    return float(np.median(periods)), float(np.median(offsets))




def rgb_background(a: np.ndarray) -> np.ndarray:
    rgb = a[:, :, :3].astype(int)
    h, w = rgb.shape[:2]
    neutral = (np.abs(rgb[:, :, 0] - rgb[:, :, 1]) <= 4) & (np.abs(rgb[:, :, 1] - rgb[:, :, 2]) <= 4) & (np.abs(rgb[:, :, 0] - rgb[:, :, 2]) <= 4)
    light = rgb.min(axis=2) >= 228
    cand = neutral & light
    lum = rgb.mean(axis=2)
    # border pixels: fit the checker phase and the two tones
    bmask = np.zeros((h, w), bool)
    bmask[:30] = bmask[-30:] = True
    bmask[:, :30] = bmask[:, -30:] = True
    bl = lum[bmask & cand]
    thr = (bl.max() + bl.min()) / 2
    tone = lum > thr  # True = white square
    px, ox = fit_grid(tone, 0)
    py, oy = fit_grid(tone, 1)
    ys, xs = np.mgrid[0:h, 0:w]
    sample = bmask & cand
    best, best_flip = -1.0, False
    parity = (np.floor((xs - ox) / px) + np.floor((ys - oy) / py)) % 2
    for flip in (False, True):
        exp = (parity == 0) != flip
        agree = (exp[sample] == tone[sample]).mean()
        if agree > best:
            best, best_flip = agree, flip
    expected = (parity == 0) != best_flip
    match = (expected == tone)
    labels, n = ndimage.label(cand)
    bg = np.zeros((h, w), bool)
    idx = np.arange(1, n + 1)
    sizes = ndimage.sum(cand, labels, idx)
    agree = ndimage.mean(match, labels, idx)
    touches = np.zeros(n + 1, bool)
    touches[np.unique(labels[bmask])] = True
    for k, (sz, ag) in enumerate(zip(sizes, agree), start=1):
        if touches[k] or (sz >= 40 and ag >= 0.85):
            bg |= labels == k
    print(f"  checker phase agreement {best:.3f}, tone threshold {thr:.0f}, bg components merged")
    return bg


def main(src: str, dst: str) -> None:
    im = Image.open(src).convert("RGBA")
    a = np.asarray(im)
    alpha = a[:, :, 3]
    if (alpha == 255).mean() > 0.95:
        fg = ~rgb_background(a)
    else:
        fg = alpha > 128
    labels, n = ndimage.label(fg)
    sizes = ndimage.sum(fg, labels, range(1, n + 1))
    keep = np.zeros_like(fg)
    for k, sz in enumerate(sizes, start=1):
        if sz >= 20:
            keep |= labels == k
    am = Image.fromarray(np.where(keep, 255, 0).astype(np.uint8)).filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.6))
    out = im.copy()
    out.putalpha(am)
    out = out.crop(out.getbbox())
    out.save(dst, optimize=True)
    print(f"{src} -> {dst} {out.size}, pieces {int((sizes >= 20).sum())}/{n}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
