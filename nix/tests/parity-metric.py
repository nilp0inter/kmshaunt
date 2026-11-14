#!/usr/bin/env python3
"""Aggregate the kmshaunt<->ghostty pixel diff over all captured frame pairs.

Emits autoresearch METRIC lines (primary total_abs_diff, secondary pixel_diff)
and per-frame ASI counts. 0 == byte-exact. Reads the capture out-link directory.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

src = Path(sys.argv[1])
stems = sorted({p.name[len("kmshaunt-"):-4] for p in src.glob("kmshaunt-*.png")})

total = 0
ndiff = 0
nframes = 0
per = []
for stem in stems:
    a = np.asarray(Image.open(src / f"kmshaunt-{stem}.png").convert("RGB"), dtype=np.int32)
    b = np.asarray(Image.open(src / f"ghostty-{stem}.png").convert("RGB"), dtype=np.int32)
    if a.shape != b.shape:
        print(f"ASI size_mismatch_{stem.replace('-', '_')}=1")
        continue
    d = np.abs(a - b)
    t = int(d.sum())
    n = int((d.sum(axis=2) > 0).sum())
    total += t
    ndiff += n
    nframes += 1
    per.append((stem, n))

print(f"METRIC total_abs_diff={total}")
print(f"METRIC pixel_diff={ndiff}")
print(f"ASI frames={nframes}")
for stem, n in per:
    print(f"ASI px_{stem.replace('-', '_')}={n}")