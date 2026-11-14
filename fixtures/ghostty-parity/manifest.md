# Ghostty ↔ kmshaunt byte-exact parity frames

Fixtures for an autoresearch loop that feeds the **same bytes** to ghostty (under
Wayland/cage) and kmshaunt (DRM/KMS console), screenshots both, and minimizes
per-pixel channel distance. The target is `sum(|ΔR|+|ΔG|+|ΔB|) == 0`.

- Generator (source of truth): [`generate_frames.py`](generate_frames.py)
- Payloads: [`frames/*.bin`](frames/) — raw bytes written to the pty
- 24 frames, 62,090 bytes total at the time of writing

The rasterizer/blend path is intentionally fair game: anti-aliasing, hinting,
gamma, sprite-vs-font choice, and colour-font paths are the target, not noise.

## Grid assumption

| Property | Value |
|---|---|
| Columns | **100** (`COLS` in the generator) |
| Rows | **30** (`ROWS` in the generator) |
| Pty size given to both terminals | exactly 100 × 30 cells |
| Cell width | one font advance; East-Asian Wide/Fullwidth = **2** cells |
| Combining marks / ZWJ / ZWSP / SHY / WJ / BOM | **0** cells |
| Ambiguous-width characters (α, ※, ±, …) | terminal/`unicode-width` policy; documented per frame and placed with CUP so drift is visible, not destructive |
| Font pixel size | identical on both VMs (harness responsibility); the grid is logical cells, not pixels |

Frames never write past column 100 and never rely on scrolling. Row 30 is used
only through CUP; no frame emits a line feed, so the 30-row screen cannot scroll.
The only output that can wrap is frame 23, where wrapping is the test.

## Wire contract baked into every payload

Each `.bin` starts with exactly:

```
ESC c          RIS (reset terminal, clears screen, home cursor)
ESC [ ? 25 l   hide cursor
ESC [ H        home
ESC [ 0 m      SGR reset
```

and every non-cursor frame ends with:

```
ESC [ 0 m      SGR reset
ESC ( B        restore G0 = ASCII
ESC ) B        restore G1
SI (0x0f)      select G0
ESC [ ? 7 h    autowrap on
ESC [ ? 25 l   hide cursor
ESC [ H        home
```

Cursor frames (19–21) end with `SGR 0`, charset restore, autowrap on, the specific
`DECSCUSR` style, `ESC[?25h`, and a final CUP to the documented cell. The cursor
stays visible there; every other frame hides it.

Output-only rules: no DA/DSR/XTVERSION/OSC-query/DCS/APC, no mouse reporting, no
time-dependent content, no shell. Colours are explicit wherever colour is tested
(the default-fg/bg rows are called out below). All escapes are real control bytes
in the `.bin`; the Python source uses `\x1b` and `\u` escapes so it stays readable.

## Harness prerequisites

1. Both terminals get identical fonts, font features, font sizes, hinting/AA
   settings, 16-colour palette, default fg/bg, and cursor colour.
2. Feed the whole `.bin` (it already contains the prologue), then wait for the
   screen to settle before capturing. There are no queries to answer.
3. Most frames are fully static. Exceptions are marked **time-dependent**:
   frame 02 (SGR 5/6 text blink) and frame 20 (DECSCUSR 5 blinking cursor).
   For a strictly phase-free diff, disable text/cursor blinking in both
   terminals, or capture both at the same fixed offset from the write.
4. Colour emoji format (CBDT / sbix / COLRv0 / COLRv1) is chosen by the installed
   font file, not by the terminal escape stream. See frame 14.

## Frame index

