# Spike Q2: libspng 0.7.4 vs. libghostty-vt's PNG decode callback

Answers ROADMAP.md **Q2** (lines 313–315): *"Is libspng's API usable with the
allocator libghostty passes to the decode callback, or does the output need a
copy?"*

## Verdict

**Direct decode into the ghostty-owned buffer — no copy of the pixel data is
needed.** `spng_decode_image()` (one-shot mode) writes decoded pixels straight
into a caller-provided buffer, and `SPNG_FMT_RGBA8` is byte-identical to the
`GhosttySysImage` contract: 8-bit RGBA, row-major from the top-left, packed with
no padding. The recommended sequence allocates the output with
`ghostty_alloc(allocator, len)` (the allocator the callback receives), decodes
directly into it via `spng_decode_image(ctx, pixels, len, SPNG_FMT_RGBA8,
SPNG_DECODE_TRNS)`, and hands it back. **No temp buffer, no per-row conversion,
no swizzle, no full-image copy.** The only residual pixel copy lives inside
libghostty-vt itself (its image storage, `graphics_image.zig:711–713`), is
independent of any host callback, and cannot be avoided from the C API.

Verified empirically (this spike, ctypes against the nix-built
`libspng.so.0.7.4`): byte order R,G,B,A; top-down row order; 16-bit → 8-bit
scaling; paletted and truecolor `tRNS` handling; Adam7 deinterlace; image-limit
enforcement. See [Verification](#verification).

**Known format caveat (the one real "copy" decision):** `tRNS` transparency is
opt-in in libspng 0.7 (`SPNG_DECODE_TRNS = 1`). With flags `0` a PNG-with-tRNS
transparent pixel decodes to alpha 255 (opaque) — empirically confirmed. Pass
`SPNG_DECODE_TRNS` to match ghostty's reference behavior (wuffs applies tRNS).
Do **not** pass `SPNG_DECODE_GAMMA` (ghostty's decoder ignores gAMA; the C API
contract says plain RGBA).

---

## 1. What the ghostty callback hands you (and what it expects)

### Callback typedef — `include/ghostty/vt/sys.h:177–182`

```c
typedef bool (*GhosttySysDecodePngFn)(
    void* userdata,
    const GhosttyAllocator* allocator,   /* the ONLY allocator for output pixels */
    const uint8_t* data,                 /* raw PNG bytes */
    size_t data_len,
    GhosttySysImage* out);               /* zeroed by the library before the call */
```

Installed process-globally at startup, before any thread uses the library
(`sys.h:22–25`):

```c
ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, (const void*)&decode_png);   /* sys.h:229, 281–282 */
```

Passing NULL clears it; without it, PNG image formats are rejected
(`graphics_image.zig:160–164`, `sys.zig:18–20` — the shipped `lib` artifact
defaults `decode_png` to `null`).

### Output struct — `sys.h:43–73`

```c
typedef struct {
    uint32_t width;
    uint32_t height;
    uint8_t* data;      /* must be allocated with the callback's allocator */
    size_t data_len;    /* must equal the size requested from the allocator */
} GhosttySysImage;
```

Pixel layout contract (`sys.h:46–48`): **8-bit RGBA, four bytes per pixel, row
by row starting at the top-left, no padding between rows → exactly
`width * height * 4` bytes.**

### Memory / ownership / allocator

- Allocate the pixel buffer only via `ghostty_alloc(allocator, len)`
  (`allocator.h:237`) and free with `ghostty_free(allocator, ptr, len)`
  (`allocator.h:259`). Dereferencing the `GhosttyAllocator` vtable is
  unsupported (`sys.h:165–166`).
- The allocator handed to the callback is a `LimitedAllocator` capped at
  `max_size = 400 MB` per image (`graphics_image.zig:22–23, 690–691`).
  `ghostty_alloc()` returns NULL above the cap → the contract requires treating
  NULL as failure (`sys.h:130–132`).
- **Success:** the library takes ownership of `out->data` and frees it with the
  same allocator (`sys.h:122–128`). `out` is zeroed before the call
  (`sys.h:139–152`).
- **Failure:** the callback must free anything it allocated and return false;
  `out` is not read (`sys.h:134–137`).
- Callback plumbing: the Zig wrapper (`c/sys.zig:99–116`) wraps the zig
  allocator as `CAllocator` (`c/sys.zig:105`), passes a zeroed `GhosttySysImage`
  (`c/sys.zig:112`), and maps `false` / NULL `data` to `error.InvalidData`
  (`c/sys.zig:113, 115`). The call site `decodePng` (`graphics_image.zig:684–713`)
  then checks `result.data.len > max_size` (`:704–707`) and copies the pixels
  into the terminal's own storage (`.ensureUnusedCapacity` + `.appendSlice`,
  `:711–713`) — that internal host copy is unavoidable and free for Q2.

