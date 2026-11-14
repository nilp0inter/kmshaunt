#!/usr/bin/env python3
"""Generate the ghostty <-> kmshaunt byte-exact parity frames.

Every frame is a self-contained, output-only byte payload for a 100x30 pty.
The harness writes the exact bytes to both terminals, waits for the screen to
settle, screenshots, and diffs pixels.

Rules baked into this generator:
  * COLS = 100, ROWS = 30 for every frame.
  * Nothing depends on time, queries, the shell, or prior screen state.
  * No ESC[6n / DA / DSR / XTVERSION / OSC-query sequences are emitted.
  * All placement uses CUP/HVP; frames contain no CR or LF at all, so wrapping
    is never an accidental side effect (except frame 23, which tests wrapping).
  * Prologue: RIS, hide cursor, home, SGR reset.
  * Epilogue: SGR reset, restore G0/G1 charsets, re-enable autowrap, hide
    cursor, home.  Cursor frames instead leave the cursor visible at a fixed
    cell with a specific DECSCUSR style.

Run from anywhere:
    python3 fixtures/ghostty-parity/generate_frames.py

Output is deterministic; re-running rewrites identical bytes.
"""

from __future__ import annotations

import re
import unicodedata
from pathlib import Path

COLS = 100
ROWS = 30

HERE = Path(__file__).resolve().parent
OUT_DIR = HERE / "frames"

E = "\x1b"
RESET = E + "[0m"


def csi(params: str) -> str:
    return E + "[" + params


def cup(row: int, col: int) -> str:
    """1-based row/column -> CUP."""
    return csi(f"{row};{col}H")


def sgr(*codes) -> str:
    """Build an SGR sequence.  Codes may be ints or raw strings like '4:3'."""
    return csi(";".join(str(c) for c in codes) + "m")


def fg256(n: int) -> str:
    return f"38;5;{n}"


def bg256(n: int) -> str:
    return f"48;5;{n}"


def fgrgb(r: int, g: int, b: int) -> str:
    return f"38;2;{r};{g};{b}"


def bgrgb(r: int, g: int, b: int) -> str:
    return f"48;2;{r};{g};{b}"


PROLOGUE = E + "c" + csi("?25l") + csi("H") + csi("0m")
EPILOGUE = (
    csi("0m") + E + "(B" + E + ")B" + "\x0f" + csi("?7h") + csi("?25l") + csi("H")
)


class Frame:
    """Tiny append-only builder for one payload."""

    def __init__(self) -> None:
        self.parts: list[str] = []

    def raw(self, data: str) -> "Frame":
        self.parts.append(data)
        return self

    def at(self, row: int, col: int, text: str = "", codes=()) -> "Frame":
        self.parts.append(cup(row, col))
        if codes:
            self.parts.append(sgr(*codes))
        # Empty text is a "set state at this position" call: keep the SGR
        # active so following raw() output uses it.
        if text:
            self.parts.append(text)
            self.parts.append(RESET)
        return self

    def title(self, text: str) -> "Frame":
        return self.at(1, 1, text, (1,))

    def build(self) -> str:
        return "".join(self.parts)


