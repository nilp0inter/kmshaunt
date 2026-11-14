# kmshaunt ↔ ghostty rendering parity

Goal: byte-exact rendering parity with **ghostty v1.4.0** for the same terminal
input, font, and user configuration. This document describes the measurement
harness, the metric, the ported rendering behaviors, and the ghostty-compatible
configuration knobs.

Status (2026-11-14): aggregate pixel diff reduced **~83%**
(`total_abs_diff` 871,949,218 → 147,336,579) over the 25 parity frames at
1280×800 with `ComicCodeLigatures Nerd Font` @ 14pt. The residual is
anti-aliasing weight (kmshaunt 4×4 sprite supersampling vs ghostty's z2d
analytic coverage, and FreeType coverage nuance); a z2d analytic-coverage port
is the remaining follow-up toward 0.

## Measurement harness

Two otherwise-identical NixOS VMs render the same frames; only the terminal
differs:

- **kmshaunt** on the DRM console (this repo).
- **ghostty** fullscreen under **cage** (Wayland kiosk compositor).

Both share resolution (1280×800), virtio-vga, the same font set
(`ComicCodeLigatures Nerd Font` + Noto Color Emoji + Noto CJK + Noto), autologin
user, and an empty shell prompt. Each frame is a deterministic, output-only
byte payload (RIS prologue, absolute CUP positioning, no queries, cursor hidden
except the cursor frames) catted into the terminal; the VM's virtual display is
captured via QMP `screendump`.

Files:

| Path | Purpose |
|---|---|
| `nix/tests/ghostty-parity-capture.nix` | two-node NixOS test; feeds frames, QMP-captures each |
| `nix/tests/ghostty-parity-capture-build.nix` | build wrapper (pkgs + comic-code font + frames + kmshaunt module) |
| `nix/tests/parity-metric.py` | aggregates the pixel diff; emits `METRIC` lines |
| `autoresearch-parity.sh` | runs the capture then the metric (autoresearch entrypoint) |
| `fixtures/ghostty-parity/generate_frames.py` | deterministic frame generator (source of truth) |
| `fixtures/ghostty-parity/frames/*.bin` | 25 frame payloads |
| `fixtures/ghostty-parity/manifest.md` | per-frame coverage + font requirements |

Run:

```sh
nix build --impure --accept-flake-config \
  -f nix/tests/ghostty-parity-capture-build.nix --out-link result-parity
# or, capture + metric:
bash autoresearch-parity.sh
```

Screenshots land in `result-parity/` as `<node>-<frame>.png`. Side-by-side
composites for visual inspection: `parity-inspect/make_composites.py`.

### Metric

`parity-metric.py` loads each `(kmshaunt, ghostty)` pair as RGB and computes:

- **`total_abs_diff`** (primary, lower is better): sum over all pixels of
  `|ΔR|+|ΔG|+|ΔB|`. `0` = byte-exact across all frames.
- **`pixel_diff`** (secondary): count of pixels with any channel difference.
- Per-frame `ASI px_<frame>` counts for attribution.

Emitted as `METRIC total_abs_diff=…` / `METRIC pixel_diff=…` for the
autoresearch loop (`init_experiment` primary `total_abs_diff`, direction
`lower`, secondary `pixel_diff`).

### Frames (25)

ASCII/SGR; SGR attributes; underline styles; 16/256/truecolor; box drawing;
block elements; braille; legacy computing (+U+1CD00 octants); powerline/nerd;
ligatures; combining marks; NFC/NFD; CJK wide; emoji (single/VS16/skin-tone/ZWJ/
flags/keycaps); variation selectors; bidi/RTL; complex shaping (Indic/Thai/
Arabic); zero-width; cursors (block/beam/underline); double-width/height;
positioning/tabs/autowrap; mixed torture; rounded corners (btop/lazygit).

## Ported rendering behaviors (from ghostty v1.4.0)