### Where this is documented

`guide-images.html`, section **"Decoding PNGs"** (`guide-images-png` anchor):
*"We don't ship a PNG decoder. You bring your own… Pixels are 8-bit RGBA, row by
row from the top-left, with no padding, so a complete image is `width * height *
4` bytes. Allocate them with `ghostty_alloc()` and the allocator we pass you,
and return true. We own the buffer after that. `data_len` must be the exact size
requested from the allocator."* (docs zip `libghostty-vt-1.0.1-docs`,
`guide-images.html`; worked example `c-vt-kitty-graphics/src/main.c`, installed
via `GHOSTTY_SYS_OPT_USERDATA`/`GHOSTTY_SYS_OPT_DECODE_PNG`).

---

## 2. Relevant libspng 0.7.4 API (nixpkgs `libspng-0.7.4-dev`)

All from `include/spng/spng.h` (dev output
`/nix/store/dmdn1vca06q4jig9f1rk7bva167nbawy-libspng-0.7.4-dev`); semantics and
line refs to the v0.7.4 source `spng/spng.c`.

```c
/* Context */
spng_ctx *spng_ctx_new(int flags);                                  /* spng.h:442 */
/*   flags 0 = decode ctx; SPNG_CTX_IGNORE_ADLER32=1, SPNG_CTX_ENCODER=2 (spng.h:186–187)
     Default allocator = malloc/realloc/calloc/free (spng.c:4878–4889). */
void spng_ctx_free(spng_ctx *ctx);                                  /* spng.h:444 */

/* One-shot input; can be set only once per ctx (SPNG_EBUF_SET otherwise) */
int spng_set_png_buffer(spng_ctx *ctx, const void *buf, size_t size); /* spng.h:446, spng.c:5048–5065 */

/* Hardening */
int spng_set_image_limits(spng_ctx *ctx, uint32_t width, uint32_t height); /* spng.h:452, spng.c:5138–5148 */
int spng_set_chunk_limits(spng_ctx *ctx, size_t chunk_size, size_t cache_size); /* spng.h:455, spng.c:5160–5168 */

/* Query (each triggers IHDR parse on demand: read_chunks(ctx,1), idempotent; spng.c:3125, 5360–5378) */
int spng_get_ihdr(spng_ctx *ctx, struct spng_ihdr *ihdr);           /* spng.h:484 */
int spng_decoded_image_size(spng_ctx *ctx, int fmt, size_t *len);   /* spng.h:463 */

/* One-shot decode into a caller buffer; once per ctx
   out==NULL → 1; len < image_size → SPNG_EBUFSIZ (spng.c:3640–3642) */
int spng_decode_image(spng_ctx *ctx, void *out, size_t len, int fmt, int flags); /* spng.h:466, spng.c:3618 */

const char *spng_strerror(int err);                                 /* spng.h:530 */
```

Formats (spng.h:167–182): `SPNG_FMT_RGBA8 = 1` — *"Channels are always in
byte-order"*, packed, host-endian. Other values: RGBA16=2, RGB8=4, GA8/G8,
`SPNG_FMT_PNG`=256, `SPNG_FMT_RAW`=512.