def ruler() -> str:
    """100-cell column ruler: tens digits, '+' every 5, '.' elsewhere."""
    out = []
    for c in range(COLS):
        if c % 10 == 0:
            out.append(str((c // 10) % 10))
        elif c % 5 == 0:
            out.append("+")
        else:
            out.append(".")
    return "".join(out)


def dwidth(s: str) -> int:
    """Display width assuming East-Asian Wide/Fullwidth = 2 cells."""
    w = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        if unicodedata.east_asian_width(ch) in ("W", "F"):
            w += 2
        else:
            w += 1
    return w


def pad_display(s: str, width: int) -> str:
    delta = width - dwidth(s)
    if delta < 0:
        raise ValueError(f"{s!r} is wider than {width} cells")
    return s + " " * delta


# --------------------------------------------------------------------------
# 01 - ASCII + basic SGR
# --------------------------------------------------------------------------


def frame_01_ascii() -> str:
    f = Frame()
    f.title("01  ASCII + basic SGR  ·  100x30  ·  output-only")
    chunks = [
        ("0x20-3F", "".join(chr(c) for c in range(0x20, 0x40))),
        ("0x40-5F", "".join(chr(c) for c in range(0x40, 0x60))),
        ("0x60-7E", "".join(chr(c) for c in range(0x60, 0x7F))),
    ]
    for i, (label, text) in enumerate(chunks):
        f.at(3 + i, 1, label + ":", (2,))
        f.at(3 + i, 11, text)

    f.at(7, 1, "pangram:", (2,))
    f.at(7, 11, "The quick brown fox jumps over the lazy dog. 0123456789")

    f.at(9, 1, "16 ANSI foregrounds on explicit bg 47:", (1,))
    for i in range(8):
        f.at(10, 1 + i * 12, f" {30 + i} ABCDE ", (30 + i, 47))

    f.at(11, 1, "bright foregrounds 90-97 on bg 40:", (1,))
    for i in range(8):
        f.at(12, 1 + i * 12, f" {90 + i} abcde ", (90 + i, 40))

    f.at(13, 1, "backgrounds 40-47 with fg 97:", (1,))
    for i in range(8):
        f.at(14, 1 + i * 12, f" bg{40 + i} ", (97, 40 + i))

    f.at(15, 1, "bright backgrounds 100-107 with fg 30:", (1,))
    for i in range(8):
        f.at(16, 1 + i * 12, f" bg{100 + i} ", (30, 100 + i))

    f.at(18, 1, "bold vs normal:", (1,))
    f.at(18, 17, "normal", (0,))
    f.at(18, 26, "bold red", (1, 31))
    f.at(18, 38, "dim blue", (2, 34))
    f.at(18, 50, "bold+underline", (1, 4))

    f.at(20, 1, "printable ASCII hex dump (reverse video makes SPACE visible):", (2,))
    for j, start in enumerate(range(0x20, 0x80, 16)):
        row = 21 + j
        text = "".join(chr(c) for c in range(start, min(start + 16, 0x7F)))
        f.at(row, 1, f"{start:02X}:", (2,))
        f.at(row, 7, text, (7,))

    f.at(
        28,
        1,
        "LF-free / CR-free: every position is placed with CUP; all 95 printable ASCII bytes are present.",
        (2,),
    )
    return f.build()


# --------------------------------------------------------------------------
# 02 - SGR text attributes
# --------------------------------------------------------------------------


def frame_02_attributes() -> str:
    f = Frame()
    f.title("02  SGR text attributes (line attributes + off codes)")
    rows = [
        (3, "SGR 1 bold", (1,)),
        (4, "SGR 2 dim", (2,)),
        (5, "SGR 3 italic", (3,)),
        (6, "SGR 1+3 bold italic", (1, 3)),
        (7, "SGR 5 slow blink", (5,)),
        (8, "SGR 6 rapid blink", (6,)),
        (9, "SGR 7 reverse", (7,)),
        (10, "SGR 8 invisible on bg 41", (8, 41)),
        (11, "SGR 9 strikethrough", (9,)),
        (12, "SGR 1+3+9 combined", (1, 3, 9)),
    ]
    for row, label, codes in rows:
        f.at(row, 1, label + ":", (2,))
        f.at(row, 26, "The quick brown fox 0123", codes)

    f.at(13, 1, "SGR 53 overline:", (2,))
    f.at(13, 26, "OVERLINED 0123", (53,))

    f.at(14, 1, "off codes must restore normal rendering:", (1,))
    f.at(15, 1, "22/23:", (2,))
    f.raw(sgr(1) + "BOLD" + sgr(22) + " normal ")
    f.raw(sgr(3) + "ITALIC" + sgr(23) + " normal ")
    f.raw(sgr(4) + "UNDER" + sgr(24) + " normal")
    f.raw(RESET)

    f.at(16, 1, "25/27/28/29:", (2,))
    f.raw(sgr(5) + "BLINK" + sgr(25) + " normal ")
    f.raw(sgr(7) + "REV" + sgr(27) + " normal ")
    f.raw(sgr(8, 42) + "HIDDEN" + sgr(28) + " normal ")
    f.raw(sgr(9) + "STRIKE" + sgr(29) + " normal")
    f.raw(RESET)

    f.at(18, 1, "SGR 0 clears a whole stack:", (2,))
    f.raw(sgr(1, 3, 4, 7, 9, 53) + "MULTI" + sgr(0) + " normal")

    f.at(20, 1, "isolation (attribute, then reset, then following text):", (1,))
    isolation = [
        (21, "bold", 1),
        (22, "italic", 3),
        (23, "underline", 4),
        (24, "strike", 9),
    ]
    for row, name, code in isolation:
        f.at(row, 1, name + ":", (2,))
        f.raw(cup(row, 14) + sgr(code) + "SAMPLE" + sgr(0) + " | normal")

    f.at(26, 1, "framed / encircled / superscript / subscript:", (1,))
    f.at(26, 50, "51 framed", (51,))
    f.at(26, 62, "52 encircled", (52,))
    f.at(26, 76, "73 H2O", (73,))
    f.at(26, 84, "74 x2", (74,))
    f.at(28, 1, "NOTE: SGR 5/6 blink is animated; capture must be phase-stable.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 03 - underline styles and underline colour
# --------------------------------------------------------------------------


def frame_03_underline() -> str:
    f = Frame()
    f.title("03  Underline styles + SGR 58 underline colour")
    f.at(3, 1, "underline on descenders and spaces follows.", (2,))

    samples = [
        (4, "SGR 4  single", (4,)),
        (5, "SGR 21 double", (21,)),
        (6, "SGR 4:2 double", ("4:2",)),
        (7, "SGR 4:3 curly", ("4:3",)),
        (8, "SGR 4:4 dotted", ("4:4",)),
        (9, "SGR 4:5 dashed", ("4:5",)),
    ]
    for row, label, codes in samples:
        f.at(row, 1, label + ":", (2,))
        f.at(row, 24, "gypqj  The quick brown fox 0123", codes)

    f.at(11, 1, "SGR 58;5;196 red underline:", (2,))
    f.at(11, 32, "coloured underline over gypqj", (4, "58;5;196"))
    f.at(12, 1, "SGR 58;2;0;255;128 truecolor underline:", (2,))
    f.at(12, 42, "truecolor underline", (4, "58;2;0;255;128"))
    f.at(13, 1, "SGR 58;5;21 then SGR 59 reset mid-line:", (2,))
    f.raw(cup(13, 46) + sgr(4, "58;5;21") + "blue underline" + sgr(59) + " default again")
    f.at(14, 1, "SGR 4:3 curly + 58;2;255;0;255:", (2,))
    f.at(14, 36, "curly magenta underline", ("4:3", "58;2;255;0;255"))

    f.at(16, 1, "underline over spaces:", (2,))
    f.raw(cup(16, 23) + sgr(4) + "          " + sgr(0) + " <- 10 underlined spaces")
    f.at(17, 1, "underline across wide CJK cells:", (2,))
    f.at(17, 36, "中文宽字符下划线", (4,))
    f.at(18, 1, "bold + underline + colour:", (2,))
    f.at(18, 30, "BOLD UNDER COLOUR", (1, 4, "58;2;255;128;0"))

    f.at(20, 1, "SGR 4:0 explicitly clears only the underline:", (2,))
    f.raw(cup(20, 50) + sgr("4:3") + "curly" + sgr("4:0") + " none")
    f.at(22, 1, "SGR 21 and SGR 4:2 must be visually identical double underlines.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 04 - colour modes
# --------------------------------------------------------------------------


def frame_04_colors() -> str:
    f = Frame()
    f.title("04  Colour modes: 16 / 256 / truecolor / default / reverse")

    f.at(3, 1, "16 colours, fg on bg 47:", (2,))
    for i in range(8):
        f.at(4, 1 + i * 12, f" fg{30 + i} ", (30 + i, 47))
    f.at(5, 1, "bright:", (2,))
    for i in range(8):
        f.at(5, 10 + i * 11, f" {90 + i} ", (90 + i, 40))

    f.at(7, 1, "256-colour palette 0-15 (bg) with contrasting fg:", (2,))
    for i in range(16):
        fg = 15 if i < 8 else 0
        f.at(8, 1 + i * 6, f"{i:03d}  ", (fg, bg256(i)))

    f.at(9, 1, "256-colour cube 16-231 (1 cell per colour, two groups per row):", (2,))
    groups = (16, 52, 88, 124, 160, 196)
    for pair in range(0, 6, 2):
        row = 10 + pair // 2
        for j in range(72):
            idx = groups[pair] + j if j < 36 else groups[pair + 1] + (j - 36)
            col = 1 + j if j < 36 else 50 + (j - 36)
            f.raw(cup(row, col) + sgr(bg256(idx)) + " ")
        f.raw(RESET)

    f.at(13, 1, "greyscale 232-255:", (2,))
    for i in range(24):
        f.raw(cup(13, 22 + i * 3) + sgr(bg256(232 + i)) + "   ")
    f.raw(RESET)

    f.at(15, 1, "38;2 foreground ramp:", (2,))
    for c in range(60):
        f.raw(cup(15, 26 + c) + sgr(fgrgb(255 - c * 4, c * 4, 128)) + "#")
    f.raw(RESET)

    f.at(16, 1, "38;2 foreground ramp 2:", (2,))
    for c in range(60):
        f.raw(cup(16, 26 + c) + sgr(fgrgb(c * 4, 255 - c * 4, 64)) + "@")
    f.raw(RESET)

    f.at(17, 1, "explicit fg/bg, then SGR 39/49 defaults mid-line:", (2,))
    f.raw(cup(17, 52) + sgr(fgrgb(10, 200, 30), bgrgb(20, 20, 80)) + "CUSTOM")
    f.raw(sgr(39, 49) + " DEFAULT")
    f.raw(RESET)

    f.at(19, 1, "truecolor background gradient (3 x 100 cells):", (2,))
    for r in range(3):
        f.raw(cup(20 + r, 1))
        for c in range(COLS):
            if r == 0:
                rr, gg, bb = 255, c * 255 // (COLS - 1), 0
            elif r == 1:
                rr, gg, bb = 0, 255, c * 255 // (COLS - 1)
            else:
                rr, gg, bb = c * 255 // (COLS - 1), 0, 255
            f.raw(sgr(bgrgb(rr, gg, bb)) + " ")
        f.raw(RESET)

    f.at(24, 1, "default background row (theme-dependent by design):", (2,))
    f.at(25, 1, "reverse video over truecolor background:", (2,))
    f.raw(cup(25, 44) + sgr(bgrgb(30, 120, 200), 7) + "REVERSE")
    f.raw(RESET)

    f.at(27, 1, "mixed: 256 bg + truecolor fg, then truecolor bg + 256 fg:", (2,))
    f.at(28, 30, "256 bg / rgb fg", (fgrgb(255, 230, 0), bg256(54)))
    f.at(28, 52, "rgb bg / 256 fg", (fg256(226), bgrgb(60, 0, 90)))
    f.at(29, 1, "Explicit colours everywhere except rows explicitly marked default.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 05 - box drawing + DEC Special Graphics
# --------------------------------------------------------------------------


BOX_STYLES = {
    "light": ("┌", "─", "┬", "┐", "├", "┼", "┤", "└", "┴", "┘", "│"),
    "heavy": ("┏", "━", "┳", "┓", "┣", "╋", "┫", "┗", "┻", "┛", "┃"),
    "double": ("╔", "═", "╦", "╗", "╠", "╬", "╣", "╚", "╩", "╝", "║"),
    "mixed": ("╒", "═", "╤", "╕", "╞", "╪", "╡", "╘", "╧", "╛", "│"),
}


def box20(style: str, label: str) -> list[str]:
    tl, h, tm, tr, ml, mm, mr, bl, bm, br, v = BOX_STYLES[style]
    inner = [
        f" {label}",
        f" {tl}{h * 4}{tm}{h * 4}{tr}",
        f" {ml}{h * 4}{mm}{h * 4}{mr}",
        f" {bl}{h * 4}{bm}{h * 4}{br}",
    ]
    out = [tl + h * 18 + tr]
    out += [v + pad_display(s, 18) + v for s in inner]
    out.append(bl + h * 18 + br)
    return out


def frame_05_box() -> str:
    f = Frame()
    f.title("05  Box drawing: light / heavy / double / mixed + DEC Special Graphics")
    f.at(2, 1, "Unicode U+2500 block:", (2,))

    for idx, style in enumerate(("light", "heavy", "double", "mixed")):
        col = 1 + idx * 22
        for i, line in enumerate(box20(style, style.upper())):
            f.at(3 + i, col, line)

    f.at(10, 1, "junctions / lines:", (1,))
    f.at(11, 1, "LIGHT : ┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘ ─ │", (2,))
    f.at(12, 1, "HEAVY : ┏ ┳ ┓ ┣ ╋ ┫ ┗ ┻ ┛ ━ ┃", (2,))
    f.at(13, 1, "DOUBLE: ╔ ╦ ╗ ╠ ╬ ╣ ╚ ╩ ╝ ═ ║", (2,))
    f.at(14, 1, "MIXED : ╒ ╤ ╕ ╞ ╪ ╡ ╘ ╧ ╛ ╓ ╥ ╖ ╟ ╫ ╢ ╙ ╨ ╜", (2,))
    f.at(15, 1, "ROUNDED / DIAGONAL: ╭ ╮ ╯ ╰ ╱ ╲ ╳", (2,))
    f.at(16, 1, "DASHED: ┄ ┅ ┆ ┇ ┈ ┉ ┊ ┋ ╌ ╍ ╎ ╏", (2,))

    # DEC Special Graphics, designated as G0 with ESC ( 0.
    f.raw(cup(18, 1) + E + "(0")
    dec_rows = [
        "l" + "q" * 11 + "k",
        "x" + " " * 11 + "x",
        "x" + " " * 11 + "x",
        "x" + " " * 11 + "x",
        "m" + "q" * 11 + "j",
    ]
    for i, line in enumerate(dec_rows):
        f.raw(cup(18 + i, 1) + line)
    f.raw(E + "(B")
    f.at(19, 16, "ESC(0 box", (2,))
    f.at(20, 16, "ESC(B ASCII", (2,))

    # G1 + SO/SI variant of the same charset.
    f.raw(cup(18, 40) + E + ")0" + "\x0e")
    for i, line in enumerate(dec_rows):
        f.raw(cup(18 + i, 40) + line)
    f.raw("\x0f" + E + ")B")
    f.at(19, 55, "same, G1 + SO/SI", (2,))

    f.at(24, 1, "G0 map: ", (2,))
    f.raw(E + "(0" + "jklmnqtuvwxafg~yz{|}" + E + "(B")
    f.raw("  = ┘┐┌└┼─├┤┴┬│▒°±·≤≥π≠£")
    f.at(25, 1, "raw letters j k l m n q t u v w x a f g ~ y z { | }", (2,))

    f.at(27, 1, "Box-drawing cells must share exact edges across rows and columns.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 06 - block elements and shades
# --------------------------------------------------------------------------


def frame_06_blocks() -> str:
    f = Frame()
    f.title("06  Block elements: halves, eighths, quadrants, shades")
    f.at(3, 1, "lower blocks:", (2,))
    f.at(3, 16, "▁▂▃▄▅▆▇█")
    f.at(3, 30, "left blocks:", (2,))
    f.at(3, 45, "▏▎▍▌▋▊▉█")
    f.at(3, 60, "right:", (2,))
    f.at(3, 69, "▐▕")
    f.at(4, 1, "upper / full:", (2,))
    f.at(4, 16, "▀▄█")
    f.at(4, 30, "shades:", (2,))
    f.at(4, 45, "░▒▓█")

    f.at(6, 1, "quadrants:", (2,))
    f.at(6, 14, "▘▝▖▗▚▞▙▛▜▟█")

    f.at(8, 1, "dense mosaic blocks (row-to-row edges must tile):", (1,))
    patterns = [
        "▛▜▙▟▛▜▙▟▛▜▙▟▛▜▙▟▛▜▙▟",
        "▚▞▚▞▚▞▚▞▚▞▚▞▚▞▚▞▚▞▚▞",
        "▘▝▖▗▘▝▖▗▘▝▖▗▘▝▖▗▘▝▖▗",
        "█▀▄█▀▄█▀▄█▀▄█▀▄█▀▄█▀▄",
        "▛▀▜▙▄▟▛▀▜▙▄▟▛▀▜▙▄▟▛▀▜",
    ]
    for i, pat in enumerate(patterns):
        f.at(9 + i, 1, pat)
    f.at(14, 1, "quadrant + half-block checker:", (2,))
    f.at(14, 35, "▚▞▚▞▚▞▚▞▚▞▚▞▚▞▚▞▚▞▚▞")

    f.at(16, 1, "colour: fg block over bg block (sprite blend path):", (1,))
    f.at(17, 1, "", (fgrgb(255, 80, 40), bgrgb(20, 40, 160)))
    f.raw("▀" * 30 + RESET)
    f.at(17, 32, "", (fgrgb(40, 220, 120), bgrgb(90, 0, 120)))
    f.raw("▄" * 30 + RESET)
    f.at(17, 64, "", (fgrgb(255, 255, 255), bgrgb(0, 0, 0)))
    f.raw("▌▐▀▄" + RESET)

    f.at(19, 1, "quadrant blends:", (1,))
    for i in range(10):
        f.at(20, 1 + i * 4, "▛", (fgrgb(255, 200 - i * 15, 0), bgrgb(0, 20 + i * 10, 255)))
    f.at(21, 1, "shade ramp (fg over bg):", (2,))
    for i in range(20):
        f.at(21, 30 + i * 3, "░▒▓", (fgrgb(230, 230, 230), bgrgb(10 * i, 0, 0)))

    f.at(23, 1, "per-column shade density ramp (100 cells):", (1,))
    ramp = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    for c in range(COLS):
        f.raw(cup(24, 1 + c) + ramp[(c * len(ramp)) // COLS])
    f.at(26, 1, "per-column block+density mix:", (1,))
    mix = [" ", "░", "▁", "▒", "▂", "▚", "▓", "▄", "▙", "█"]
    for c in range(COLS):
        f.raw(cup(27, 1 + c) + mix[(c * len(mix)) // COLS])
    f.at(29, 1, "Blocks must be exactly one cell wide with no gap or bleed.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 07 - braille
# --------------------------------------------------------------------------


def braille(mask: int) -> str:
    """Braille pattern from an 8-bit dot mask (dot1=0x01 ... dot8=0x80)."""
    return chr(0x2800 | (mask & 0xFF))


def braille_bitmap(cols: int, rows: int, fn) -> list[str]:
    """Render a char grid; fn(x, y) tests a 2x4-dot subcell (x,y in dots)."""
    out = []
    for cy in range(rows):
        line = []
        for cx in range(cols):
            mask = 0
            # Dot layout inside a braille cell:
            #   1 4
            #   2 5
            #   3 6
            #   7 8
            bit_for = {(0, 0): 1, (0, 1): 2, (0, 2): 4, (1, 0): 8,
                       (1, 1): 16, (1, 2): 32, (0, 3): 64, (1, 3): 128}
            for (dx, dy), bit in bit_for.items():
                x = cx * 2 + dx
                y = cy * 4 + dy
                if fn(x, y):
                    mask |= bit
            line.append(braille(mask))
        out.append("".join(line))
    return out


def frame_07_braille() -> str:
    f = Frame()
    f.title("07  Braille U+2800 block: dot patterns, dense fields, raster art")
    f.at(3, 1, "single dots:", (2,))
    f.at(3, 15, "".join(braille(1 << i) for i in range(8)))
    f.at(3, 25, "blank:" , (2,))
    f.at(3, 33, braille(0))
    f.at(3, 36, "full:", (2,))
    f.at(3, 43, braille(0xFF))

    f.at(4, 1, "masks 0-31:", (2,))
    f.at(4, 15, "".join(braille(m) for m in range(0, 32)))

    f.at(5, 1, "masks 32-63:", (2,))
    f.at(5, 15, "".join(braille(m) for m in range(32, 64)))

    f.at(6, 1, "dense field, 40 x 4 cells of U+28FF:", (1,))
    for r in range(4):
        f.at(7 + r, 1, "⣿" * 40)

    f.at(12, 1, "diagonal raster (40 x 8 dots):", (1,))
    diag = braille_bitmap(40, 2, lambda x, y: x == y)
    for i, line in enumerate(diag):
        f.at(13 + i, 1, line)

    f.at(16, 1, "checkerboard raster (40 x 8 dots):", (1,))
    checker = braille_bitmap(40, 2, lambda x, y: (x + y) % 2 == 0)
    for i, line in enumerate(checker):
        f.at(17 + i, 1, line)

    f.at(20, 1, "ring raster (40 x 8 dots):", (1,))
    ring = braille_bitmap(40, 2, lambda x, y: 28 <= (x - 20) ** 2 + (y - 4) ** 2 <= 60)
    for i, line in enumerate(ring):
        f.at(21 + i, 1, line)

    f.at(24, 1, "colour + background over braille:", (1,))
    f.at(24, 40, "⣿⣿⣿⣿", (fgrgb(255, 255, 0), bgrgb(0, 60, 120)))
    f.at(24, 48, "⣀⣤⣶⣿", (fgrgb(0, 255, 200), bgrgb(80, 0, 40)))

    f.at(26, 1, "100-cell pattern cycle (masks 0,1,3,7,15,31,63,127,255):", (2,))
    cycle = [0, 1, 3, 7, 15, 31, 63, 127, 255]
    f.at(27, 1, "".join(braille(cycle[c % len(cycle)]) for c in range(COLS)))
    f.at(29, 1, "Braille dots must align to the same 2x4 sub-cell grid in every cell.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 08 - legacy computing
# --------------------------------------------------------------------------


def frame_08_legacy() -> str:
    f = Frame()
    f.title("08  Legacy computing: sextants, mosaics, octants, segmented digits")
    f.at(3, 1, "U+1FB00-1FB3B sextants 1-60:", (2,))
    f.at(3, 36, "".join(chr(c) for c in range(0x1FB00, 0x1FB1E)))
    f.at(4, 36, "".join(chr(c) for c in range(0x1FB1E, 0x1FB3C)))

    f.at(6, 1, "U+1FB3C-1FB67 block diagonals:", (2,))
    f.at(6, 40, "".join(chr(c) for c in range(0x1FB3C, 0x1FB52)))
    f.at(7, 1, "U+1FB52-1FB67 diagonals:", (2,))
    f.at(7, 40, "".join(chr(c) for c in range(0x1FB52, 0x1FB68)))

    f.at(9, 1, "U+1FB68-1FB6F triangular blocks:", (2,))
    f.at(9, 40, "".join(chr(c) for c in range(0x1FB68, 0x1FB70)))

    f.at(10, 1, "U+1FB70-1FB81 eighth blocks:", (2,))
    f.at(10, 40, "".join(chr(c) for c in range(0x1FB70, 0x1FB82)))

    f.at(11, 1, "U+1FB82-1FB8B quarter/eighth blocks:", (2,))
    f.at(11, 40, "".join(chr(c) for c in range(0x1FB82, 0x1FB8C)))

    f.at(12, 1, "U+1FB8C-1FB90 medium-shade mosaics:", (2,))
    f.at(12, 40, "".join(chr(c) for c in range(0x1FB8C, 0x1FB91)))

    f.at(13, 1, "U+1FB91-1FB9F shades:", (2,))
    f.at(13, 40, "".join(chr(c) for c in range(0x1FB91, 0x1FBA0)))

    f.at(15, 1, "U+1FBA0-1FBAF box diagonals:", (2,))
    f.at(15, 40, "".join(chr(c) for c in range(0x1FBA0, 0x1FBB0)))

    f.at(16, 1, "U+1FBB0-1FBCF misc symbols:", (2,))
    f.at(16, 40, "".join(chr(c) for c in range(0x1FBB0, 0x1FBC0)))
    f.at(17, 40, "".join(chr(c) for c in range(0x1FBC0, 0x1FBD0)))

    f.at(19, 1, "U+1FBD0-1FBDF box diagonals:", (2,))
    f.at(19, 40, "".join(chr(c) for c in range(0x1FBD0, 0x1FBE0)))

    f.at(20, 1, "U+1FBE0-1FBEF circle quarters:", (2,))
    f.at(20, 40, "".join(chr(c) for c in range(0x1FBE0, 0x1FBF0)))

    f.at(21, 1, "U+1FBF0-1FBF9 segmented digits:", (2,))
    f.at(21, 40, "".join(chr(c) for c in range(0x1FBF0, 0x1FBFA)))
    f.at(21, 52, "ASCII 0123456789")

    f.at(23, 1, "Unicode 16 octants live at U+1CD00 (Supplement), not U+1FB00:", (2,))
    f.at(23, 66, "sample 40")
    f.at(24, 1, "".join(chr(c) for c in range(0x1CD00, 0x1CD28)))
    f.at(25, 1, "".join(chr(c) for c in range(0x1CD28, 0x1CD50)))

    f.at(27, 1, "dense sextant field:", (2,))
    f.at(27, 30, chr(0x1FB3B) * 50)
    f.at(28, 1, "shade mosaic ramp:", (2,))
    f.at(28, 30, "".join(chr(c) for c in range(0x1FB8C, 0x1FB90)) * 10)
    f.at(29, 1, "Requires a face covering U+1FB00.. and U+1CD00..; tofu must at least be identical.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 09 - powerline + nerd font PUA
# --------------------------------------------------------------------------


def frame_09_powerline() -> str:
    f = Frame()
    f.title("09  Powerline + Nerd Font private-use glyphs")
    f.at(2, 1, "statusline transitions (fg = previous bg, bg = next bg):", (2,))

    f.raw(cup(3, 1) + sgr("48;5;24;38;5;231") + " user@kmshaunt ")
    f.raw(sgr("48;5;22;38;5;24") + "\ue0b0")
    f.raw(sgr("48;5;22;38;5;231") + " ~/Projects/kmshaunt2 ")
    f.raw(sgr("48;5;130;38;5;22") + "\ue0b0")
    f.raw(sgr("48;5;130;38;5;231") + " main ")
    f.raw(sgr("0;38;5;130") + "\ue0b0")
    f.raw(RESET)

    f.at(5, 1, "separators E0B0-E0B7:", (2,))
    f.at(5, 28, "".join(chr(c) for c in range(0xE0B0, 0xE0B8)), (fgrgb(0, 220, 120), bgrgb(20, 20, 30)))

    f.at(6, 1, "branch/lock extras E0A0-E0A2:", (2,))
    f.at(6, 38, "".join(chr(c) for c in range(0xE0A0, 0xE0A3)))
    f.at(6, 52, "\ue0a0 branch  \ue0a2 lock")

    f.at(8, 1, "Nerd Font icons (PUA; font-specific):", (1,))
    icons = [
        (0xF07B, "folder"), (0xF07C, "folder-open"), (0xF15B, "file"),
        (0xF121, "code"), (0xF120, "terminal"), (0xF1D3, "git"),
        (0xF09B, "github"), (0xF013, "cog"), (0xF015, "home"),
        (0xF017, "clock"), (0xF0F3, "bell"), (0xF00C, "check"),
        (0xF00D, "times"), (0xF0E7, "bolt"), (0xF004, "heart"),
        (0xF005, "star"), (0xF0C2, "cloud"), (0xF1C0, "database"),
        (0xF023, "lock"), (0xF007, "user"), (0xF002, "search"),
        (0xF0AD, "wrench"), (0xF0C9, "bars"), (0xF0D0, "magic"),
        (0xE718, "dev-git"), (0xE795, "dev-term"), (0xF8FF, "apple"),
        (0xF2DB, "microchip"), (0xF1C9, "tree"), (0xF0E8, "sitemap"),
    ]
    for i, (cp, name) in enumerate(icons):
        row = 9 + i // 6
        col = 1 + (i % 6) * 16
        f.at(row, col, f"{chr(cp)} {name}")

    f.at(15, 1, "filling separators must tile into a continuous edge:", (1,))
    f.at(16, 1, "\ue0b0" * 20, (fgrgb(255, 100, 0), bgrgb(0, 80, 160)))
    f.at(17, 1, "\ue0b1" * 20, (fgrgb(0, 255, 200), bgrgb(60, 0, 120)))
    f.at(18, 1, "\ue0b2" * 20, (fgrgb(255, 255, 255), bgrgb(0, 0, 0)))

    f.at(20, 1, "truecolor statusline:", (1,))
    f.raw(cup(21, 1) + sgr(bgrgb(30, 40, 90), fgrgb(230, 240, 255)) + "  workspace  ")
    f.raw(sgr(bgrgb(30, 120, 90), fgrgb(30, 40, 90)) + "\ue0b0")
    f.raw(sgr(bgrgb(30, 120, 90), fgrgb(230, 255, 240)) + "  byte-exact  ")
    f.raw(sgr(bgrgb(140, 90, 30), fgrgb(30, 120, 90)) + "\ue0b0")
    f.raw(sgr(bgrgb(140, 90, 30), fgrgb(255, 240, 220)) + "  diff=0  ")
    f.raw(sgr(0, fgrgb(140, 90, 30)) + "\ue0b0")
    f.raw(RESET)

    f.at(23, 1, "font-specific PUA codepoints must still have identical advance/placement.", (2,))
    f.at(25, 1, "overlap risk: U+E0B0 is often double-drawn at cell boundaries; edges must match.", (2,))
    f.at(27, 1, "required: Nerd Font patched monospace face (e.g. JetBrainsMono Nerd Font).", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 10 - programming ligatures
# --------------------------------------------------------------------------


def frame_10_ligatures() -> str:
    f = Frame()
    f.title("10  Programming ligatures (calt/liga enabled in both terminals)")
    samples = [
        (3, "fi fl ffi ffl"),
        (4, "-> <- => <= >= <-> <=>"),
        (5, "== === != !== =/= !==="),
        (6, ":: ::= := =: ++ -- +/- ** ***"),
        (7, "|> <| >>= <<= <$> <*> <&> <>"),
        (8, "&& || ~~ !! ?? ?. ?? !!"),
        (9, "// /* */ #! ## ###"),
        (10, ".. ... ..= .- -. |> <|"),
        (11, "0x1F 0b1010 1_000_000 1.5e-9"),
        (12, "www aws fj ff ffl ffi"),
        (13, "const x = foo(bar) orelse return;"),
    ]
    for row, text in samples:
        f.at(row, 1, f"{row - 2:02d}:", (2,))
        f.at(row, 8, text)

    f.at(15, 1, "underline reveals cell advance (must stay monospace):", (1,))
    f.at(16, 1, "-> => === != <=> <*> |>", (4,))
    f.at(16, 30, "f i  vs  fi", (2,))
    f.at(18, 1, "ligature boundaries must not fire across spaces:", (1,))
    f.at(19, 1, "f i fl ffi < > = =", (2,))
    f.at(21, 1, "code context:", (1,))
    f.at(22, 1, "if (a != b and c <= d) return a->b;", (36,))
    f.at(23, 1, "fn render(self: *Frame) !void { try self.flush(); }", (33,))
    f.at(25, 1, "HarfBuzz may shape these into one glyph; cell advances must not change.", (2,))
    f.at(27, 1, "required font features: liga + calt; families: JetBrains Mono, Fira Code, Cascadia Code.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 11 - combining marks
# --------------------------------------------------------------------------


def frame_11_combining() -> str:
    f = Frame()
    f.title("11  Combining diacritics and stacked grapheme clusters")
    f.at(2, 1, ruler(), (2,))

    f.at(4, 1, "single combining marks over a base:", (1,))
    f.at(4, 45, "a\u0301 e\u0308 i\u0302 o\u0303 u\u030a c\u0327 n\u0303 s\u030c z\u0327 y\u0301")

    f.at(6, 1, "stacked marks:", (1,))
    f.at(6, 20, "x\u0301\u0327\u0308  a\u0308\u0301  e\u0327\u0302\u0304  o\u0301\u0308\u0303")

    f.at(8, 1, "marks over precomposed bases:", (1,))
    f.at(8, 32, "\u00e9\u0308  \u00f1\u0301  \u00fc\u0304")

    f.at(10, 1, "cell-advance check: the bar must land in the same column on every row:", (1,))
    checks = [
        (11, "a\u0301|"),
        (12, "e\u0308|"),
        (13, "x\u0301\u0327|"),
        (14, "n\u0303|"),
        (15, "s\u030c|"),
    ]
    for row, s in checks:
        f.at(row, 10, s, (2,))
        f.at(row, 14, "<- one base cell", (2,))

    f.at(17, 1, "wide base + combining mark:", (2,))
    f.at(17, 30, "中\u0301|")
    f.at(17, 40, "combining enclosing circle:", (2,))
    f.at(17, 68, "a\u20dd  o\u20dd")

    f.at(19, 1, "sampler U+0300..U+030F over 'o':", (2,))
    f.at(19, 36, "".join("o" + chr(0x300 + i) + " " for i in range(16)))

    f.at(21, 1, "colour of a combining mark follows the base:", (1,))
    f.at(21, 50, "a\u0301", (fgrgb(255, 80, 0),))
    f.at(21, 56, "e\u0308", (fgrgb(0, 200, 255),))
    f.at(21, 62, "x\u0327\u0301", (fgrgb(180, 80, 255),))

    f.at(23, 1, "underlined cluster:", (2,))
    f.at(23, 40, "e\u0301", (4,))

    f.at(25, 1, "mark-only run after a space:", (2,))
    f.at(25, 40, " \u0301 \u0308 X")

    f.at(27, 1, "Rendering difficulty: marks may be drawn outside the cell; clipping/atlas bounds differ.", (2,))
    f.at(28, 1, ruler(), (2,))
    return f.build()


# --------------------------------------------------------------------------
# 12 - NFC vs NFD
# --------------------------------------------------------------------------


def frame_12_nfc_nfd() -> str:
    f = Frame()
    f.title("12  NFC vs NFD canonical equivalence")
    f.at(2, 1, ruler(), (2,))
    f.at(3, 1, "label", (2,))
    f.at(3, 22, "NFC", (2,))
    f.at(3, 33, "NFD", (2,))
    f.at(3, 54, "fixed marker", (2,))

    pairs = [
        ("e acute", "\u00e9", "e\u0301"),
        ("n tilde", "\u00f1", "n\u0303"),
        ("u diaeresis", "\u00fc", "u\u0308"),
        ("A ring", "\u00c5", "A\u030a"),
        ("c cedilla", "\u00e7", "c\u0327"),
        ("o double acute", "\u0151", "o\u030b"),
        ("u diaeresis acute", "\u01d8", "u\u0308\u0301"),
        ("e macron acute", "\u1e17", "e\u0304\u0301"),
        ("alpha tonos", "\u03ac", "\u03b1\u0301"),
        ("iota dialytika tonos", "\u0390", "\u03b9\u0308\u0301"),
        ("Cyrillic short i", "\u0439", "\u0438\u0306"),
        ("e circumflex acute", "\u1ebf", "e\u0302\u0301"),
    ]
    for i, (label, nfc, nfd) in enumerate(pairs):
        row = 4 + i
        f.at(row, 1, label, (2,))
        f.at(row, 22, "NFC", (2,))
        f.at(row, 26, nfc)
        f.at(row, 28, "|", (2,))
        f.at(row, 33, "NFD", (2,))
        f.raw(cup(row, 37))
        f.raw(nfd)
        f.raw("|")
        f.at(row, 54, "MARK", (2,))

    f.at(17, 1, "NFC flow:", (1,))
    f.at(17, 12, "\u00e9\u00f1\u00fc\u00c5\u00e7\u0151\u01d8\u1e17\u03ac\u0390\u0439\u1ebf")
    f.at(18, 1, "NFD flow:", (1,))
    f.at(18, 12, "e\u0301n\u0303u\u0308A\u030ac\u0327o\u030bu\u0308\u0301e\u0304\u0301\u03b1\u0301\u03b9\u0308\u0301\u0438\u0306e\u0302\u0301")
    f.at(19, 12, "| end marker should align exactly above", (2,))

    f.at(21, 1, "Hangul syllable vs jamo:", (2,))
    f.at(21, 40, "\uac00")
    f.at(21, 48, "(canonical pair; glyph width may differ by font)", (2,))
    f.at(22, 1, "jamo:", (2,))
    f.at(22, 10, "\u1100\u1161")

    f.at(24, 1, "U+00E9 and e+U+0301 must produce identical pixels and one cell of advance.", (2,))
    f.at(26, 1, "Rendering difficulty: composition may happen in the shaper or the font; both paths must agree.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 13 - CJK wide
# --------------------------------------------------------------------------


def cjk_table() -> list[str]:
    w1, w2, w3 = 14, 8, 7
    top = "┌" + "─" * w1 + "┬" + "─" * w2 + "┬" + "─" * w3 + "┐"
    mid = "├" + "─" * w1 + "┼" + "─" * w2 + "┼" + "─" * w3 + "┤"
    bot = "└" + "─" * w1 + "┴" + "─" * w2 + "┴" + "─" * w3 + "┘"

    def row(a, b, c):
        return "│" + pad_display(a, w1) + "│" + pad_display(b, w2) + "│" + pad_display(c, w3) + "│"

    return [
        top,
        row("名前", "サイズ", "mode"),
        mid,
        row("ドキュメント", "12 KiB", "0644"),
        row("写真.png", "2 MiB", "0644"),
        row("文字化け.txt", "4 KiB", "0600"),
        bot,
    ]


def frame_13_cjk() -> str:
    f = Frame()
    f.title("13  Wide/fullwidth CJK mixed with ASCII")
    f.at(2, 1, ruler(), (2,))

    f.at(3, 1, "Chinese:", (2,))
    f.at(3, 14, "你好世界 中文终端测试 汉字宽字符对齐")
    f.at(4, 1, "Chinese:", (2,))
    f.at(4, 14, "这是一个很长的中文句子，用于测试换行与对齐。")

    f.at(6, 1, "Japanese:", (2,))
    f.at(6, 14, "こんにちは世界 カタカナテスト 日本語のテキスト")
    f.at(7, 1, "Japanese:", (2,))
    f.at(7, 14, "漢字とひらがな交じり文です。")

    f.at(9, 1, "Korean:", (2,))
    f.at(9, 14, "안녕하세요 한글 테스트 한국어 터미널")

    f.at(11, 1, "fullwidth:", (2,))
    f.at(11, 14, "ＡＢＣ１２３ ，。！？「」")

    f.at(13, 1, "mixed natural flow (wide chars are 2 cells):", (1,))
    f.at(13, 48, "A中B文C字D")
    f.at(13, 62, "| expected bar")
    f.at(14, 1, "wide-cell grid:", (2,))
    f.at(14, 30, "中|文|字|語|")
    f.at(15, 1, "ASCII/CJK table (border alignment requires width 2):", (2,))
    for i, line in enumerate(cjk_table()):
        f.at(16 + i, 1, line)

    f.at(23, 1, "ambiguous-width characters (width is terminal/unicode-width policy):", (2,))
    for i, ch in enumerate(["α", "β", "γ", "※", "±", "×", "÷"]):
        f.at(24, 1 + i * 6, ch)

    f.at(26, 1, "double-width background cells:", (2,))
    f.at(26, 34, "中文", (30, 47))
    f.at(26, 44, "ASCII", (30, 47))
    f.at(27, 1, "fullwidth emoji-adjacent:", (2,))
    f.at(27, 30, "Ａ😀Ｂ")
    f.at(29, 1, "Every wide glyph must occupy exactly two cells and never split across the right edge.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 14 - emoji
# --------------------------------------------------------------------------


def emoji_row(f: Frame, row: int, items: list[str], step: int, start: int = 1) -> None:
    for i, item in enumerate(items):
        f.at(row, start + i * step, item)


def frame_14_emoji() -> str:
    f = Frame()
    f.title("14  Emoji: single, VS16, skin tones, ZWJ, flags, keycaps (all colour-font formats)")
    f.at(2, 1, "single-codepoint (placed at fixed columns to tolerate width differences):", (2,))
    emoji_row(f, 3, ["😀", "😁", "😂", "🤣", "😃", "😄", "😅", "😆", "😉", "😊", "🙂", "🙃"], 7)
    emoji_row(f, 4, ["🐱", "🍎", "🌍", "🚀", "⚡", "🔥", "🌈", "🌙", "☕", "🎯", "💡", "🧪"], 7)

    f.at(6, 1, "VS16 presentation:", (2,))
    emoji_row(f, 7, ["❤️", "☀️", "☺️", "✈️", "⚠️", "⭐", "🌀", "♻️"], 9)

    f.at(9, 1, "skin-tone modifiers:", (2,))
    emoji_row(f, 10, ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿", "👋🏽", "🧑🏿", "🤝🏿"], 9)

    f.at(12, 1, "ZWJ families and professions:", (2,))
    emoji_row(f, 13, ["👨\u200d👩\u200d👧\u200d👦", "👩🏽\u200d👩🏾\u200d👧🏿", "👨\u200d👨\u200d👧", "👩\u200d👩\u200d👦"], 15)
    emoji_row(f, 14, ["👨\u200d⚕️", "👩\u200d⚕️", "👨🏽\u200d🚀", "👩🏿\u200d🎤", "🧑\u200d⚕️"], 15)

    f.at(16, 1, "flags: regional-indicator pairs + tag sequences:", (2,))
    emoji_row(f, 17, ["🇺🇸", "🇯🇵", "🇪🇸", "🇩🇪", "🇫🇷", "🇧🇷", "🇺🇳"], 10)
    f.at(18, 1, "tag flag (Scotland):", (2,))
    f.at(18, 24, "\U0001F3F4\U000E0067\U000E0062\U000E0073\U000E0063\U000E0074\U000E007F")
    f.at(18, 40, "England:", (2,))
    f.at(18, 50, "\U0001F3F4\U000E0067\U000E0062\U000E0065\U000E006E\U000E0067\U000E007F")

    f.at(20, 1, "keycaps:", (2,))
    emoji_row(f, 21, ["0\ufe0f\u20e3", "1\ufe0f\u20e3", "2\ufe0f\u20e3", "#\ufe0f\u20e3", "*\ufe0f\u20e3"], 8)

    f.at(23, 1, "natural-flow alignment:", (1,))
    f.at(23, 52, "A😀B|A❤️B|A👍🏽B|A🇺🇸B|")
    f.at(23, 90, "END")

    f.at(25, 1, "emoji over explicit backgrounds:", (2,))
    f.at(25, 40, "😀", (0, bgrgb(180, 0, 0)))
    f.at(25, 48, "🚀", (0, bgrgb(0, 120, 0)))
    f.at(25, 56, "🍎", (0, bgrgb(0, 0, 180)))
    f.at(25, 64, "👨\u200d👩\u200d👧\u200d👦", (0, bgrgb(90, 0, 90)))

    f.at(27, 1, "Color-font formats are not selectable via escapes; the configured emoji face decides.", (2,))
    f.at(28, 1, "Noto Color Emoji is CBDT; other faces may exercise sbix / COLRv0 / COLRv1 for the same text.", (2,))
    f.at(29, 1, "Sequences must render as one grapheme (2 cells) or consistently as separate cells in both.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 15 - variation selectors
# --------------------------------------------------------------------------


def frame_15_vs() -> str:
    f = Frame()
    f.title("15  Variation selectors: text vs emoji presentation")
    f.at(2, 1, ruler(), (2,))
    f.at(3, 1, "label", (2,))
    f.at(3, 22, "base+FE0E (text)", (2,))
    f.at(3, 44, "base+FE0F (emoji)", (2,))
    f.at(3, 68, "expected cell width", (2,))

    pairs = [
        ("heart U+2764", "\u2764\ufe0e", "\u2764\ufe0f"),
        ("sun U+2600", "\u2600\ufe0e", "\u2600\ufe0f"),
        ("smile U+263A", "\u263a\ufe0e", "\u263a\ufe0f"),
        ("plane U+2708", "\u2708\ufe0e", "\u2708\ufe0f"),
        ("envelope U+2709", "\u2709\ufe0e", "\u2709\ufe0f"),
        ("warning U+26A0", "\u26a0\ufe0e", "\u26a0\ufe0f"),
        ("check U+2714", "\u2714\ufe0e", "\u2714\ufe0f"),
        ("cross U+2716", "\u2716\ufe0e", "\u2716\ufe0f"),
        ("copyright U+00A9", "\u00a9\ufe0e", "\u00a9\ufe0f"),
        ("registered U+00AE", "\u00ae\ufe0e", "\u00ae\ufe0f"),
        ("trademark U+2122", "\u2122\ufe0e", "\u2122\ufe0f"),
        ("double bang U+203C", "\u203c\ufe0e", "\u203c\ufe0f"),
        ("interrobang U+2049", "\u2049\ufe0e", "\u2049\ufe0f"),
        ("arrows U+2194", "\u2194\ufe0e", "\u2194\ufe0f"),
    ]
    for i, (label, text, emoji) in enumerate(pairs):
        row = 4 + i
        f.at(row, 1, label, (2,))
        f.at(row, 22, text)
        f.at(row, 44, emoji)
        f.at(row, 64, "text / emoji presentation", (2,))

    f.at(19, 1, "digits:", (1,))
    f.at(19, 16, "no VS: 1", (2,))
    f.at(19, 30, "FE0E: 1\ufe0e", (2,))
    f.at(19, 44, "FE0F: 1\ufe0f", (2,))
    f.at(19, 58, "keycap: 1\ufe0f\u20e3", (2,))

    f.at(21, 1, "unsupported VS on ASCII:", (2,))
    f.at(21, 34, "A\ufe0eB")
    f.at(21, 44, "A\ufe0fB")
    f.at(21, 54, "AB", (2,))
    f.at(21, 60, "must all be identical", (2,))

    f.at(23, 1, "flow: all text forms:", (1,))
    f.at(23, 24, "".join(p[1] for p in pairs))
    f.at(24, 1, "flow: all emoji forms:", (1,))
    f.at(24, 24, "".join(p[2] for p in pairs))
    f.at(24, 80, "|", (2,))

    f.at(26, 1, "text presentation must be monochrome; emoji presentation may be a colour glyph.", (2,))
    f.at(28, 1, "Required: a face with both monochrome and colour coverage (Noto Emoji + Noto Color Emoji).", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 16 - bidi / RTL
# --------------------------------------------------------------------------


def frame_16_bidi() -> str:
    f = Frame()
    f.title("16  RTL and bidi: Arabic + Hebrew contextual shaping")
    f.at(2, 1, "Arabic:", (1,))
    f.at(3, 1, "phrase", (2,))
    f.at(3, 26, "مرحبا بالعالم")
    f.at(4, 1, "greeting", (2,))
    f.at(4, 26, "السلام عليكم")
    f.at(5, 1, "tawhid", (2,))
    f.at(5, 26, "لا إله إلا الله")
    f.at(6, 1, "diacritics", (2,))
    f.at(6, 26, "مُحَمَّد")
    f.at(7, 1, "arabic-indic digits", (2,))
    f.at(7, 26, "العربية ١٢٣٤٥٦٧٨٩")

    f.at(9, 1, "mixed LTR/RTL:", (1,))
    f.at(10, 20, "Hello مرحبا World 42")
    f.at(11, 20, "kmshaunt يدعم Wayland")

    f.at(13, 1, "Hebrew:", (1,))
    f.at(14, 1, "phrase", (2,))
    f.at(14, 14, "שלום עולם")
    f.at(15, 1, "niqqud", (2,))
    f.at(15, 14, "שָׁלוֹם")
    f.at(16, 1, "mixed", (2,))
    f.at(16, 14, "abc שלום def 123")

    f.at(18, 1, "bidi controls (if implemented):", (1,))
    f.at(19, 1, "RLO", (2,))
    f.at(19, 14, "abc \u202eDEF\u202c ghi")
    f.at(20, 1, "RLE/PDF", (2,))
    f.at(20, 14, "\u202bאבג 123\u202c")
    f.at(21, 1, "RLI/PDI", (2,))
    f.at(21, 14, "a \u2067אבג\u2069 b")

    f.at(23, 1, "punctuation and brackets:", (1,))
    f.at(23, 30, "(مرحبا) [שלום] «مرحبا»")
    f.at(24, 1, "Persian/Urdu:", (1,))
    f.at(24, 20, "سلام دنیا — اردو زبان")

    f.at(26, 1, "Rendering difficulty: glyph order, joining, mark positioning, and bracket mirroring.", (2,))
    f.at(27, 1, "If bidi is not implemented, the byte order must at least render deterministically.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 17 - complex shaping
# --------------------------------------------------------------------------


def frame_17_shaping() -> str:
    f = Frame()
    f.title("17  Complex shaping (HarfBuzz): Indic, Thai, Arabic ligatures")
    rows = [
        (3, "Devanagari", "नमस्ते दुनिया"),
        (4, "conjunct", "क्षेत्र"),
        (5, "matras", "हिन्दी"),
        (6, "cluster", "संस्कृतम्"),
        (7, "ZWJ conjunct", "क्\u200dष"),
        (8, "Bengali", "বাংলা ভাষা"),
        (9, "Bengali", "নমস্কার"),
        (10, "Thai", "ภาษาไทย"),
        (11, "Thai", "สวัสดีชาวโลก"),
        (12, "Tamil", "தமிழ்"),
        (13, "Telugu", "తెలుగు"),
        (14, "Arabic ligature", "لا إله إلا الله"),
        (15, "Arabic ligature", "الله"),
        (16, "mixed", "नमस्ते, world!"),
        (17, "mixed", "ไทย + English + हिंदी"),
    ]
    for row, label, text in rows:
        f.at(row, 1, label + ":", (2,))
        f.at(row, 18, text)

    f.at(19, 1, "above/below marks (Thai tone + vowel):", (2,))
    f.at(19, 44, "กิ่  ก้  ก๊  ก๋  เก  แก")
    f.at(20, 1, "Devanagari above/below:", (2,))
    f.at(20, 44, "किं कुं कृ कॢ")

    f.at(22, 1, "coloured shaped clusters:", (1,))
    f.at(22, 40, "नमस्ते", (fgrgb(255, 160, 0),))
    f.at(22, 50, "বাংলা", (fgrgb(0, 220, 140),))
    f.at(22, 58, "ภาษาไทย", (fgrgb(80, 180, 255),))
    f.at(22, 68, "الله", (fgrgb(255, 80, 160),))

    f.at(24, 1, "underline shaped cluster:", (2,))
    f.at(24, 40, "क्षेत्र", (4,))

    f.at(26, 1, "Rendering difficulty: reordering, ligatures, mark positioning, and cluster cell count.", (2,))
    f.at(27, 1, "Required: Noto Sans Devanagari/Bengali/Thai/Tamil/Telugu/Arabic or equivalent coverage.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 18 - zero width / invisible
# --------------------------------------------------------------------------


def frame_18_zero_width() -> str:
    f = Frame()
    f.title("18  Zero-width and invisible characters")
    f.at(2, 1, ruler(), (2,))
    f.at(3, 1, "All visible text starts at column 16; the bar must land at the same column.", (2,))

    base = "ABCDEFGHIJ"
    f.at(4, 1, "baseline", (2,))
    f.at(4, 16, base + "|")

    variants = [
        (5, "ZWSP U+200B", "A\u200bB\u200bC\u200bD\u200bE\u200bF|"),
        (6, "ZWJ U+200D", "A\u200dB\u200dC\u200dD\u200dE|"),
        (7, "ZWNJ U+200C", "A\u200cB\u200cC\u200cD\u200cE|"),
        (8, "WJ U+2060", "A\u2060B\u2060C\u2060D\u2060E|"),
        (9, "SHY U+00AD", "hy\u00adphen|"),
        (10, "BOM U+FEFF", "\ufeffABCDE|"),
    ]
    for row, label, text in variants:
        f.at(row, 1, label, (2,))
        f.at(row, 16, text)

    f.at(12, 1, "mixed zero-width run:", (2,))
    f.at(12, 30, "A\u200b\u200c\u200d\u2060B|")

    f.at(14, 1, "ZWNJ/ZWJ change shaping without changing advance:", (1,))
    f.at(15, 1, "Persian ZWNJ", (2,))
    f.at(15, 16, "می\u200cخواهم")
    f.at(15, 36, "Persian joined", (2,))
    f.at(15, 53, "میخواهم")
    f.at(16, 1, "Devanagari ZWJ", (2,))
    f.at(16, 16, "क्\u200dष")
    f.at(16, 30, "ZWNJ", (2,))
    f.at(16, 37, "क्\u200cष")
    f.at(16, 50, "plain", (2,))
    f.at(16, 58, "क्ष")

    f.at(18, 1, "zero-width inside a combining cluster:", (2,))
    f.at(18, 46, "e\u0301\u200dX")
    f.at(18, 56, "e\u200b\u0301X")
    f.at(18, 66, "a\u2060\u0308Y")

    f.at(20, 1, "zero-width before/after emoji:", (2,))
    f.at(20, 40, "\u200d😀\u200d")
    f.at(20, 48, "😀\u200b❤️")

    f.at(22, 1, "soft hyphen:", (2,))
    f.at(22, 30, "hy\u00adphenation")

    f.at(24, 1, "cluster + ZWJ edge cases (must not add cells):", (2,))
    f.at(24, 50, "x\u200dy\u200dz")
    f.at(24, 60, "1\u200d2\u200d3")

    f.at(26, 1, "Rendering difficulty: some libraries give ZWSP/SHY a width; both must agree or be fixed.", (2,))
    f.at(27, 1, "Ruler above and below pinpoints any accidental advance introduced by an invisible code point.", (2,))
    f.at(29, 1, ruler(), (2,))
    return f.build()


# --------------------------------------------------------------------------
# 19-21 - cursor styles
# --------------------------------------------------------------------------


def cursor_frame(style: int, row: int, col: int, name: str, note: str) -> str:
    f = Frame()
    f.title(f"{name}  ·  cursor visible at row {row}, col {col}")
    f.at(2, 1, ruler(), (2,))
    f.at(3, 1, f"DECSCUSR style {style}; cell ({row},{col}); no writes after the final CUP.", (2,))
    f.at(4, 1, note, (2,))

    for r in range(6, 29, 4):
        for c in range(10, 91, 10):
            if (r, c) == (row, col):
                continue
            f.at(r, c, "+", (2,))

    f.at(29, 1, "Cursor must sit on exactly one cell (or one wide cell) with the requested shape.", (2,))
    body = f.build()
    ending = (
        csi("0m")
        + E
        + "(B"
        + "\x0f"
        + csi("?7h")
        + sgr(0)
        + csi(f"{style} q")
        + csi("?25h")
        + cup(row, col)
    )
    return body + ending


def frame_19_cursor_block() -> str:
    return cursor_frame(
        2,
        15,
        50,
        "19  Cursor: steady block",
        "Default-style block cursor over the terminal background.",
    )


def frame_20_cursor_beam_blink() -> str:
    return cursor_frame(
        5,
        10,
        25,
        "20  Cursor: blinking beam",
        "Blink is time-dependent; capture at a controlled phase or disable blinking.",
    )


def frame_21_cursor_underline() -> str:
    return cursor_frame(
        4,
        20,
        75,
        "21  Cursor: steady underline",
        "Underline cursor must not alter the cell's glyph rendering.",
    )


# --------------------------------------------------------------------------
# 22 - double width / double height lines
# --------------------------------------------------------------------------


def frame_22_double_lines() -> str:
    f = Frame()
    f.title("22  DECDWL / DECDHL line attributes")
    f.at(2, 1, ruler(), (2,))

    f.at(3, 1, "normal line before DECDWL (100 cells):", (2,))
    f.raw(cup(4, 1) + E + "#6")
    f.raw("DOUBLE WIDTH: abcdefghijklmnopqrstuvwxyz")
    f.raw(cup(5, 1) + E + "#5")
    f.at(5, 1, "single width restored: abcdefghijklmnopqrstuvwxyz 0123456789", (2,))

    f.at(7, 1, "DECDHL pair (top ESC#3, bottom ESC#4):", (2,))
    f.raw(cup(8, 1) + E + "#3" + "DOUBLE HEIGHT PAIR 0123456789 Hg")
    f.raw(cup(9, 1) + E + "#4" + "DOUBLE HEIGHT PAIR 0123456789 Hg")
    f.raw(cup(10, 1) + E + "#5")
    f.at(10, 1, "normal height restored", (2,))

    f.at(12, 1, "second DECDHL pair, coloured halves:", (2,))
    f.raw(cup(13, 1) + E + "#3" + sgr(1, 31) + "TOP HALF RED 0123456789" + RESET)
    f.raw(cup(14, 1) + E + "#4" + sgr(1, 34) + "TOP HALF RED 0123456789" + RESET)
    f.raw(cup(15, 1) + E + "#5")

    f.at(17, 1, "DECDWL with CJK (30 logical cells):", (2,))
    f.raw(cup(18, 1) + E + "#6")
    f.raw("中文宽字符双宽行测试ABCDEFGHIJ")
    f.raw(cup(19, 1) + E + "#5")
    f.at(19, 1, "single width CJK: 中文宽字符双宽行测试ABCDEFGHIJ", (2,))

    f.at(21, 1, "cursor column accounting after a DECDWL line:", (2,))
    f.raw(cup(21, 70) + "MARK70")
    f.at(22, 1, "CUP to column 70 must be identical to a normal line.", (2,))

    f.at(24, 1, "box glyphs on a DECDHL pair (vertical scaling test):", (2,))
    f.raw(cup(25, 1) + E + "#3" + "┌────┐ ▁▂▃▄▅▆▇█ 0123")
    f.raw(cup(26, 1) + E + "#4" + "┌────┐ ▁▂▃▄▅▆▇█ 0123")
    f.raw(cup(27, 1) + E + "#5")

    f.at(29, 1, "ESC#3 top / ESC#4 bottom / ESC#5 single / ESC#6 double width.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 23 - positioning and wrap
# --------------------------------------------------------------------------


def frame_23_positioning() -> str:
    f = Frame()
    f.title("23  Positioning, tabs, save/restore, autowrap")
    f.at(2, 1, ruler(), (2,))
    f.at(3, 1, "CUP diagonal (C) vs HVP diagonal (H):", (2,))
    for i in range(6):
        f.raw(cup(4 + i, 1 + i * 10) + "C")
        f.raw(csi(f"{4 + i};{90 - i * 10}f") + "H")

    f.at(11, 1, "CHA (CSI G) and VPA (CSI d):", (2,))
    f.raw(cup(11, 30) + "G30")
    f.raw(csi("60G") + "G60")
    f.raw(csi("12d") + "VPA12")

    f.at(13, 1, "save/restore ESC 7 / ESC 8:", (2,))
    f.raw(cup(13, 30) + "abc" + E + "7")
    f.raw(cup(13, 60) + "XXX" + E + "8" + "DEF")
    f.at(14, 1, "save/restore CSI s / CSI u:", (2,))
    f.raw(cup(14, 30) + "ghi" + csi("s"))
    f.raw(cup(14, 60) + "YYY" + csi("u") + "JKL")

    f.at(15, 1, "tab tests:", (1,))
    f.raw(cup(16, 1) + "A\tB\tC\tD")
    f.at(16, 40, "default stops 9/17/25/33", (2,))
    f.raw(csi("3g"))
    for col in (10, 20, 30):
        f.raw(cup(17, col) + E + "H")
    f.raw(cup(17, 1) + "A\tB\tC\tD")
    f.at(17, 40, "custom stops 10/20/30", (2,))
    f.raw(cup(18, 31) + "X" + csi("Z") + "Y")
    f.at(18, 40, "CBT backtab", (2,))

    f.at(20, 1, "autowrap: 100 cells then forced wrap:", (1,))
    f.at(21, 1, "A" * 99 + "B" + "CD")
    f.at(22, 10, "wrapped C,D should be at row 22 cols 1-2", (2,))

    f.at(24, 1, "DECAWM off: 105 X at column 1 must not spill:", (1,))
    f.raw(cup(25, 1) + csi("?7l") + "X" * 105 + csi("?7h"))
    f.at(26, 10, "row 26 must stay empty (DECAWM off clamps at column 100)", (2,))

    f.raw(cup(27, 100) + "Q")
    f.at(27, 1, "L", (1,))
    f.at(27, 10, "last-column write then CUP away:", (2,))
    f.at(28, 10, "no spurious wrap on row 28 (a stray L would appear at col 1)", (2,))

    f.at(29, 1, "columns 1..100 markers:", (2,))
    for c in range(1, 101, 10):
        f.raw(cup(30, c) + str((c // 10) % 10))
    return f.build()


# --------------------------------------------------------------------------
# 24 - mixed real-world torture
# --------------------------------------------------------------------------


def frame_24_mixed() -> str:
    f = Frame()
    f.title("24  Mixed torture: prompt + code + powerline + emoji + CJK + table")

    # Prompt with powerline segments.
    f.raw(cup(2, 1) + sgr(bgrgb(30, 40, 90), fgrgb(230, 240, 255)) + " nil@kmshaunt ")
    f.raw(sgr(bgrgb(30, 120, 90), fgrgb(30, 40, 90)) + "\ue0b0")
    f.raw(sgr(bgrgb(30, 120, 90), fgrgb(230, 255, 240)) + " ~/Projects/kmshaunt2 ")
    f.raw(sgr(bgrgb(140, 90, 30), fgrgb(30, 120, 90)) + "\ue0b0")
    f.raw(sgr(bgrgb(140, 90, 30), fgrgb(255, 240, 220)) + " main ")
    f.raw(sgr(0, fgrgb(140, 90, 30)) + "\ue0b0")
    f.raw(RESET)

    f.at(3, 1, "❯", (1, 32))
    f.at(3, 3, "zig build test --summary all", (1,))
    f.at(3, 32, "⚡ 0.42s", (2,))

    code = [
        (' 1 ', "const std = @import(\"std\");", (36,)),
        (' 2 ', "fn main() !void {", (36,)),
        (' 3 ', "    var gpa = std.heap.GeneralPurposeAllocator(.{}){};", ()),
        (' 4 ', "    const buf = try alloc.alloc(u8, 1 << 16);", ()),
        (' 5 ', "    if (buf.len >= 4096 and buf.len != 0) return render(buf);", ()),
        (' 6 ', "    for (0..buf.len) |i| buf[i] = @intCast(i & 0xff);", ()),
        (' 7 ', "} // fast path: -> => === != <=>", (2,)),
    ]
    for i, (num, text, codes) in enumerate(code):
        row = 4 + i
        f.at(row, 1, num, (2,))
        f.at(row, 5, text, codes)

    f.at(12, 1, "✓", (1, 32))
    f.at(12, 3, "3/3 steps succeeded", (32,))
    f.at(13, 1, "✓", (1, 32))
    f.at(13, 3, "12/12 tests passed in 0.42s", (32,))

    f.at(15, 1, "◆", (2,))
    f.at(15, 3, "a1b2c3d feat: render 100×30 byte-exact", (36,))
    f.at(15, 46, "👨\u200d💻", ())
    f.at(16, 1, "◆", (2,))
    f.at(16, 3, "e4f5g6h fix: CJK 名前 padding", (36,))
    f.at(16, 46, "🇺🇸", ())

    table = cjk_table()
    for i, line in enumerate(table):
        f.at(18 + i, 3, line)

    # Statusline.
    f.raw(cup(25, 1) + sgr(bgrgb(30, 40, 90), fgrgb(230, 240, 255)) + "  main*  ")
    f.raw(sgr(bgrgb(30, 120, 90), fgrgb(30, 40, 90)) + "\ue0b0")
    f.raw(sgr(bgrgb(30, 120, 90), fgrgb(230, 255, 240)) + "  ✓ 12 tests  ")
    f.raw(sgr(bgrgb(140, 90, 30), fgrgb(30, 120, 90)) + "\ue0b0")
    f.raw(sgr(bgrgb(140, 90, 30), fgrgb(255, 240, 220)) + "  ⌁ 42%  ")
    f.raw(sgr(0, fgrgb(140, 90, 30)) + "\ue0b0")
    f.raw(RESET)

    f.at(27, 1, "⚠️", ())
    f.at(27, 4, "3 files changed, 1 insertion(+), 2 deletions(-)", (33,))
    f.at(27, 54, "◇ ٣ ملفات: مرحبا.txt", ())

    f.at(29, 1, "BYTE-EXACT TARGET", ())
    for i, ch in enumerate(" · diff = 0"):
        f.raw(cup(29, 18 + i) + sgr(fgrgb(255 - i * 12, 120 + i * 8, 255)) + ch)
    f.raw(RESET)
    f.at(29, 36, "grid 100x30, cursor hidden", (2,))
    return f.build()


# --------------------------------------------------------------------------
# 25 - rounded corners (btop / lazygit)
# --------------------------------------------------------------------------


def rect(width: int, height: int, corners: str, label: str = "") -> list[str]:
    tl, tr, bl, br = corners
    h, v = "─", "│"
    lines = [tl + h * (width - 2) + tr]
    for r in range(height - 2):
        inner = " " * (width - 2)
        if r == 0 and label:
            inner = pad_display(" " + label, width - 2)
        lines.append(v + inner + v)
    lines.append(bl + h * (width - 2) + br)
    return lines


ROUNDED = "╭╮╰╯"
LIGHT = "┌┐└┘"
DOUBLE = "╔╗╚╝"


def frame_25_rounded() -> str:
    f = Frame()
    f.title("25  Rounded corners: ╭ ╮ ╰ ╯ squares (btop / lazygit)")
    f.at(2, 1, "Isolated corners:  ╭   ╮   ╰   ╯   (U+256D U+256E U+2570 U+256F)", (2,))

    # Same-size boxes: rounded vs sharp references, to expose corner rendering.
    for idx, (corners, name) in enumerate(
        ((ROUNDED, "rounded"), (LIGHT, "light"), (DOUBLE, "double"))
    ):
        col = 1 + idx * 30
        for i, line in enumerate(rect(26, 9, corners, name)):
            f.at(4 + i, col, line)

    # Nested rounded panels, lazygit style.
    for i, line in enumerate(rect(40, 8, ROUNDED, "lazygit outer")):
        f.at(15 + i, 1, line)
    for i, line in enumerate(rect(20, 4, ROUNDED, "inner")):
        f.at(17 + i, 6, line)

    # Rounded panel with a header rule, btop style.
    for i, line in enumerate(rect(40, 8, ROUNDED, "btop cpu")):
        f.at(15 + i, 45, line)
    f.at(17, 46, "├" + "─" * 38 + "┤")

    f.at(25, 1, "small: ╭─╮ ╭──╮ ╭───╮   ╰─╯ ╰──╯ ╰───╯", (2,))
    f.at(27, 1, "Corners must join ─ and │ with a smooth arc: no gap, overlap, or square joint.", (2,))
    return f.build()


# --------------------------------------------------------------------------
# registry / main
# --------------------------------------------------------------------------

FRAMES: list[tuple[str, str]] = [
    ("01-ascii-sgr.bin", frame_01_ascii()),
    ("02-sgr-attributes.bin", frame_02_attributes()),
    ("03-underline-styles.bin", frame_03_underline()),
    ("04-color-modes.bin", frame_04_colors()),
    ("05-box-drawing.bin", frame_05_box()),
    ("06-block-elements.bin", frame_06_blocks()),
    ("07-braille.bin", frame_07_braille()),
    ("08-legacy-computing.bin", frame_08_legacy()),
    ("09-powerline-nerd.bin", frame_09_powerline()),
    ("10-ligatures.bin", frame_10_ligatures()),
    ("11-combining-marks.bin", frame_11_combining()),
    ("12-nfc-nfd.bin", frame_12_nfc_nfd()),
    ("13-cjk-wide.bin", frame_13_cjk()),
    ("14-emoji.bin", frame_14_emoji()),
    ("15-variation-selectors.bin", frame_15_vs()),
    ("16-bidi-rtl.bin", frame_16_bidi()),
    ("17-complex-shaping.bin", frame_17_shaping()),
    ("18-zero-width-invisible.bin", frame_18_zero_width()),
    ("19-cursor-block-steady.bin", frame_19_cursor_block()),
    ("20-cursor-beam-blink.bin", frame_20_cursor_beam_blink()),
    ("21-cursor-underline-steady.bin", frame_21_cursor_underline()),
    ("22-double-width-height.bin", frame_22_double_lines()),
    ("23-positioning-wrap.bin", frame_23_positioning()),
    ("24-mixed-torture.bin", frame_24_mixed()),
    ("25-rounded-corners.bin", frame_25_rounded()),
]

CURSOR_FRAMES = {
    "19-cursor-block-steady.bin",
    "20-cursor-beam-blink.bin",
    "21-cursor-underline-steady.bin",
}

# Query sequences that must never appear: DSR, DA, XTVERSION, any OSC/DCS.
FORBIDDEN = [
    re.compile(rb"\x1b\[[?>]?[0-9;]*n"),
    re.compile(rb"\x1b\[[?>=]?[0-9;]*c"),
    re.compile(rb"\x1b\[>[0-9;]*q"),
    re.compile(rb"\x1b\]"),
    re.compile(rb"\x1bP"),
    re.compile(rb"\x1b\^"),
    re.compile(rb"\x1b_"),
]


def validate(name: str, data: bytes) -> None:
    if not data.startswith(PROLOGUE.encode()):
        raise SystemExit(f"{name}: missing prologue")
    for rx in FORBIDDEN:
        m = rx.search(data)
        if m:
            raise SystemExit(f"{name}: forbidden query sequence near byte {m.start()}")
    if b"\r" in data:
        raise SystemExit(f"{name}: contains CR")
    if b"\n" in data:
        raise SystemExit(f"{name}: contains LF (frames must be CUP-positioned)")
    if name in CURSOR_FRAMES:
        if b"\x1b[?25h" not in data[-40:]:
            raise SystemExit(f"{name}: cursor frame does not leave the cursor visible")
        if not re.search(rb"\x1b\[[0-9]+;[0-9]+H$", data):
            raise SystemExit(f"{name}: cursor frame does not end with a fixed CUP")
    else:
        if not data.endswith(EPILOGUE.encode()):
            raise SystemExit(f"{name}: missing epilogue")
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SystemExit(f"{name}: not valid UTF-8: {exc}") from exc


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    names = [name for name, _ in FRAMES]
    if len(names) != len(set(names)):
        raise SystemExit("duplicate frame filename")
    if not (10 <= len(FRAMES) <= 30):
        raise SystemExit(f"frame count {len(FRAMES)} outside 10-30")

    manifest = HERE / "manifest.md"
    manifest_text = manifest.read_text(encoding="utf-8") if manifest.exists() else None

    total = 0
    changed = 0
    for name, body in FRAMES:
        ending = "" if name in CURSOR_FRAMES else EPILOGUE
        data = (PROLOGUE + body + ending).encode("utf-8")
        validate(name, data)
        path = OUT_DIR / name
        old = path.read_bytes() if path.exists() else None
        if old != data:
            changed += 1
        path.write_bytes(data)
        total += len(data)
        print(f"{name:38s} {len(data):7d} bytes" + ("" if old is None else ("  changed" if old != data else "  identical")))
        if manifest_text is not None and name not in manifest_text:
            print(f"  WARNING: {name} not mentioned in manifest.md")

    extra = sorted(p.name for p in OUT_DIR.glob("*.bin") if p.name not in set(names))
    if extra:
        print("WARNING: stale frames not generated by this script: " + ", ".join(extra))

    print(f"\n{len(FRAMES)} frames, {total} bytes total, {changed} changed")
    print(f"grid: {COLS} cols x {ROWS} rows")
    if manifest_text is None:
        print("manifest.md not present yet (write it next)")


if __name__ == "__main__":
    main()