| # | File | Category | One-line purpose |
|---|---|---|---|
| 01 | `01-ascii-sgr.bin` | ASCII + SGR sanity | All 95 printable ASCII, 16 ANSI fg/bg, bold/dim |
| 02 | `02-sgr-attributes.bin` | SGR attributes | bold, dim, italic, blink, reverse, hidden, strike, off codes |
| 03 | `03-underline-styles.bin` | SGR attributes | single/double/curly/dotted/dashed, SGR 58/59 |
| 04 | `04-color-modes.bin` | Colour modes | 16 / 256 / truecolor fg+bg, defaults, reverse, gradients |
| 05 | `05-box-drawing.bin` | Box drawing | U+2500 block + DEC Special Graphics (`ESC(0`, SO/SI) |
| 06 | `06-block-elements.bin` | Blocks & shades | halves, eighths, quadrants, ░▒▓█, blend bars |
| 07 | `07-braille.bin` | Braille | dot patterns, dense fields, computed raster art |
| 08 | `08-legacy-computing.bin` | Legacy computing | sextants, mosaics, octants, segmented digits |
| 09 | `09-powerline-nerd.bin` | Powerline/Nerd | separators, statuslines, PUA icon grid |
| 10 | `10-ligatures.bin` | Ligatures | fi/fl/ffi, arrows, comparisons, operators |
| 11 | `11-combining-marks.bin` | Combining marks | single/stacked marks, cell-advance checks |
| 12 | `12-nfc-nfd.bin` | NFC vs NFD | precomposed vs decomposed pairs, flow alignment |
| 13 | `13-cjk-wide.bin` | Wide CJK | hanzi, kanji, hangul, fullwidth, CJK table |
| 14 | `14-emoji.bin` | Emoji (+ colour formats) | VS16, skin tones, ZWJ, flags, keycaps, alpha over bg |
| 15 | `15-variation-selectors.bin` | Variation selectors | FE0E vs FE0F text/emoji presentation |
| 16 | `16-bidi-rtl.bin` | RTL/bidi | Arabic + Hebrew shaping, mixed LTR/RTL, bidi controls |
| 17 | `17-complex-shaping.bin` | Complex shaping | Devanagari, Bengali, Thai, Tamil, Telugu, Arabic ligatures |
| 18 | `18-zero-width-invisible.bin` | Zero-width | ZWJ/ZWNJ/ZWSP/SHY/WJ/BOM and cluster edges |
| 19 | `19-cursor-block-steady.bin` | Cursor | DECSCUSR 2, cursor visible at row 15 col 50 |
| 20 | `20-cursor-beam-blink.bin` | Cursor | DECSCUSR 5, cursor visible at row 10 col 25 (blink) |
| 21 | `21-cursor-underline-steady.bin` | Cursor | DECSCUSR 4, cursor visible at row 20 col 75 |
| 22 | `22-double-width-height.bin` | DECDWL/DECDHL | double-width and double-height line attributes |
| 23 | `23-positioning-wrap.bin` | Positioning/wrap | CUP/HVP, tabs, save/restore, autowrap on/off |
| 24 | `24-mixed-torture.bin` | Mixed torture | prompt + code + powerline + emoji + CJK + table |

---

## Per-frame details

### 01 — `01-ascii-sgr.bin` — ASCII + basic SGR sanity

- **Tests:** all printable ASCII `0x20–0x7E` in hex rows (reverse video so the
  space is visible), a pangram, normal/bright 16-colour foregrounds and
  backgrounds, bold/dim/underline.
- **Why hard:** cell width and glyph advance for every ASCII code point; the
  16-colour palette is configuration, so both VMs must share it; reverse video
  changes which channel is painted (fg vs bg).
- **Font:** any monospace with full Basic Latin. Suggested: DejaVu Sans Mono,
  JetBrains Mono, Noto Sans Mono.
- **Grid:** ASCII only; one cell per glyph.

### 02 — `02-sgr-attributes.bin` — SGR text attributes

- **Tests:** SGR 1/2/3/5/6/7/8/9 singly and combined; SGR 53 overline; SGR
  22/23/24/25/27/28/29 off codes; SGR 0 stack reset; SGR 51/52/73/74.
- **Why hard:** synthetic bold/italic/oblique differ per renderer; blink is
  animated; invisible text must leave the background intact; the rasterizer may
  synthesize attributes from the same outline with different emboldening/slant.
- **Font:** regular/bold/italic faces (synthetic fallback allowed but must match
  between terminals). Suggested: JetBrains Mono, DejaVu Sans Mono.
- **Grid:** 1 cell per glyph; attributes do not change advance.
- **Time-dependent:** rows with SGR 5 and SGR 6 (blink). Capture phase-stable or
  disable blink.

### 03 — `03-underline-styles.bin` — underline styles and colour

- **Tests:** SGR 4, 21, `4:2`, `4:3` (curly), `4:4` (dotted), `4:5` (dashed);
  SGR 58;5;196, 58;2;0;255;128, SGR 59 reset mid-line; underline across spaces,
  descenders and wide CJK; `4:0` partial reset.