- **Cell metrics** (`src/font/discovery.zig` `cellMetricsGhostty`): hhea/OS/2
  vertical-metric selection (USE_TYPO_METRICS → sTypo*, else hhea, else usWin),
  fractional `FT_Set_Char_Size` (points @ 96dpi), `@round` cell width/height,
  line-gap, baseline-from-bottom with half-gap centering, and `adjust-cell-*`
  recentering (ghostty `font/Metrics.zig` calc+apply).
- **Text raster**: fractional size applied at every face-sizing site (init,
  fallback, style variants, color-strike restore); no blit-time downscale
  (glyphs may overflow the cell like ghostty); light hinting
  (`FT_LOAD_TARGET_LIGHT | FT_LOAD_NO_SVG`).
- **Blend**: exact linear-corrected alpha blend (ghostty Linux default) with
  direct f32 sRGB encode; emoji (bgra8) composited in linear space.
- **Sprites** (`src/font/sprite_ghostty.zig`): ghostty `sprite/draw/*` geometry —
  box (Bézier rounded corners), blocks/shades/quadrants, braille, powerline
  (Bézier round separators + inner stroke), legacy computing (sextants, smooth
  mosaics, octants), geometric shapes. U+E0A0–E0A3 taken from the font (ghostty
  has no sprite for them).
- **Decorations/cursor** (`src/render/decorations.zig`): ghostty `special.zig` +
  z2d AA for underline styles (single/double/dotted/dashed/curly), strike/overline,
  and block/hollow/bar/underline cursors; baseline sign corrected.
- **Emoji**: mode **2027** (grapheme_cluster) enabled by default
  (`session/terminal.zig`, `setModeDefault` so RIS restores it) so ZWJ/skin-tone
  sequences arrive as one grapheme cell; presentation-aware color-face selection
  (VS15/VS16, full-cluster coverage) so sequences shape on Noto Color Emoji to a
  single composed glyph; `.cover` constraint + vendored stb Mitchell resize
  (`src/font/stbir.zig`).

## ghostty-compatible configuration knobs

Added to `src/config/config.zig` with ghostty v1.4.0 defaults (so identical user
config yields identical rendering). These are kmshaunt extensions, not kmscon
options (see `docs/reference/kmscon-options.md` for the kmscon surface).

| Option | Type | Default (ghostty) | Effect |
|---|---|---|---|
| `font-size` | points (0=auto) | 12 (kmshaunt 0=auto) | fractional `FT_Set_Char_Size(pt*64, 96)` |
| `adjust-cell-width` | MetricModifier | 0 | cell width delta (percent-f64 or absolute-i32 px) |
| `adjust-cell-height` | MetricModifier | 0 | cell height delta + baseline recenter |
| `adjust-font-baseline` | MetricModifier | 0 | baseline delta |
| `alpha-blending` | enum | `linear-corrected` (Linux) | native / linear / linear-corrected |
| `freetype-load-flags` | flags | `hinting,autohint,light` | hinting/autohint/light/monochrome/force-autohint |
| `font-thicken` | bool | false | inert on Linux (macOS-only in ghostty) |
| `font-thicken-strength` | u8 | 255 | inert on Linux |
| `adjust-cursor-thickness` | MetricModifier | 1 | cursor stroke thickness (px) |
| `adjust-cursor-height` | MetricModifier | 0 | cursor height delta + recenter |
| `adjust-underline-position` | MetricModifier | 0 | underline row delta |
| `cursor-style` | enum | `block` | block / bar / underline / hollow |

`MetricModifier` parses `N%` (percent, multiplier `1+N/100`, ≤−100% → 0) or `N`
(absolute px), matching ghostty `font/Metrics.zig:454-547`.

## Remaining work

- Sprite AA: replace 4×4 supersampling with ghostty z2d analytic coverage
  (closes box/block/braille/legacy edge pixels).
- Text AA: match ghostty FreeType coverage exactly (rasterizer build nuance).
- `window-padding-x/y` + grid anchoring (ghostty anchors at padding; kmshaunt
  centers) — intentionally not changed yet to avoid regressing the calibrated
  grid; add with a capture-verified anchor.