Decode flags (spng.h:190–199): `SPNG_DECODE_TRNS = 1` (apply tRNS; opt-in),
`SPNG_DECODE_GAMMA = 2`, `SPNG_DECODE_PROGRESSIVE = 256`.

Errors (spng.h:33–79): `SPNG_OK = 0`, positive on failure —
`SPNG_EUSER_WIDTH = 7`, `SPNG_EUSER_HEIGHT = 8`, `SPNG_ECRC`-family (e.g.
`SPNG_ECHUNK_CRC = 18`), `SPNG_EMEM = 2`, `SPNG_EBUFSIZ = 66`, `SPNG_EOVERFLOW = 3`.

Progressive decode exists (`spng_decode_scanline`/`spng_decode_row`,
spng.h:469–470) but is **not needed**: one-shot `spng_decode_image` writes every
row itself, top-down, at `out + row_num * image_width` (spng.c:3998–4002), and
deinterlaces Adam7 and scales 16-bit → 8-bit internally (verified).

---

## 3. Mapping: ghostty expected layout vs. spng output

| Aspect | Ghostty `GhosttySysImage` | libspng `SPNG_FMT_RGBA8` | Match? |
|---|---|---|---|
| Pixel order | 8-bit RGBA bytes `[R,G,B,A]` (sys.h:46) | byte-order RGBA (spng.h:167, 170) | **Yes** (verified) |
| Alpha | straight RGBA (premultiply happens at blend time, if at all) | straight; tRNS opt-in via `SPNG_DECODE_TRNS` | **Yes, if flag passed** |
| Row order | top-left first, row by row (sys.h:47) | scanline 0 = top; written at `out + row_num*image_width` (spng.c:3999) | **Yes** (verified) |
| Stride | `width * 4`, no padding (sys.h:47–48) | `image_width = width * 4`, packed | **Yes** (verified: 2×2 → 16 bytes) |
| Total size | `width * height * 4` | `spng_decoded_image_size()` == same | **Yes** |
| Alignment | none stated; `ghostty_alloc` handles it | none required (byte writes) | **Yes** |
| Color conversion | n/a (decoder must deliver RGBA) | paletted/gray/gray+alpha/16-bit/Adam7 → RGBA8 | spng does it (verified) |
| Ownership | callback allocates with passed allocator; library frees on true; callback frees on false (sys.h:50–52, 122–137) | spng never owns `out` | Compatible |

**Conclusion of the comparison:** the formats are identical; only the allocator
differs, and it is used exactly *because* libspng lets the caller supply the
output buffer. The output does **not** need a copy. In fact the only allocation
in the whole callback is the pixel buffer itself (`ghostty_alloc`), plus
libspng's transient internal state (ctx + 2 bounded scanline buffers + zlib
window + ancillary-chunk cache capped by `spng_set_chunk_limits`) which is
malloc-backed and irrelevant to the ghostty allocator.

**Do not** try `spng_ctx_new2()` with the ghostty allocator: the
`GhosttyAllocator` vtable is opaque by contract (sys.h:165–166) and exposes no
`calloc`/`realloc` equivalents; spng's internal allocations are small and
bounded, so keeping them on libc malloc is correct.

---

## 4. Recommended call sequence (real signatures)