- **Why hard:** style-aware underlines are usually drawn by the terminal, not the
  font; curly/dotted/dashed geometry, thickness, offset from baseline, and
  clipping under descenders all differ. SGR 58 requires per-cell colour state.
- **Font:** plain monospace; suggested JetBrains Mono or DejaVu Sans Mono, plus
  CJK coverage for the wide row (Noto Sans CJK).
- **Grid:** underline must span exactly the cells of the underlined text.

### 04 — `04-color-modes.bin` — colour modes

- **Tests:** 16-colour fg on explicit bg; 256-colour palette 0–15, the full
  6×6×6 cube 16–231, greyscale 232–255; `38;2`/`48;2` truecolor fg and bg; SGR
  39/49 defaults; reverse over truecolor; 3×100-cell truecolor gradient.
- **Why hard:** palette lookup vs direct RGB, gamma/colour conversion, dithering
  (none expected), and `sRGB` vs linear blending in the compositor. The gradient
  exposes per-channel rounding and any palette quantization.
- **Font:** any monospace; the block swatches use spaces/cells.
- **Grid:** 100 cells of gradient per row; explicit colours except the labelled
  default-fg/bg row.

### 05 — `05-box-drawing.bin` — box drawing + DEC Special Graphics

- **Tests:** U+2500 light/heavy/double/mixed boxes with internal grids; junction
  sampler; rounded corners and diagonals; dashed variants; a full DEC Special
  Graphics box designated with `ESC(0`, the same charset via G1 + SO/SI, and the
  character map (`jklmnqtuvwxafg~yz{|}`).
- **Why hard:** sprite tables (kmshaunt) vs font glyphs (ghostty) must meet at
  exact pixel edges; line thickness and junction geometry differ; DEC graphics
  is a legacy charset path that may bypass normal shaping/fallback.
- **Font:** box-drawing coverage in the mono face or a symbols fallback.
  Suggested: JetBrains Mono, DejaVu Sans Mono, Noto Sans Symbols 2.
- **Grid:** every box glyph is exactly one cell; DEC charset uses the same cells.

### 06 — `06-block-elements.bin` — block elements and shades

- **Tests:** upper/lower/left/right partial blocks, quadrants, quadrant mosaics,
  ░▒▓█ shades, fg-block over bg-block bars, per-column shade density ramps.
- **Why hard:** partial blocks must fill their cell fraction exactly; sprite
  rasterization vs a font's block glyphs can differ by a row/column of pixels;
  foreground/background compositing differs. This is a direct probe of the
  rasterizer.
- **Font:** block elements + shades. Suggested: DejaVu Sans Mono, Noto Sans Mono,
  GNU Unifont as fallback.
- **Grid:** one cell per block; edges must tile with no seams.

### 07 — `07-braille.bin` — braille patterns

- **Tests:** single dots, masks 0–63, a 40×4-cell `⣿` field, computed 40×8-dot
  diagonal/checker/ring rasters, coloured braille over backgrounds, and a
  100-cell pattern cycle.
- **Why hard:** 2×4 dot geometry must land on the same sub-cell grid and have the
  same dot radius; fonts vs sprite tables; clipping at cell bounds.
- **Font:** Braille Patterns coverage. Suggested: DejaVu Sans Mono, Noto Sans
  Mono, GNU Unifont.
- **Grid:** one braille character per cell; dots occupy the full 2×4 sub-grid.

### 08 — `08-legacy-computing.bin` — sextants, mosaics, octants, segmented digits

- **Tests:** U+1FB00–1FB3B sextants, U+1FB3C–1FB67 diagonals, triangular blocks,
  eighth/quarter blocks, medium-shade mosaics, U+1FBA0–1FBDF box diagonals and
  circles, U+1FBF0–1FBF9 segmented digits, plus Unicode 16 block octants at
  U+1CD00 (sampled).
- **Why hard:** these were designed for 8×8 bitmap terminals; coverage is rare,
  fallback chains differ, and tofu must at least be identical tofu. The 1FB00
  plane is adjacent to emoji/PUA and may be intercepted by sprite special-casing.
- **Font:** Legacy Computing coverage. Suggested: Noto Sans Symbols 2, GNU
  Unifont (check its Unicode 16 version for U+1CD00), or any bitmap terminal
  font with the block. Octants are frequently missing → expect tofu.
- **Grid:** one cell per glyph; the U+1CD00 row is explicitly outside the
  1FB00 block (the task brief grouped them; Unicode 16 put octants at U+1CD00).

