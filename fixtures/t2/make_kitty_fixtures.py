#!/usr/bin/env python3
"""Regenerate the M4.6 kitty escape fixtures (fixtures/t2/kitty-*.bin).

Deterministic, stdlib-only. Every fixture is a raw VT byte stream the T2
golden renderer (tools/render_golden.zig) feeds to libghostty-vt:

  kitty-placement.bin  a=T at two cursor positions, upscaled and downscaled
  kitty-layers.bin     below_text / above_text / below_background z-order
  kitty-crop.bin       source-rect crop (x/y/w/h) + bilinear scaling
  kitty-scroll.bin     image scrolled partly off screen (ESC[3S)
  kitty-delete.bin     delete-by-id (a=d,d=i) erases one of two images
  kitty-animation.bin  two-frame animation (a=f / a=a s=2) that parks on the
                       last frame; the frame-2 golden is rendered with
                       --animation-ms 40, and a T3 VM screenshot settles on
                       frame 2 deterministically

Images are raw RGBA (f=32), small fixed pixel sizes displayed over c/r cell
spans, so the fixtures do not depend on the font's cell metrics. q=2
suppresses replies, C=1 keeps the cursor at the placement cell. Kitty places
images at the CURSOR, so each transmit is preceded by a CSI row;col H.

Layer encoding (ghostty): z < -2^30 is below_background, z < 0 is
below_text, z >= 0 is above_text.

Run from the repository root:  python3 fixtures/t2/make_kitty_fixtures.py
Then bless the goldens:        just update-goldens
"""

import base64
from pathlib import Path

HERE = Path(__file__).resolve().parent

ESC = b"\x1b"
APC = ESC + b"_G"
ST = ESC + b"\\"


def csi(s: str) -> bytes:
    return ESC + b"[" + s.encode()


def cursor(row: int, col: int) -> bytes:
    """Zero-based cell -> CSI row;col H (1-based)."""
    return csi(f"{row + 1};{col + 1}H")


def solid(w: int, h: int, rgba: tuple) -> bytes:
    return bytes(rgba) * (w * h)


def transmit(payload: bytes, keys: str) -> bytes:
    b64 = base64.b64encode(payload).decode()
    return APC + keys.encode() + b";" + b64.encode() + ST


def image_keys(i: int, w: int, h: int, extra: str = "") -> str:
    return f"f=32,s={w},v={h},i={i},a=T,C=1,q=2" + ("," + extra if extra else "")


def checker4() -> bytes:
    """4x4: red/green over blue/yellow quadrants."""
    r, g, b, y = (255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255), (255, 255, 0, 255)
    rows = [[r, r, g, g], [r, r, g, g], [b, b, y, y], [b, b, y, y]]
    return b"".join(bytes(px) for row in rows for px in row)


def gradient8() -> bytes:
    """8x8 smooth gradient, distinct in x and y."""
    return b"".join(
        bytes((x * 32, y * 32, 255 - x * 32, 255)) for y in range(8) for x in range(8)
    )


def placement() -> bytes:
    px = checker4()
    out = bytearray()
    # 4x4 pixels over 4x2 cells (upscale) at cell (2, 1).
    out += cursor(1, 2)
    out += transmit(px, image_keys(1, 4, 4, "c=4,r=2,z=0"))
    # Same pixels over 2x1 cells (downscale) at cell (10, 4).
    out += cursor(4, 10)
    out += transmit(px, image_keys(2, 4, 4, "c=2,r=1,z=0"))
    out += cursor(8, 0) + b"kitty placement: 4x2 and 2x1 cells"
    return bytes(out)


def layers() -> bytes:
    out = bytearray()
    out += cursor(0, 0) + b"ABCD"
    # Opaque blue cell background at cols 8..11: hides the below_background
    # image drawn under it.
    out += cursor(0, 8) + csi("44m") + b"    " + csi("0m")
    out += cursor(0, 0)
    out += transmit(solid(2, 2, (0, 0, 255, 255)), image_keys(1, 2, 2, "c=2,r=1,z=-1"))
    out += cursor(0, 2)
    out += transmit(solid(2, 2, (255, 0, 0, 255)), image_keys(2, 2, 2, "c=2,r=1,z=1"))
    out += cursor(0, 8)
    out += transmit(
        solid(2, 2, (0, 255, 0, 255)), image_keys(3, 2, 2, "c=4,r=1,z=-1073741825")
    )
    out += cursor(2, 0) + b"layers: below-text / above-text / below-bg"
    return bytes(out)


def crop() -> bytes:
    px = gradient8()
    out = bytearray()
    # Crop the centre 4x4 of the 8x8 image, scale it over 8x4 cells.
    out += cursor(1, 1)
    out += transmit(px, image_keys(1, 8, 8, "x=2,y=2,w=4,h=4,c=8,r=4,z=0"))
    # The uncropped image next to it, same display span.
    out += cursor(1, 20)
    out += transmit(px, image_keys(2, 8, 8, "c=8,r=4,z=0"))
    out += cursor(7, 0) + b"kitty crop: centre 4x4 of 8x8, scaled 8x4 cells"
    return bytes(out)


def scroll() -> bytes:
    out = bytearray()
    out += cursor(0, 0)
    # 4x4-cell magenta image, below_text so the label draws over it.
    out += transmit(solid(4, 4, (255, 0, 255, 255)), image_keys(1, 4, 4, "c=4,r=4,z=-1"))
    # Scroll up three rows: only the image's bottom cell-row stays on screen.
    out += csi("3S")
    out += b"after-scroll"
    return bytes(out)


def delete() -> bytes:
    out = bytearray()
    out += cursor(1, 1)
    out += transmit(solid(2, 2, (255, 0, 0, 255)), image_keys(1, 2, 2, "c=3,r=2,z=0"))
    out += cursor(1, 9)
    out += transmit(solid(2, 2, (0, 255, 0, 255)), image_keys(2, 2, 2, "c=3,r=2,z=0"))
    # Delete image 1 by id; its rows repaint to the background.
    out += APC + b"a=d,d=i,i=1,q=2" + ST
    out += cursor(5, 0) + b"kitty delete: red gone, green stays"
    return bytes(out)


def animation() -> bytes:
    out = bytearray()
    red = solid(4, 4, (255, 0, 0, 255))
    blue = solid(4, 4, (0, 0, 255, 255))
    out += cursor(0, 0)
    # Root frame (red), displayed over 2x2 cells.
    out += transmit(red, image_keys(1, 4, 4, "c=2,r=2,z=0"))
    # Frame 2 (blue), 40 ms gap; give the root frame the same gap, then play
    # once and park on the last frame (s=2, no loop).
    b64 = base64.b64encode(blue).decode()
    out += APC + f"a=f,i=1,f=32,s=4,v=4,r=2,z=40,q=2;{b64}".encode() + ST
    out += APC + b"a=a,i=1,r=1,z=40,q=2" + ST
    out += APC + b"a=a,i=1,s=2,q=2" + ST
    out += cursor(3, 0) + b"kitty animation: frame 1 red, frame 2 blue"
    return bytes(out)


FIXTURES = {
    "kitty-placement.bin": placement,
    "kitty-layers.bin": layers,
    "kitty-crop.bin": crop,
    "kitty-scroll.bin": scroll,
    "kitty-delete.bin": delete,
    "kitty-animation.bin": animation,
}


def main() -> None:
    for name, make in FIXTURES.items():
        data = make()
        (HERE / name).write_bytes(data)
        print(f"{name}: {len(data)} bytes")


if __name__ == "__main__":
    main()