```c
#include <ghostty/vt.h>   /* GHOSTTY_SYS_OPT_DECODE_PNG, GhosttyAllocator, GhosttySysImage, ghostty_alloc/free */
#include <spng.h>

static bool decode_png(
    void* userdata,
    const GhosttyAllocator* allocator,
    const uint8_t* data,
    size_t data_len,
    GhosttySysImage* out)
{
    (void)userdata;

    spng_ctx* ctx = spng_ctx_new(0);              /* decode ctx, malloc-backed */
    if (ctx == NULL) return false;

    /* Hardening (decoder runs as root: R3) — place before any parse:
       IHDR is parsed lazily by the first spng_get_ihdr/decoded_image_size. */
    spng_set_image_limits(ctx, 10000, 10000);     /* mirror terminal max_dimension */
    spng_set_chunk_limits(ctx, 8u << 20, 32u << 20); /* cap chunk + ancillary cache */

    int rc = spng_set_png_buffer(ctx, data, data_len);   /* SPNG_EBUF_SET if ctx reused */
    struct spng_ihdr ihdr;
    size_t out_len = 0;
    uint8_t* pixels = NULL;

    if (rc == 0) rc = spng_get_ihdr(ctx, &ihdr);            /* parse IHDR; enforces limits */
    if (rc == 0) rc = spng_decoded_image_size(ctx, SPNG_FMT_RGBA8, &out_len);
    if (rc == 0 && out_len > 400u * 1024 * 1024) rc = SPNG_EOVERFLOW; /* belt & braces */
    if (rc == 0)
    {
        pixels = ghostty_alloc(allocator, out_len);         /* NULL if over allocator limit */
        if (pixels == NULL) rc = SPNG_EMEM;
    }
    if (rc == 0)
        rc = spng_decode_image(ctx, pixels, out_len, SPNG_FMT_RGBA8,
                               SPNG_DECODE_TRNS);           /* TRNS: keep tRNS transparency */

    spng_ctx_free(ctx);                                     /* one-shot: ctx used once */

    if (rc != 0)
    {
        if (pixels != NULL) ghostty_free(allocator, pixels, out_len);
        return false;                                       /* library ignores out */
    }

    out->width    = ihdr.width;
    out->height   = ihdr.height;
    out->data     = pixels;    /* library takes ownership; frees via same allocator */
    out->data_len = out_len;   /* exact size requested from the allocator (sys.h:68–70) */
    return true;
}
```

Notes:

- **ctx lifetime:** `spng_decode_image()` can be called only once per context
  (state machine ends at `SPNG_STATE_EOI`; libspng docs, `docs/decode.md`).
  Create/free a ctx per callback invocation. This also makes the callback
  thread-safe (spng contexts share no mutable globals) — the callback may be
  invoked from any of the terminal's threads.
- **Size ordering:** `spng_get_ihdr` and `spng_decoded_image_size` each invoke
  the (idempotent) IHDR parse (`read_chunks(ctx, 1)`, spng.c:3125) — either
  order works, and the later `spng_decode_image` resumes from where the parse
  stopped (`read_chunks(ctx, 0)` continues through IDAT). Empirically verified.
- **Allocation vs. limits:** `max_size = 400 MB` (graphics_image.zig:22–23) and
  `max_dimension = 10000` (graphics_image.zig:20). 10000×10000×4 = 400,000,000 <
  419,430,400, so a legal full-size image fits under the allocator cap;
  `ghostty_alloc` NULL and the `out_len > max_size` guard cover hostile inputs.
- **No other buffers:** the only ghostty-allocator-backed memory is the pixel
  buffer. libspng's internals (ctx, two scanline buffers of `scanline_width+32`
  bytes, optional interlaced row buffer, zlib state, ancillary chunk cache) come
  from the C allocator and are bounded by the chunk limits above.

---

## 5. Pixel-format & stride mapping (summary)

```text
ghostty RGBA8  = [R G B A] per pixel, top-left → bottom-right, stride w*4, no padding
spng RGBA8     = [R G B A] per pixel ("channels are always in byte-order"),
                 scanline 0 is the top row, stride = image_width = w*4, no padding
                 → identical; verified byte-for-byte on a 2×2 image
```

Premultiplied alpha: neither side — ghostty's contract is plain 8-bit RGBA and
the terminal performs alpha blending (`rgbaSrcOver`) on stored images.

---

## 6. Hardening knobs for R3 (root-privilege PNG parsing)

libspng's own guidance for untrusted files (`docs/decode.md`, "Decoding
untrusted files"): *set image limits, check the decoded size against a constant,
set chunk limits.*