### 09 — `09-powerline-nerd.bin` — Powerline + Nerd Font PUA

- **Tests:** a coloured statusline using U+E0B0 transitions, E0B0–E0B7, E0A0–
  E0A2, a 30-icon PUA grid (Font Awesome codepoints, U+E718/U+E795, U+F8FF),
  tiling separators, and a truecolor statusline.
- **Why hard:** PUA codepoints are font-specific; a patched Nerd Font must be
  installed and selected identically. Separators are often drawn slightly beyond
  the cell box; the previous bg/fg colour pair must meet seamlessly.
- **Font:** **Nerd Fonts patched monospace** (JetBrainsMono Nerd Font, FiraCode
  Nerd Font, Hack Nerd Font). Not optional: without it both sides show tofu and
  the frame proves nothing about separator/icon parity.
- **Grid:** separator glyphs are one cell; adjacent separators must tile into a
  continuous edge.

### 10 — `10-ligatures.bin` — programming ligatures

- **Tests:** fi/fl/ffi/ffl; `-> => <= >= <-> <=>`; `== === != !==`; `:: ::= :=`;
  `|> <| >>= <$> <*> <&>`; `&& ||`; numbers; code context.
- **Why hard:** the same text must shape identically **and** keep monospace cell
  advances; ligature substitution is a HarfBuzz/font-feature setting. One
  terminal may shape while the other does not, or may substitute a different
  glyph set. Underlines expose advance changes.
- **Font:** JetBrains Mono, Fira Code, or Cascadia Code with `liga` + `calt`.
  **Feature parity is part of the harness config**, not the escape stream.
- **Grid:** ligatures must not change the cell count of the source characters.

### 11 — `11-combining-marks.bin` — combining diacritics

- **Tests:** single marks over base letters, multiple stacked marks, marks over
  precomposed bases, wide base + mark, U+20DD enclosing circle, a U+0300–U+030F
  sampler, coloured marks, underlined cluster, mark-only run; ruler at top/bottom.
- **Why hard:** zero-width clustering, glyph attachment, mark positioning outside
  the cell, clipping, and whether marks are shaped by HarfBuzz or drawn by the
  font fallback. A mark that becomes a cell shifts every following character.
- **Font:** combining diacritics coverage. Suggested: DejaVu Sans, Noto Sans,
  Noto Sans Mono.
- **Grid:** base = 1 cell, marks = 0; the per-row bar column verifies advance.

### 12 — `12-nfc-nfd.bin` — NFC vs NFD canonical equivalence

- **Tests:** 12 canonical pairs (é, ñ, ü, Å, ç, ő, ǘ, ḗ, ά, ΐ, й, ế) with NFC and
  NFD forms at fixed columns, then full NFC/NFD flows, Hangul syllable vs jamo.
- **Why hard:** the shaper or font must compose decomposed sequences into the
  same glyph; per-codepoint fallback can pick a different font for the base and
  the mark, yielding different advance/glyph. Both paths must be pixel-identical.
- **Font:** full Latin Extended + Greek/Cyrillic coverage; suggested Noto Sans
  Mono or DejaVu Sans Mono, with Noto Sans CJK for the Hangul row.
- **Grid:** composed and decomposed forms must each occupy exactly one cell and
  the trailing `|` and `MARK` columns must align.

### 13 — `13-cjk-wide.bin` — wide/fullwidth CJK

- **Tests:** Chinese, Japanese, Korean sentences, fullwidth Latin/digits and
  punctuation, mixed ASCII/CJK flow, a CJK/ASCII box table whose borders depend
  on width 2, ambiguous-width characters (α ※ ± …), double-width background
  cells, fullwidth+emoji adjacency; ruler.
- **Why hard:** wide-cell accounting, double-width background painting, fallback
  font selection per script (SC/JP/KR may come from different faces), and
  ambiguous-width policy. A one-cell width error breaks the table borders.
- **Font:** Noto Sans CJK (SC + JP + KR, or the pan-CJK face), Source Han Sans.
  Ambiguous characters need a policy decision; the frame pins them with CUP so a
  mismatch is visible without destroying the layout.
- **Grid:** Wide/Fullwidth = 2 cells. The CJK table is padded by display width.

### 14 — `14-emoji.bin` — emoji and colour-font formats

