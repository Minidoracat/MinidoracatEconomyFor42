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

def fit_grid(tone: np.ndarray, cand: np.ndarray, axis: int):
    """Period/offset of the checker squares along `axis` (0 = x), by grid search on the two
    border bands parallel to that axis. Each band line may sit on either parity, so a line
    scores max(match, 1 - match); the score is the mean over lines and candidate pixels."""
    if axis == 0:
        lines = np.concatenate([tone[5:30], tone[-30:-5]], axis=0)
        mask = np.concatenate([cand[5:30], cand[-30:-5]], axis=0)
    else:
        lines = np.concatenate([tone[:, 5:30].T, tone[:, -30:-5].T], axis=0)
        mask = np.concatenate([cand[:, 5:30].T, cand[:, -30:-5].T], axis=0)
    n = lines.shape[1]
    pos = np.arange(n)

    def score(p, o):
        exp = (np.floor((pos - o) / p) % 2) == 0
        m = (lines == exp[None, :]) | ~mask
        per_line = m.mean(axis=1)
        return np.maximum(per_line, 1 - per_line + (~mask).mean(axis=1)).mean()

    best = (-1.0, 25.0, 0.0)
    for p in np.arange(8.0, 40.0, 0.1):        # gpt-image-2 squares seen so far: ~15 and ~25 px
        for o in np.arange(0.0, p, 1.0):
            s = score(p, o)
            if s > best[0]:
                best = (s, p, o)
    _, p0, o0 = best
    for p in np.arange(p0 - 0.12, p0 + 0.12, 0.005):
        for o in np.arange(o0 - 1.2, o0 + 1.2, 0.1):
            s = score(p, o)
            if s > best[0]:
                best = (s, p, o)
    return float(best[1]), float(best[2] % best[1])




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
    px, ox = fit_grid(tone, cand, 0)
    py, oy = fit_grid(tone, cand, 1)
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
    dark = ndimage.mean(~tone, labels, idx)   # share of the darker checker tone inside the component
    touches = np.zeros(n + 1, bool)
    touches[np.unique(labels[bmask])] = True
    # the model's grid drifts inside the figure (W: half a square off between the legs), so an
    # enclosed neutral region that mixes both checker tones is background even off-phase; a
    # white-dress highlight is one tone only and stays
    for k, (sz, ag, dk) in enumerate(zip(sizes, agree, dark), start=1):
        if touches[k] or (sz >= 40 and ag >= 0.85) or (sz >= 150 and 0.12 <= dk <= 0.88):
            bg |= labels == k
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