| Knob | Call | Effect / error |
|---|---|---|
| Dimension cap | `spng_set_image_limits(ctx, 10000, 10000)` | Rejects at IHDR parse before any scanline work: `SPNG_EUSER_WIDTH`/`SPNG_EUSER_HEIGHT` (spng.c:2030–2036; errno 7/8). Defaults: unlimited (`spng_u32max`, spng.c:4906–4907). |
| Decoded size check | `spng_decoded_image_size()` then compare with cap | No buffer allocated before the check; mirrors 400 MB terminal cap; `ghostty_alloc` NULL is the backstop (spng.c:5360–5368). |
| Chunk size / cache | `spng_set_chunk_limits(ctx, chunk_size, cache_size)` | Caps per-chunk size and ancillary-chunk cache (decompression-bomb / text-chunk DoS): `SPNG_ECHUNK_LIMITS`. Defaults: chunk `spng_u32max`, cache `SIZE_MAX` (spng.c:4909–4910). |
| Chunk count | `spng_set_option(ctx, SPNG_CHUNK_COUNT_LIMIT, n)` | Default `SPNG_MAX_CHUNK_COUNT = 1000` (spng.c:32, 4911); exceed treated as OOM (docs/decode.md). |
| Checksums | don't pass `SPNG_CTX_IGNORE_ADLER32` | Keep DEFLATE-Adler32 and CRC verification (critical chunks hard-fail, ancillary discarded on bad CRC — libspng default since 0.6.2). 
| Signature | built-in | 8-byte PNG signature validated (`SPNG_ESIGNATURE`). |

Defense in depth: the terminal already rejects `width|height > 10000` and
`data_size > max_size` before decoding (graphics_image.zig:304–307, 330, 554–556);
the spng-level limits protect the decoder process itself (which runs as root
today, per R3), and `SPNG_DECODE_TRNS`/CRC handling keep pixel fidelity and
integrity. Explicit dimension validation (`spng_get_ihdr` → `bit_depth == 8 || 16`,
`color_type ∈ {0,2,3,4,6}`) can further reduce the attack surface before
allocations; RGBA8 conversion handles all of them.

---

## 7. Citations (file:line)

libghostty-vt 1.0.1 — tarball
`https://release.files.ghostty.org/libghostty-vt/1.0.1/libghostty-vt-1.0.1.tar.gz`
(sha256 `333dfce97641ef9b536bb9e08907ad86abaaada50e8f7417b70d9284adef37aa`):

- `include/ghostty/vt/sys.h:43–73` — `GhosttySysImage` (+ pixel layout 46–48, data_len contract 68–70)
- `include/ghostty/vt/sys.h:122–137` — success/failure ownership; 130–132 allocator limit → NULL
- `include/ghostty/vt/sys.h:139–152` — `out` zeroed before call
- `include/ghostty/vt/sys.h:165–166` — allocator usable only via `ghostty_alloc`/`ghostty_free`
- `include/ghostty/vt/sys.h:177–182` — `GhosttySysDecodePngFn` typedef
- `include/ghostty/vt/sys.h:229` — `GHOSTTY_SYS_OPT_DECODE_PNG = 2`; `:281–282` — `ghostty_sys_set`
- `include/ghostty/vt/allocator.h:210` — `GhosttyAllocator`; `:237` — `ghostty_alloc`; `:259` — `ghostty_free`
- `src/terminal/sys.zig:17–28` — zig `DecodePngFn`/`Image`; `:18–20` — lib artifact defaults to null
- `src/terminal/c/sys.zig:10–15` — C `GhosttySysImage` extern; `:18–24` — C `DecodePngFn`; `:99–116` — wrapper (zeroed out, `fromZig`, false→`InvalidData`)
- `src/terminal/kitty/graphics_image.zig:19–23` — `max_dimension = 10000`, `max_size = 400 MB`
- `src/terminal/kitty/graphics_image.zig:684–713` — `decodePng` (LimitedAllocator 690–691, size check 704–707, internal copy 711–713)
- docs zip `libghostty-vt-1.0.1-docs`: `guide-images.html` §"Decoding PNGs" (`guide-images-png`); example `c-vt-kitty-graphics_2src_2main_8c-example.html`