- **Tests:** single-codepoint emoji, VS16, five skin-tone modifiers, ZWJ families
  and professions, regional-indicator flags, tag-sequence flags (Scotland,
  England), keycaps, natural-flow alignment, emoji over explicit backgrounds.
- **Why hard:** colour glyph formats (CBDT/sbix/COLRv0/COLRv1) are selected by
  the font file, not by escapes; ZWJ sequences may render as one 2-cell cluster
  or as separate glyphs; alpha compositing over a coloured background differs;
  tag sequences are zero-width and fragile.
- **Font:** Noto Color Emoji (CBDT) as the primary. To exercise other formats,
  swap in a face that uses them (e.g. an sbix Apple-style face, a COLRv0 face
  such as Twemoji Mozilla/Noto Emoji COLR, or a COLRv1 face) — **the harness must
  use the same file on both VMs**. Noto Emoji provides monochrome text forms.
- **Grid:** emoji are 2 cells; rows are spaced at 7–15 columns so width policy
  differences do not overlap. Natural-flow row uses a CUP-pinned `END` marker.
- **Merged category:** the brief's item 14 (“colour emoji font formats”) is
  merged here because format choice is a font-installation property, not an
  output-byte property. Swapping the emoji font file is the only way to exercise
  it; see the harness note above.

### 15 — `15-variation-selectors.bin` — text vs emoji presentation

- **Tests:** U+FE0E / U+FE0F on ❤ ☀ ☺ ✈ ✉ ⚠ ✔ ✖ © ® ™ ‼ ⁉ ↔; digits with no
  VS / FE0E / FE0F / keycap; unsupported VS on ASCII; flow of all text forms and
  all emoji forms.
- **Why hard:** VS15/VS16 scope, default presentation, whether the terminal
  or font honours the selector, and the resulting cell width (monochrome text
  form may be 1 cell, emoji form 2). Colour vs monochrome glyph choice must match.
- **Font:** a monochrome symbols/emoji face plus a colour emoji face. Suggested:
  Noto Emoji + Noto Color Emoji, or Noto Sans Symbols 2.
- **Grid:** text forms may be 1 cell, emoji forms 2; the frames place each form at
  a fixed column and include a flow row with a pinned `|` marker.

### 16 — `16-bidi-rtl.bin` — RTL and bidi

- **Tests:** Arabic phrases, lam-alef ligature, Arabic-Indic digits, Arabic
  diacritics, mixed LTR/RTL, Hebrew with niqqud, mixed Hebrew/Latin, bidi control
  characters (RLO/PDF, RLE/PDF, RLI/PDI), bracket mirroring, Persian/Urdu.
- **Why hard:** requires a bidi algorithm plus Arabic shaping/joining; glyph
  order, mark positioning, bracket mirroring, and interaction with the cell grid.
  Ghostty and kmshaunt may or may not implement bidi identically; the frame makes
  the difference visible in a fixed layout.
- **Font:** Noto Sans Arabic, Noto Sans Hebrew. Suggested additional: Noto Naskh
  Arabic for more traditional shaping.
- **Grid:** RTL text is placed with CUP per row; cell width assumptions are the
  same (Arabic letters normally 1 cell). If bidi is unimplemented, output must at
  least be deterministic and identical in both.
- **NOTE:** the RTL frame is the one most likely to differ because of a missing
  feature rather than rasterization. That is intentional: the fixture records it.

### 17 — `17-complex-shaping.bin` — complex shaping (HarfBuzz)

- **Tests:** Devanagari (नमस्ते, क्षेत्र, हिन्दी, संस्कृतम्, ZWJ conjunct), Bengali,
  Thai (including above/below tone marks and vowels), Tamil, Telugu, Arabic
  ligatures (الله, لا إله إلا الله), mixed scripts, coloured/underlined clusters.
- **Why hard:** reordering, conjunct ligatures, above/below mark placement, and
  cluster cell counts; every script may need a different fallback face. Font
  feature settings can change joining/ligation.
- **Font:** Noto Sans Devanagari, Noto Sans Bengali, Noto Sans Thai, Noto Sans
  Tamil, Noto Sans Telugu, Noto Sans Arabic (or Noto Sans + script-specific
  faces). HarfBuzz must be used by both terminals.
- **Grid:** shaped clusters are placed at fixed columns; a cluster may occupy 1–2
  cells depending on the script/font. The frame does not assume a single width
  for every cluster; it checks that both terminals choose the same one.