libspng 0.7.4 — nixpkgs dev output
`/nix/store/dmdn1vca06q4jig9f1rk7bva167nbawy-libspng-0.7.4-dev/include/spng.h`,
source tag `v0.7.4` (`spng/spng.c`):

- `spng.h:33–79` — `enum spng_errno` (`SPNG_OK=0`, `SPNG_EUSER_WIDTH=7`, `SPNG_EUSER_HEIGHT=8`)
- `spng.h:167–182` — `enum spng_format` (`SPNG_FMT_RGBA8 = 1` at 170; "Channels are always in byte-order" at 167)
- `spng.h:185–188` — ctx flags (`SPNG_CTX_IGNORE_ADLER32`, `SPNG_CTX_ENCODER`)
- `spng.h:190–199` — decode flags (`SPNG_DECODE_TRNS = 1` at 196, `SPNG_DECODE_GAMMA = 2`, `SPNG_DECODE_PROGRESSIVE = 256`)
- `spng.h:221–227` — `struct spng_ihdr`
- `spng.h:442, 444, 446, 452, 455, 463, 466, 484, 530` — `spng_ctx_new`, `spng_ctx_free`, `spng_set_png_buffer`, `spng_set_image_limits`, `spng_set_chunk_limits`, `spng_decoded_image_size`, `spng_decode_image`, `spng_get_ihdr`, `spng_strerror`
- `spng.c:32` — `SPNG_MAX_CHUNK_COUNT (1000)`
- `spng.c:2030–2036` — `check_ihdr` user limits → `SPNG_EUSER_WIDTH/HEIGHT`
- `spng.c:3125` — IHDR-only parse (`read_chunks(ctx, 1)`) stops, resumable
- `spng.c:3618` — `spng_decode_image`; `:3640–3642` — `out==NULL`/`len < image_size` → `SPNG_EBUFSIZ`
- `spng.c:3998–4002` — one-shot row write `out + row_num * image_width` (top-down)
- `spng.c:4878–4889` — `spng_ctx_new` default malloc allocator
- `spng.c:4906–4911` — default limits (unbounded, chunk count 1000)
- `spng.c:5048–5065` — `spng_set_png_buffer` (once per ctx)
- `spng.c:5138–5148` — `spng_set_image_limits`; `:5160–5168` — `spng_set_chunk_limits`
- `spng.c:5360–5368` — `spng_decoded_image_size`; `:5375–5378` — `spng_get_ihdr`
- `docs/decode.md` — untrusted-file guidance; "This function can only be called once per context"; `SPNG_DECODE_TRNS` opt-in

## Verification

Empirical, not assumed (this spike, ctypes against the nix-built
`/nix/store/bq7yl3mkfj2p9ycdya4c9qrsqdqgarbw-libspng-0.7.4/lib/libspng.so.0.7.4`,
sequence `set_png_buffer → decoded_image_size → decode_image` on one ctx):

1. 2×2 truecolor → exact bytes `ff0000ff 00ff00ff 0000ffff ffffffff` (R,G,B,A; rows top-down; 16 bytes) ✓
2. truecolor + tRNS: flags `0` → alpha 255 (opaque); `SPNG_DECODE_TRNS` → alpha 0 ✓
3. paletted + tRNS: per-pixel alpha honored ✓
4. 16-bit → 8-bit scaling (`0xFFFF→0xFF`, `0x8000→0x80`) ✓
5. `spng_set_image_limits(4,3)` on 4×4 → `SPNG_EUSER_HEIGHT` (errno 8) ✓
6. Adam7-interlaced 4×4 (programmatically generated passes) → exact full RGBA8 image ✓