### 18 — `18-zero-width-invisible.bin` — zero-width and invisible characters

- **Tests:** ZWSP, ZWJ, ZWNJ, word joiner, soft hyphen, BOM; a mixed zero-width
  run; Persian ZWNJ vs joined; Devanagari ZWJ/ZWNJ conjunct control; zero-width
  inside combining clusters; zero-width around emoji; soft hyphen in a word.
- **Why hard:** width tables often disagree on ZWSP/SHY/BOM; ZWJ can change
  shaping without changing advance; BOM at the start of a CUP-positioned run must
  be invisible. Any accidental 1-cell advance shifts the whole row.
- **Font:** any; the relevant coverage is Arabic/Devanagari for the shaping rows.
  Suggested: Noto Sans Arabic + Noto Sans Devanagari.
- **Grid:** all listed controls are 0 cells; the ruler and per-row bars expose
  accidental advances.

### 19 — `19-cursor-block-steady.bin` — cursor: steady block

- **Tests:** `DECSCUSR 2` (steady block), cursor left visible at **row 15,
  column 50** after a final CUP. Sparse `+` markers at 10-column intervals
  (cursor cell skipped) make the cursor position obvious.
- **Why hard:** hardware cursor plane vs software cursor, cursor colour/inversion,
  and whether the cursor paints the cell background or the glyph. A block cursor
  is the largest cursor area and exposes colour/blend differences.
- **Font:** any monospace.
- **Grid:** cursor cell is exactly one cell at (15, 50). No writes follow the
  final CUP.

### 20 — `20-cursor-beam-blink.bin` — cursor: blinking beam

- **Tests:** `DECSCUSR 5` (blinking beam), cursor visible at **row 10, column 25**.
- **Why hard:** beam thickness and height are terminal-defined; blink phase is
  time-dependent. This frame covers a blink style so the DECSCUSR parser and the
  animation path are exercised, not only static shapes.
- **Font:** any monospace.
- **Grid:** cursor cell (10, 25).
- **Time-dependent:** capture at a controlled blink phase, or disable cursor
  blinking on both terminals. The static counterpart is frame 19 (block) / 21
  (underline). If a phase-free diff is required, change the style constant from
  `5` to `6` in `frame_20_cursor_beam_blink` (steady beam) — the fixture is
  valuable either way, but the generator keeps the blinking variant to document
  DECSCUSR coverage.

### 21 — `21-cursor-underline-steady.bin` — cursor: steady underline

- **Tests:** `DECSCUSR 4` (steady underline), cursor visible at **row 20,
  column 75**.
- **Why hard:** underline cursor thickness/offset and whether it overlaps glyph
  descenders; must not repaint the whole cell.
- **Font:** any monospace.
- **Grid:** cursor cell (20, 75).

### 22 — `22-double-width-height.bin` — DECDWL / DECDHL

- **Tests:** `ESC#6` double-width line, `ESC#5` single-width restore, `ESC#3` top
  and `ESC#4` bottom double-height pair, coloured DECDHL halves, DECDWL with CJK,
  double-height box/block glyphs, and cursor-column accounting after a DECDWL
  line.
- **Why hard:** line attributes are a legacy VT feature; implementations differ in
  whether they scale glyphs horizontally/vertically or use special glyph sets.
  Font scaling must match exactly (including anti-aliasing and hinting), and the
  logical cursor column after a double-width line must be handled the same way.
- **Font:** any monospace with box/block glyphs; suggested JetBrains Mono or
  DejaVu Sans Mono. DECDHL is uncommon and may be unimplemented.
- **Grid:** DECDWL uses 50 logical cells for 100 physical columns; DECDHL pairs
  use two consecutive rows for top/bottom halves. The DECDWL line is kept at 40
  logical cells (80 physical columns) so it cannot touch the right edge.

### 23 — `23-positioning-wrap.bin` — positioning and wrap

- **Tests:** CUP and HVP diagonals; CHA (`CSI G`) and VPA (`CSI d`); save/restore
  with `ESC 7`/`ESC 8` and `CSI s`/`CSI u`; default tab stops; `CSI 3g` clear plus
  HTS (`ESC H`) custom stops; backtab (`CSI Z`); autowrap after exactly 100
  cells; `DECAWM` off with 105 characters; write at column 100 then CUP away
  (pending-wrap cancellation); markers every 10 columns on row 30.
- **Why hard:** cursor state machines and pending-wrap semantics are a common
  source of off-by-one differences; tabs depend on tab-stop state; `CSI s/u`
  vs `ESC 7/8` may have different saved attributes.
- **Font:** any monospace.
- **Grid:** 100×30; row 21 forces a wrap into row 22, row 25 proves DECAWM-off
  clamps at column 100, row 30 markers are all placed with CUP.

### 24 — `24-mixed-torture.bin` — mixed real-world torture

- **Tests:** a realistic shell prompt with powerline segments, ligature-rich Zig
  code with syntax colours, build/test output, git-log lines with emoji, a
  CJK/ASCII box table, a truecolor statusline, an emoji warning line with an
  Arabic filename, and a gradient "BYTE-EXACT TARGET" row.
- **Why hard:** this is the integration frame: width accounting, CJK padding,
  ligatures inside coloured text, powerline edges, colour emoji on the same line
  as ASCII, and truecolor gradients all interact. A single-cell error anywhere
  shifts the rest of the line.
- **Font:** the union of frames 09, 10, 13 and 14: a Nerd Font patched mono
  (JetBrainsMono Nerd Font), Noto Sans CJK, Noto Color Emoji, plus Arabic
  coverage for the filename (Noto Sans Arabic).
- **Grid:** 100×30; the table is padded by display width; emoji are 2 cells;
  the prompt and statusline are built from explicit segments with CUP anchors.

---

## Coverage notes

**Splits**

- Category 2 (SGR attributes) is split into **02** (text attributes, on/off codes,
  reset hygiene) and **03** (underline styles + underline colour). Both are dense
  enough to deserve their own screens, and underline rendering is a separate code
  path from bold/italic synthesis.
- Category 19 (cursor styles) is split into **19/20/21** because only one cursor
  can be visible per screenshot. The three frames cover block, beam and underline,
  plus one blinking style. This is the only way to compare DECSCUSR shapes
  statically.
- Category 14 (colour emoji font formats) is **merged into 14** (emoji), because
  the format is a property of the installed font file, not of the escape payload.
  To exercise CBDT/sbix/COLRv0/COLRv1, swap the emoji font file in both VMs and
  reuse the same frame; the manifest records the suggested faces.

**Not expressible as a static frame**

- **Blink phase:** SGR 5/6 (frame 02) and DECSCUSR 5 (frame 20) are animated.
  A static payload cannot pin the phase; capture timing or a blink-disable setting
  is required. Frames 19 and 21 are the static cursor counterparts.
- **Font-format selection:** emoji format (CBDT/sbix/COLRv0/COLRv1) and ligature
  feature selection (`liga`/`calt`) are font/config properties, not escapes.
  The frames define the text; the harness defines the face and features.
- **Ambiguous-width policy:** α/※/± width is a terminal configuration choice.
  Frame 13 pins those characters with CUP so a mismatch is visible locally rather
  than corrupting the rest of the screen. If the harness wants a strict test, set
  the same ambiguous-width policy on both terminals and compare that row.
- **DECDHL/DECDWL support:** some terminals ignore these attributes. The frame
  still records the difference deterministically (both may render normally, or
  one may scale). No escape can force an implementation to support them.

## Rebuild / determinism

```sh
python3 fixtures/ghostty-parity/generate_frames.py
```

The script has no timestamps, randomness, network access, or environment
dependence. It validates every payload before writing:

- starts with the exact prologue;
- no DA/DSR/XTVERSION/OSC/DCS/APC query sequences;
- no CR and no LF (all positioning is CUP/HVP; wrapping is tested explicitly in
  frame 23);
- non-cursor frames end with the exact epilogue; cursor frames end with
  `ESC[?25h` and a fixed CUP;
- valid UTF-8;
- 10–30 frames and unique filenames;
- if `manifest.md` exists, every generated filename is mentioned in it.

Re-running after a successful run reports every frame as `identical`. The frame
count is 25; total payload size is 65,420 bytes.

## Frame 25 — rounded corners (btop / lazygit)

`25-rounded-corners.bin` draws squares/panels with the rounded corner glyphs
╭ ╮ ╰ ╯ (U+256D–U+2570) as used by btop and lazygit, alongside same-size light
and double sharp-corner reference boxes, nested rounded panels, a btop-style
header rule, and small rounded squares. Added to expose a kmshaunt corner-
rendering bug: the arcs must join ─ and │ smoothly with no gap, overlap, or
square joint.