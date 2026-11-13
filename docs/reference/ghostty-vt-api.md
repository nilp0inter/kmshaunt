# libghostty-vt 1.0.1 C API reference

Reference for `src/vt.zig` (ROADMAP D1), distilled from the 1.0.1 release
tarball and Doxygen docs. A Zig engineer should be able to write the wrapper
from this document alone for the common paths; the effects callbacks and the
render cell struct are complete here.

Provenance (all checksums verified at download time):

- Tarball: `https://release.files.ghostty.org/libghostty-vt/1.0.1/libghostty-vt-1.0.1.tar.gz`
  sha256 `333dfce97641ef9b536bb9e08907ad86abaaada50e8f7417b70d9284adef37aa`
- Docs: `https://release.files.ghostty.org/libghostty-vt/1.0.1/libghostty-vt-1.0.1-docs.zip`
- The library is written in Zig and exposed through C. The C ABI is stable
  from 1.0 (`stability` docs page). Linking: `zig fetch --save=ghostty <url>`,
  then `exe.linkLibrary(dep.artifact("ghostty-vt"))`; requires Zig exactly
  0.17. For the wrapper, `b.addTranslateC` of `ghostty/vt.h` and declare the
  symbols that are used.

**Citation convention.** Every signature cites the header and line where it is
declared, relative to `include/ghostty/vt/` inside the tarball (the only
include outside that directory is the umbrella `include/ghostty/vt.h`, which
has no declarations of its own; the C symbols below are all from the
`ghostty-vt` library artifact). Line numbers match the 1.0.1 tarball.

**Header layout.** `vt.h` is an umbrella that includes, in order: version.h,
types.h, allocator.h, build_info.h, color.h, color_scheme.h, device.h,
focus.h, formatter.h, render.h, terminal.h, grid_ref.h, grid_ref_tracked.h,
io.h, osc.h, sgr.h, style.h, sys.h, key.h, kitty_graphics.h, modes.h, mouse.h,
paste.h, point.h, screen.h, search.h, selection.h, size_report.h, snapshot.h,
unicode.h, wasm.h.

---

## 0. Conventions that apply everywhere

### 0.1 `GhosttyResult` — every fallible call returns one (types.h:143)

```c
typedef enum {
  GHOSTTY_SUCCESS = 0,
  GHOSTTY_OUT_OF_MEMORY = -1,
  GHOSTTY_INVALID_VALUE = -2,  /* NULL where a value is needed, out-of-range enum, wrong size */
  GHOSTTY_OUT_OF_SPACE = -3,   /* caller buffer too small */
  GHOSTTY_NO_VALUE = -4,       /* the requested value has no value right now */
  GHOSTTY_IO_ERROR = -5,
  GHOSTTY_LIMIT_EXCEEDED = -6,
  GHOSTTY_REJECTED = -7,       /* paste safety check failed; nothing was done */
  GHOSTTY_UNSUPPORTED = -8,    /* key/feature/option unknown to this build or newer-than-library */
} GhosttyResult;
```
`result < 0` tests for any error. `GHOSTTY_UNSUPPORTED` from keyed get/set
means the library predates the key (or an optional feature was compiled out);
check it to degrade gracefully.

### 0.2 Sized structs and `GHOSTTY_INIT_SIZED` (types.h:558, types.h:601)

Several structs start with a `size_t size` field so the library can detect the
version of the struct the caller compiled against. Initialize them with
`GHOSTTY_INIT_SIZED(T)` (a compound literal, `((T){ .size = sizeof(T) })`) or,
from a language binding that cannot run macros, `ghostty_sized_init(&s, sizeof(s))`
(types.h:601, `GHOSTTY_API void ghostty_sized_init(void* ptr, size_t size)`).
Passing a struct whose `size` is smaller than the library's base layout yields
`GHOSTTY_INVALID_VALUE`.

Sized structs in this API: `GhosttyTerminalWriteStop`, `GhosttyTerminalMemoryUsage`,
`GhosttyClipboardWriteReply`, `GhosttyClipboardReadReply`, `GhosttyRenderStateCursor`,
`GhosttyRenderStateColors`, `GhosttyRenderStateRowSelection`,
`GhosttyMouseEncoderSize`, `GhosttyPaste`, `GhosttyKittyGraphicsPlacementRenderInfo`,
`GhosttyTerminalSelectWordOptions`, `GhosttyTerminalSelectWordBetweenOptions`,
`GhosttyTerminalSelectLineOptions`.

### 0.3 Borrowed memory

- `GhosttyString` (types.h:439) = `{ const uint8_t* ptr; size_t len; }` — a
  borrowed byte string; empty strings from the library have a non-NULL pointer.
  Strings passed to callbacks are only valid until the callback returns; copy
  what you keep.
- `GhosttyBuffer` (types.h:455) = `{ uint8_t* ptr; size_t cap; size_t len; }`
  — caller-provided output buffer. `ptr` may be NULL with `cap` 0 to query the
  required size; on `GHOSTTY_OUT_OF_SPACE`, `len` holds the required capacity.
- `GhosttyCodepoints` (types.h:494) = `{ const uint32_t* ptr; size_t len; }` —
  borrowed list of Unicode scalar values.
- `GhosttyCodepointBuffer` (types.h:518) = `{ uint32_t* ptr; size_t cap; size_t len; }`
  — caller-provided codepoint sink; `len` is always set to the total count
  even when only `cap` fit (then the call returns `GHOSTTY_OUT_OF_SPACE`).
- Things the library allocates and hands you for you to free are always freed
  with `ghostty_free()` + the same allocator; never C `free()`. See §1.4.

### 0.4 Threading and reentrancy

- The terminal is **not thread-safe**: serialize `ghostty_terminal_vt_write*`,
  `ghostty_terminal_set`, `ghostty_terminal_resize`, `ghostty_terminal_reset`,
  render-state updates, searches, selection gestures, and compression on the
  same terminal.
- Callbacks run **synchronously inside** `ghostty_terminal_vt_write()` /
  `ghostty_terminal_vt_write_until()`. A callback MUST NOT call a VT write
  function on the same terminal (no reentrancy; nothing checks it, bytes are
  parsed into the middle of the sequence that fired you). Callbacks should be
  fast and non-blocking; while a callback runs, the rest of the VT stream is
  stalled.
- Exceptions by design: `ghostty_terminal_continuation_*` reads, `ghostty_search_tick`
  and `ghostty_search_get` never touch the terminal and are safe from other
  threads; the render state **end** phase only touches render-state memory and
  is safe while the terminal is modified (use the two-phase update, §4.3).
- `ghostty_sys_set()` is process-global and **not thread-safe**: call it once
  at startup before any other library use.
- Rendering docs maintain that libghostty-vt "never crashes your program by
  design, given valid use"; check every `GhosttyResult`.

---

## 1. Library / config init

### 1.1 Version macros (version.h:35, 38, 41, 60, 77)

```c
#define GHOSTTY_VT_VERSION_MAJOR 1        /* version.h:35 */
#define GHOSTTY_VT_VERSION_MINOR 0        /* version.h:38 */
#define GHOSTTY_VT_VERSION_PATCH 1        /* version.h:41 */
#define GHOSTTY_VT_VERSION "1.0.1"        /* version.h:60 */
#define GHOSTTY_VT_VERSION_AT_LEAST(maj, min, pat) ...  /* version.h:77, usable in #if */
```

### 1.2 Build info (build_info.h)

```c
typedef enum {
  GHOSTTY_OPTIMIZE_DEBUG = 0, GHOSTTY_OPTIMIZE_RELEASE_SAFE = 1,
  GHOSTTY_OPTIMIZE_RELEASE_SMALL = 2, GHOSTTY_OPTIMIZE_RELEASE_FAST = 3,
  ...
} GhosttyOptimizeMode;                               /* build_info.h:55 */

typedef enum {
  GHOSTTY_BUILD_INFO_INVALID = 0,
  GHOSTTY_BUILD_INFO_SIMD = 1,            /* out: bool* */
  GHOSTTY_BUILD_INFO_KITTY_GRAPHICS = 2,  /* out: bool* */
  GHOSTTY_BUILD_INFO_TMUX_CONTROL_MODE = 3,
  GHOSTTY_BUILD_INFO_OPTIMIZE = 4,        /* out: GhosttyOptimizeMode* */
  GHOSTTY_BUILD_INFO_VERSION_STRING = 5,  /* out: GhosttyString* */
  GHOSTTY_BUILD_INFO_VERSION_MAJOR = 6,   /* out: size_t* */
  GHOSTTY_BUILD_INFO_VERSION_MINOR = 7,
  GHOSTTY_BUILD_INFO_VERSION_PATCH = 8,
  GHOSTTY_BUILD_INFO_VERSION_PRE = 9,     /* out: GhosttyString* */
  GHOSTTY_BUILD_INFO_VERSION_BUILD = 10,
  GHOSTTY_BUILD_INFO_FEATURE_SNAPSHOT = 11, GHOSTTY_BUILD_INFO_FEATURE_FORMATTER = 12,
  GHOSTTY_BUILD_INFO_FEATURE_SELECTION = 13, GHOSTTY_BUILD_INFO_FEATURE_SEARCH = 14,
  GHOSTTY_BUILD_INFO_FEATURE_RENDER_STATE = 15, GHOSTTY_BUILD_INFO_FEATURE_INPUT_ENCODE = 16,
  GHOSTTY_BUILD_INFO_FEATURE_COLOR = 17, GHOSTTY_BUILD_INFO_FEATURE_GRID_INTROSPECTION = 18,
  GHOSTTY_BUILD_INFO_FEATURE_GLYPH_PROTOCOL = 19,
} GhosttyBuildInfo;                                   /* build_info.h:68 */

GHOSTTY_API GhosttyResult ghostty_build_info(GhosttyBuildInfo data, void *out);  /* build_info.h:236 */
GHOSTTY_API const char *ghostty_version(void);   /* build_info.h:264, library-owned, never free */
```
`ghostty_version()` is the *loaded* library's version ("1.0.1"; dev builds have
`-dev+hash`); the macros describe the headers compiled against. Same major
version + library >= headers is the compatibility rule.

### 1.3 Sys options — process-global hooks, incl. the PNG decoder (sys.h)

The sys interface is a set of process-global function pointers for things the
library cannot do itself. Set them once at startup with `ghostty_sys_set()`,
**before any other thread uses the library**. Passing NULL clears an
implementation and disables the feature. Option identifiers (sys.h:210):

```c
typedef enum {
  GHOSTTY_SYS_OPT_INVALID = 0,
  GHOSTTY_SYS_OPT_USERDATA = 1,        /* input: void* (or NULL) */
  GHOSTTY_SYS_OPT_DECODE_PNG = 2,      /* input: GhosttySysDecodePngFn (or NULL) */
  GHOSTTY_SYS_OPT_LOG = 3,             /* input: GhosttySysLogFn (or NULL) */
  GHOSTTY_SYS_OPT_RANDOM_SECURE = 4,   /* input: GhosttySysRandomSecureFn (or NULL) */
} GhosttySysOption;

GHOSTTY_API GhosttyResult ghostty_sys_set(GhosttySysOption option, const void* value);  /* sys.h:286 */
```

**PNG decode hook** (the one kmshaunt D4 wires to libspng; without it PNG
image data is rejected by the Kitty protocol):

```c
typedef struct {
  uint32_t width;          /* image width in pixels */
  uint32_t height;         /* image height in pixels */
  uint8_t* data;           /* RGBA, 4 bytes/pixel, rows top-left first, no padding */
  size_t data_len;         /* must equal the allocation size requested (used to free) */
} GhosttySysImage;                                         /* sys.h:54 */

typedef bool (*GhosttySysDecodePngFn)(
    void* userdata,                    /* the value set via GHOSTTY_SYS_OPT_USERDATA */
    const GhosttyAllocator* allocator, /* allocate `out->data` with this */
    const uint8_t* data, size_t data_len,
    GhosttySysImage* out);             /* zeroed by the library before the call */
                                                                  /* sys.h:169 */
```
Contract: on success, allocate `out->data` with `ghostty_alloc(allocator, n)`
and return true — the library then owns it and frees it with `ghostty_free()`
+ the same allocator (use that allocator only through `ghostty_alloc` /
`ghostty_free`; never dereference its vtable). On failure free anything you
allocated and return false; the library rejects the image. `out` is
zero-initialized before the call, so `data == NULL` on return is treated as
failure. `GhosttySysImage` is frozen (a future format change introduces a new
callback typedef, never new fields here).

**Log callback** (sys.h:99): `typedef void (*GhosttySysLogFn)(void* userdata, GhosttySysLogLevel level, const uint8_t* scope, size_t scope_len, const uint8_t* message, size_t message_len);`
with `GhosttySysLogLevel { ERROR=0, WARNING=1, INFO=2, DEBUG=3 }` (sys.h:78).
`scope` is e.g. "osc", "kitty"; scope_len 0 = default scope. Without a
callback, logs are discarded; use the built-in
`ghostty_sys_log_stderr` (sys.h:302) to print `[level](scope): message` to
stderr. Release builds compile debug-level messages out entirely.

**Secure random** (sys.h:195):
`typedef bool (*GhosttySysRandomSecureFn)(void* userdata, uint8_t* buf, size_t len);`
CSPRNG only (getrandom/arc4random_buf/CNG) — used for secrets. Defaults to the
platform source; wasm32-freestanding has none and paste events fail with
`GHOSTTY_IO_ERROR` until this is set.

### 1.4 Allocator injection (allocator.h)

Every `const GhosttyAllocator*` parameter accepts NULL = a default allocator;
most programs never need more. Two structures, matching Zig's
`std.mem.Allocator`:

```c
typedef void* (*GhosttyAllocatorAllocFn)(void *ctx, size_t len, uint8_t alignment, uintptr_t ret_addr);  /* required */
typedef bool  (*GhosttyAllocatorResizeFn)(void *ctx, void *memory, size_t memory_len, uint8_t alignment, size_t new_len, uintptr_t ret_addr); /* optional */
typedef void* (*GhosttyAllocatorRemapFn)(void *ctx, void *memory, size_t memory_len, uint8_t alignment, size_t new_len, uintptr_t ret_addr);  /* optional */
typedef void  (*GhosttyAllocatorFreeFn)(void *ctx, void *memory, size_t memory_len, uint8_t alignment, uintptr_t ret_addr);  /* required */

typedef struct {
  GhosttyAllocatorAllocFn alloc;
  GhosttyAllocatorResizeFn resize;
  GhosttyAllocatorRemapFn remap;
  GhosttyAllocatorFreeFn free;
  void* reserved[4];       /* must be NULL; debug builds abort if not */
} GhosttyAllocatorVtable;                        /* allocator.h:173 */

typedef struct {
  void *ctx;                      /* passed unchanged to every vtable fn */
  const GhosttyAllocatorVtable *vtable;
} GhosttyAllocator;                              /* allocator.h:207 */
```
`alignment` is `log2(bytes)` of the required alignment, stable across
resize/free of a block. The library does not copy the allocator; it must
outlive everything allocated with it. Zero-initialize the vtable before
filling fields.

```c
GHOSTTY_API uint8_t* ghostty_alloc(const GhosttyAllocator* allocator, size_t len);   /* allocator.h:237 */
GHOSTTY_API void ghostty_free(const GhosttyAllocator* allocator, uint8_t* ptr, size_t len);  /* allocator.h:259 */
```
`ghostty_alloc`/`ghostty_free` are how you free every buffer the library
returns (formatter output, snapshot continuation, …) — never plain `free()`.
`ghostty_free(NULL)` is a no-op, but the `len` must match the allocation.

---

## 2. Terminal: create, destroy, resize, feed, read back

### 2.1 Lifecycle (terminal.h)

```c
GHOSTTY_API GhosttyResult ghostty_terminal_new(const GhosttyAllocator* allocator,
                                               GhosttyTerminal* terminal,
                                               uint16_t cols, uint16_t rows);   /* terminal.h:3114 */
```
`cols`/`rows` must be > 0. The terminal starts with sensible defaults (see
option table §3.1); configure with `ghostty_terminal_set()` before use.

```c
GHOSTTY_API void ghostty_terminal_free(GhosttyTerminal terminal);   /* terminal.h:3129, NULL ok */
GHOSTTY_API void ghostty_terminal_reset(GhosttyTerminal terminal);  /* terminal.h:3145, NULL ok */
```
`reset` = full RIS (`ESC c`): clears screen+scrollback, restores all modes to
their reset defaults, clears title and pwd; dimensions preserved. Ends a
render hold (`RENDER_HOLD` fires with `held=false`). Progress/program-status
records are cleared (their callbacks fire first, then `RESET`).

```c
GHOSTTY_API GhosttyResult ghostty_terminal_resize(GhosttyTerminal terminal,
                                                  uint16_t cols, uint16_t rows,
                                                  uint32_t cell_width_px, uint32_t cell_height_px);  /* terminal.h:3172 */
```

**Size-change propagation** (documented behavior):
- Grid dims change; the primary screen **reflows** content (if wraparound mode
  is on), the alternate screen does **not** reflow.
- Pixel dims (`cols*cell_width_px`, `rows*cell_height_px`) are stored and used
  by image protocols and size reports; report them from your window state.
- Resize **disables synchronized output** (mode 2026) per spec — the
  `RENDER_HOLD` callback fires `held=false` if a hold was active.
- If mode 2048 (in-band size reports) is enabled, the terminal immediately
  emits a size report (through the `SIZE` callback → `WRITE_PTY`, see §8).
- `GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK` (default true) controls whether
  growing rows reveals scrollback. kmscon talks to a pty that keeps its own
  screen; leaving the default true matches a normal pty-based terminal.
- The render state picks the new size up on its next update; expect a full
  redraw after resize. Hosts resize after `SIGWINCH`/mode change (M1/M2).

### 2.2 Feeding bytes in (terminal.h)

```c
GHOSTTY_API void ghostty_terminal_vt_write(GhosttyTerminal terminal,
                                           const uint8_t* data, size_t len);   /* terminal.h:3259 */
```
Parrot pty-master reads straight in. Never fails; malformed input is skipped,
handled safely, and logged (it is assumed untrusted). Sequences and partial
UTF-8 may be split across calls. Writes that need a reply or have a side
effect are **silently ignored until the corresponding effect callback is
registered** (§8) — register `WRITE_PTY` before real programs run. C0 controls
must arrive as the pty emits them (pty line discipline turns `\n` into `\r\n`).

```c
GHOSTTY_API GhosttyResult ghostty_terminal_vt_write_until(
    GhosttyTerminal terminal, const uint8_t* data, size_t len,
    uint32_t boundaries,                /* GhosttyTerminalBoundary flags, nonzero */
    GhosttyTerminalWriteStop* out);     /* terminal.h:3307 */
```
Pauses at the first byte that reaches one of the requested boundaries; only
the consumed bytes are processed and only they fire callbacks. Pass the rest
next call; the terminal ends up identical to one big write. Useful for
interposing/forwarding APC/DCS/OSC strings (tmux control mode, kitty graphics)
and for waiting for ground before injecting your own sequences.

Boundary flags (`GhosttyTerminalBoundary`, terminal.h:204): `GROUND = 1<<0`,
`APC_START = 1<<1`, `APC_END = 1<<2`, `DCS_START = 1<<3`, `DCS_END = 1<<4`,
`OSC_START = 1<<5`, `OSC_END = 1<<6`. Stop record (sized struct, terminal.h:374):

```c
typedef struct {
  size_t size;              /* set via GHOSTTY_INIT_SIZED */
  size_t consumed;          /* input bytes consumed, incl. the boundary byte */
  uint32_t reached;         /* boundary flags reached (0 if none) */
  GhosttyTerminalStringKind kind;        /* APC | DCS | OSC (terminal.h:259) */
  GhosttyTerminalStringIntroducer introducer;  /* ESC | C1 (terminal.h:285) */
  GhosttyTerminalStringEnd end;          /* ST_ESC | ST_C1 | CANCELLED | ABORTED | BEL (terminal.h:310) */
  uint8_t byte;             /* the boundary byte */
} GhosttyTerminalWriteStop;
```
Returns `GHOSTTY_SUCCESS` when a boundary was reached, `GHOSTTY_NO_VALUE` when
all input was consumed without reaching one (`reached`=0). Each call resets
all fields except `size`. Special cases: BEL (End=BEL) still returns to
ground, so `GROUND` can be set together with `OSC_END`; a C1 introducer inside
APC/DCS-header ends one string and starts another (`reached` carries an END
and a START flag, `end`=ABORTED).

### 2.3 Replay-safe continuation (terminal.h)

The terminal can retain the exact byte suffix needed to rebuild unfinished
parser/UTF-8 state (used by snapshots; also usable for hosts that must hand
state to another process). Enable with
`GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES` = nonzero before the input that
produces the continuation. The continuation is empty when the stream is at
ground.

```c
GHOSTTY_API GhosttyResult ghostty_terminal_continuation_write(GhosttyTerminal terminal, GhosttyWriter writer); /* terminal.h:3339 */
GHOSTTY_API GhosttyResult ghostty_terminal_continuation_buf(GhosttyTerminal terminal, uint8_t* buf, size_t buf_len, size_t* out_written); /* terminal.h:3373 */
GHOSTTY_API GhosttyResult ghostty_terminal_continuation_alloc(GhosttyTerminal terminal, const GhosttyAllocator* allocator, uint8_t** out_ptr, size_t* out_len); /* terminal.h:3404 */
```
`GhosttyWriter` (io.h:123): `typedef struct { GhosttyWriterFn write; void* userdata; }`
with `typedef bool (*GhosttyWriterFn)(void* userdata, const uint8_t* data, size_t len);`
(io.h:87).

### 2.4 Reading state back: `ghostty_terminal_get` / `_get_multi` (terminal.h)

```c
GHOSTTY_API GhosttyResult ghostty_terminal_get(GhosttyTerminal terminal,
                                               GhosttyTerminalData data, void *out);  /* terminal.h:3535 */
GHOSTTY_API GhosttyResult ghostty_terminal_get_multi(GhosttyTerminal terminal, size_t count,
                                                     const GhosttyTerminalData* keys,
                                                     void** values, size_t* out_written); /* terminal.h:3570 */
```
The multi form reads every key in one call (for wasm/FFI); per-key types must
match. `out_written` = count on success, failing index on error.

### 2.5 Scrolling (terminal.h)

```c
GHOSTTY_API GhosttyResult ghostty_terminal_scroll_viewport(
    GhosttyTerminal terminal, GhosttyTerminalScrollViewport behavior);  /* terminal.h:3447 */
```
Tagged union (terminal.h:163-168): `tag` ∈ `{ TOP=0, BOTTOM=1, DELTA=2, ROW=3, DELTA_PROMPT=4 }`
(terminal.h:99); `value.delta` (intptr_t, up negative) for DELTA, `value.row`
(size_t, absolute row from the top of the scrollable area, same space as
`GhosttyTerminalScrollbar::offset`, clamped) for ROW, `value.delta_prompt`
for DELTA_PROMPT (moves whole prompts using OSC 133 markers; kmscon's
`grab-scroll-*`/`grab-page-*` map here).

```c
typedef struct { uint64_t total; uint64_t offset; uint64_t len; } GhosttyTerminalScrollbar; /* terminal.h:438 */
```
Read via `GHOSTTY_TERMINAL_DATA_SCROLLBAR`; amortized O(1) (first read after
an arbitrary jump may walk pages). **There is no scrollbar change
notification** — poll once per frame / per write batch and diff (Ghostty's own
renderer does this).

### 2.6 Scrollback compression (terminal.h)

```c
GHOSTTY_API GhosttyResult ghostty_terminal_compression_activity(GhosttyTerminal terminal, uint64_t* out_activity); /* terminal.h:3475 */
GHOSTTY_API GhosttyResult ghostty_terminal_compress(
    GhosttyTerminal terminal,
    GhosttyTerminalCompressionMode mode,            /* INCREMENTAL=0 | FULL=1 (terminal.h:68) */
    GhosttyTerminalCompressionResult* out_result);  /* terminal.h:3506 */
```
Incremental = one bounded step for an idle callback (result `PENDING=1` →
schedule another step; `COMPLETE=2` → wait until the activity token changes
before stepping again; `UNSUPPORTED=0` when the platform can't reclaim
retained mappings). Never changes logical contents; compressed history is
decompressed transparently on access. Must be serialized with other terminal
access.

### 2.7 Grid access (for non-render-loop, per-cell reads)

```c
typedef struct { uint16_t x; uint32_t y; } GhosttyPointCoordinate;             /* point.h:42 */
typedef enum { GHOSTTY_POINT_TAG_ACTIVE=0, GHOSTTY_POINT_TAG_VIEWPORT=1,
               GHOSTTY_POINT_TAG_SCREEN=2, GHOSTTY_POINT_TAG_HISTORY=3 } GhosttyPointTag;  /* point.h:62 */
typedef struct { GhosttyPointTag tag; GhosttyPointValue value; } GhosttyPoint;  /* point.h:99 */

GHOSTTY_API GhosttyResult ghostty_terminal_grid_ref(GhosttyTerminal terminal,
                                                    GhosttyPoint point, GhosttyGridRef *out_ref);  /* terminal.h:3608 */
GHOSTTY_API GhosttyResult ghostty_terminal_grid_ref_track(GhosttyTerminal terminal,
                                                          GhosttyPoint point,
                                                          GhosttyTrackedGridRef *out_ref);  /* terminal.h:3639 */
GHOSTTY_API GhosttyResult ghostty_terminal_point_from_grid_ref(
    GhosttyTerminal terminal, const GhosttyGridRef *ref,
    GhosttyPointTag tag, GhosttyPointCoordinate *out);    /* terminal.h:3672 */
```
`GhosttyGridRef` (grid_ref.h:107): `{ void *node; uint16_t x; uint16_t y; }`,
frozen (16 bytes on 64-bit). Zero-init it; the ref API functions return
`GHOSTTY_INVALID_VALUE` for a zeroed ref. An **untracked** ref is only valid
until the next mutating terminal call; using a stale one is UB (page may have
been freed). `ACTIVE`/`VIEWPORT` lookups are fast; `SCREEN`/`HISTORY` may walk
the page list. Not fast enough for a frame; use the render state for that.

`point_from_grid_ref` returns `GHOSTTY_NO_VALUE` when the ref is not
representable in the requested coordinate space (history cell in ACTIVE
space, etc.).

Tracked refs (grid_ref_tracked.h):
```c
GHOSTTY_API void ghostty_tracked_grid_ref_free(GhosttyTrackedGridRef ref);               /* grid_ref_tracked.h:37 */
GHOSTTY_API bool ghostty_tracked_grid_ref_has_value(GhosttyTrackedGridRef ref);          /* grid_ref_tracked.h:50 */
GHOSTTY_API GhosttyResult ghostty_tracked_grid_ref_point(GhosttyTrackedGridRef ref,
                                                         GhosttyPointTag tag, GhosttyPointCoordinate *out_point); /* grid_ref_tracked.h:79 */
GHOSTTY_API GhosttyResult ghostty_tracked_grid_ref_set(GhosttyTrackedGridRef ref,
                                                       GhosttyTerminal terminal, GhosttyPoint point);          /* grid_ref_tracked.h:105 */
GHOSTTY_API GhosttyResult ghostty_tracked_grid_ref_snapshot(GhosttyTrackedGridRef ref, GhosttyGridRef *out_ref); /* grid_ref_tracked.h:131 */
```
A tracked ref follows its cell across scroll, pruning, resize/reflow. It is
attached to the screen page-list that was active at creation/set. Uses
untracked snapshots only immediately before reading (they die at the next
mutation). Freeable after the terminal is freed (then reports no value).

---

## 3. Terminal options and data (keyed get/set)

### 3.1 `ghostty_terminal_set` (terminal.h:3228)

```c
GHOSTTY_API GhosttyResult ghostty_terminal_set(GhosttyTerminal terminal,
                                               GhosttyTerminalOption option,
                                               const void* value);
```
For callbacks and userdata `value` is the pointer itself; for everything else
it points to a value of the documented type. NULL restores the documented
default. `GHOSTTY_TERMINAL_OPT_MODE` / `MODE_DEFAULT` have no default and
return `GHOSTTY_INVALID_VALUE` for NULL.

Complete option table (enum `GhosttyTerminalOption`, terminal.h:2033). The
"in" column is the type `value` points to; callbacks are passed directly
(cast from a C call site; Zig `@ptrCast` of the function).

| # | Option | In | Default / notes |
|---|--------|----|-----------------|
| 1 | `USERDATA` (2041) | `void*` | opaque pointer given to every callback; NULL |
| 2 | `WRITE_PTY` (2051) | `GhosttyTerminalWritePtyFn` | pty reply sink (§8.1); NULL = queries unanswered |
| 3 | `BELL` (2059) | `GhosttyTerminalBellFn` | BEL (0x07); NULL = ignore |
| 4 | `ENQUIRY` (2067) | `GhosttyTerminalEnquiryFn` | ENQ (0x05); NULL = no response |
| 5 | `XTVERSION` (2075) | `GhosttyTerminalXtversionFn` | `CSI > q`; NULL = default "libghostty" |
| 6 | `TITLE_CHANGED` (2084) | `GhosttyTerminalTitleChangedFn` | OSC 0/2 |
| 7 | `SIZE` (2092) | `GhosttyTerminalSizeFn` | XTWINOPS CSI 14/16/18/19 t + mode 2048; NULL = queries ignored |
| 8 | `COLOR_SCHEME` (2102) | `GhosttyTerminalColorSchemeFn` | `CSI ? 996 n`; NULL = ignored |
| 9 | `DEVICE_ATTRIBUTES` (2116) | `GhosttyTerminalDeviceAttributesFn` | DA1/2/3; NULL = built-in defaults |
| 10 | `TITLE` (2126) | `GhosttyString*` | set manually; copied; NULL clears |
| 11 | `PWD` (2136) | `GhosttyString*` | set manually; copied; NULL clears |
| 12-14 | `COLOR_FOREGROUND/BACKGROUND/CURSOR` (2145, 2154, 2163) | `GhosttyColorRgb*` | set default colors; NULL clears |
| 15 | `COLOR_PALETTE` (2173) | `GhosttyColorRgb[256]*` | NULL resets built-in palette |
| 16 | `KITTY_IMAGE_STORAGE_LIMIT` (2188) | `uint64_t*` | per-screen bytes; 0 **disables the whole protocol, deleting stored images/placements**; default 10,000,000; NULL restores |
| 17 | `KITTY_IMAGE_MEDIUM_FILE` (2199) | `bool*` | file medium; default off (kmshaunt M4 keeps file/tmp/shm media off as root) |
| 18 | `KITTY_IMAGE_MEDIUM_TEMP_FILE` (2211) | `GhosttyString*` | temp-file medium restricted to a directory; default off |
| 19 | `KITTY_IMAGE_MEDIUM_SHARED_MEM` (2222) | `bool*` | shm medium; default off |
| 20 | `APC_MAX_BYTES` (2232) | `size_t*` | APC buffer cap for all protocols; NULL = built-ins |
| 21 | `APC_MAX_BYTES_KITTY` (2241) | `size_t*` | kitty-specific override |
| 22 | `SELECTION` (2256) | `GhosttySelection*` | install/clear the active-screen selection; copied into terminal-owned tracked state immediately |
| 23 | `DEFAULT_CURSOR_STYLE` (2265) | `GhosttyCursorStyle*` | what DECSCUSR 0 restores; default block |
| 24 | `DEFAULT_CURSOR_BLINK` (2275) | `bool*` | default no blink |
| 25 | `GLYPH_PROTOCOL` (2290) | `bool*` | Glyph Protocol APC handling; default off |
| 26 | `PWD_CHANGED` (2299) | `GhosttyTerminalPwdChangedFn` | OSC 7 / OSC 9 / OSC 1337 CurrentDir |
| 27 | `CLIPBOARD_WRITE` (2311) | `GhosttyTerminalClipboardWriteFn` | OSC 52 / OSC 1337 Copy / OSC 5522 writes normalized to MIME reps; NULL = ignore (kitty writes refused ENOSYS) |
| 28 | `SCROLLBACK_MAX_BYTES` (2346) | `size_t*` | default 10,000 bytes (rounded up to one ~400KB page); 0 erases history; `SIZE_MAX` = no limit |
| 29 | `SCROLLBACK_MAX_LINES` (2373) | `size_t*` | no default limit; `SIZE_MAX`/NULL removes |
| 30 | `DESKTOP_NOTIFICATION` (2382) | `GhosttyTerminalDesktopNotificationFn` | OSC 9 / OSC 777 |
| 31 | `PROGRESS_REPORT` (2390) | `GhosttyTerminalProgressReportFn` | OSC 9;4 |
| 32 | `CONTINUATION_MAX_BYTES` (2410) | `size_t*` | enable replay-safe continuation (§2.3); default off |
| 33 | `TITLE_REPORT` (2422) | `bool*` | answer `CSI 21 t`; default off (command-injection risk) |
| 34 | `MODE_DEFAULT` (2437) | `GhosttyTerminalModeConfig*` | set reset default for a mode (RIS restores all, DECSTR a subset); some modes invalid |
| 35 | `MODE` (2447) | `GhosttyTerminalModeConfig*` | set current mode value; does not change reset default |
| 36 | `UNKNOWN_SEQUENCE` (2459) | `GhosttyTerminalUnknownSequenceFn` | §8.3; requires #37 |
| 37 | `UNKNOWN_MAX_BYTES` (2480) | `size_t*` | nonzero enables unknown-sequence reporting; ≤2048 allocations-free for OSC |
| 38 | `TERMINFO_NAME` (2496) | `GhosttyString*` | name answered to XTGETTCAP "TN" (e.g. "xterm-256color"); ≤128 bytes; unset = no answer |
| 39 | `CLIPBOARD_READ` (2507) | `GhosttyTerminalClipboardReadFn` | OSC 52 `?` / OSC 5522 reads; also enables kitty paste events (mode 5522) |
| 40 | `CLIPBOARD_WRITE_MAX_BYTES` (2530) | `size_t*` | OSC 5522 transaction cap; default 64 MiB |
| 41 | `RESIZE_PULL_SCROLLBACK` (2555) | `bool*` | default true |
| 42 | `RENDER_HOLD` (2567) | `GhosttyTerminalRenderHoldFn` | sync output 2026 start/end |
| 43 | `SEMANTIC_PROMPT` (2576) | `GhosttyTerminalSemanticPromptFn` | OSC 133 steps |
| 44 | `RESET` (2584) | `GhosttyTerminalResetFn` | RIS `ESC c` |
| 45 | `XT_CHECKSUM_REPORT` (2600) | `bool*` | DECRQCRA `CSI ... * y`; default off (screen can be read back cell-by-cell) |
| 46 | `XT_CHECKSUM_EXTENSION` (2621) | `uint8_t*` | CHECKSUM calculation bits (1/2/4/8/16, cf. `checksumExtension`); 0 = DEC default; >31 invalid |
| 47 | `PROGRAM_STATUS` (2644) | `GhosttyTerminalProgramStatusFn` | OSC 7501 reports; while set, `OSC 7501 ; ?` queries are answered through WRITE_PTY |
| 48 | `RESIZE_WINDOW` (2653) | `GhosttyTerminalResizeWindowFn` | `CSI 8 ; rows ; cols t` |

`GhosttyTerminalModeConfig` (terminal.h:2025): `{ GhosttyMode mode; bool value; }`
— set `mode` before the call; on a data read the `value` field receives the
current value.

### 3.2 `GHOSTTY_TERMINAL_DATA_*` read keys (enum `GhosttyTerminalData`, terminal.h:2665)

| # | Key | Out type | Notes |
|---|-----|----------|-------|
| 1 | `COLS` (2674) | `uint16_t*` | width in cells |
| 2 | `ROWS` (2681) | `uint16_t*` | height in cells |
| 3 | `CURSOR_X` (2688) | `uint16_t*` | 0-indexed column |
| 4 | `CURSOR_Y` (2695) | `uint16_t*` | 0-indexed row within active area |
| 5 | `CURSOR_PENDING_WRAP` (2702) | `bool*` | next print will soft-wrap |
| 6 | `ACTIVE_SCREEN` (2709) | `GhosttyTerminalScreen*` | PRIMARY=0 / ALTERNATE=1 |
| 7 | `CURSOR_VISIBLE` (2716) | `bool*` | DEC mode 25 |
| 8 | `KITTY_KEYBOARD_FLAGS` (2723) | `GhosttyKittyKeyFlags*` (uint8_t) | §5.1 |
| 9 | `SCROLLBAR` (2741) | `GhosttyTerminalScrollbar*` | §2.5 |
| 10 | `CURSOR_SGR_STYLE` (2752) | `GhosttyStyle*` | style the next printed char will get, not cursor shape |
| 11 | `MOUSE_TRACKING` (2762) | `bool*` | any of X10/normal/button/any-event on |
| 12 | `TITLE` (2773) | `GhosttyString*` | borrowed until next mutating call |
| 13 | `PWD` (2785) | `GhosttyString*` | borrowed |
| 14 | `TOTAL_ROWS` (2792) | `size_t*` | active screen incl. scrollback |
| 15 | `SCROLLBACK_ROWS` (2799) | `size_t*` | total − viewport |
| 16 | `WIDTH_PX` (2808) | `uint32_t*` | cols × cell_width_px |
| 17 | `HEIGHT_PX` (2817) | `uint32_t*` | rows × cell_height_px |
| 18-20 | `COLOR_FOREGROUND/BACKGROUND/CURSOR` (2826/2835/2844) | `GhosttyColorRgb*` | effective (OSC-overridden); `GHOSTTY_NO_VALUE` if unset |
| 21 | `COLOR_PALETTE` (2851) | `GhosttyColorRgb[256]*` | current |
| 22-24 | `..._DEFAULT` (2860/2869/2878) | `GhosttyColorRgb*` | ignoring OSC overrides; `NO_VALUE` if unset |
| 25 | `COLOR_PALETTE_DEFAULT` (2885) | `GhosttyColorRgb[256]*` | |
| 26 | `KITTY_IMAGE_STORAGE_LIMIT` (2896) | `uint64_t*` | 0 = disabled |
| 27 | `KITTY_IMAGE_MEDIUM_FILE` (2907) | `bool*` | |
| 28 | `KITTY_IMAGE_MEDIUM_TEMP_FILE` (2919) | `GhosttyString*` | empty if disabled |
| 29 | `KITTY_IMAGE_MEDIUM_SHARED_MEM` (2930) | `bool*` | |
| 30 | `KITTY_GRAPHICS` (2944) | `GhosttyKittyGraphics*` | borrowed storage handle; **valid only until the next mutating terminal call** |
| 31 | `SELECTION` (2961) | `GhosttySelection*` | untracked snapshot of the terminal's selection; refs valid until next mutating call; `NO_VALUE` if none |
| 32 | `VIEWPORT_ACTIVE` (2971) | `bool*` | viewport pinned to active area |
| 33 | `VT_PROCESSING_ERROR` (2987) | `bool*` | a non-graceful VT error happened; informational only, cannot be unset |
| 34 | `SCROLLBACK_MAX_BYTES` (2998) | `size_t*` | always the primary screen's configured value; `NO_VALUE` if unlimited |
| 35 | `SCROLLBACK_MAX_LINES` (3009) | `size_t*` | as above |
| 36 | `CONTINUATION_MAX_BYTES` (3020) | `size_t*` | configured limit (0 = tracking off) |
| 37 | `MODE` (3031) | `GhosttyTerminalModeConfig*` | in/out: set `mode`, read `value` |
| 38 | `VT_GROUND` (3046) | `bool*` | parser at ground — safe to inject your own sequences |
| 39 | `CURSOR_AT_PROMPT` (3057) | `bool*` | cursor at semantic prompt/input (OSC 133); false on alt screen |
| 40 | `CLIPBOARD_WRITE_MAX_BYTES` (3066) | `size_t*` | |
| 41 | `MOUSE_SHAPE` (3075) | `GhosttyMouseShape*` | app's `OSC 22` pointer-shape request; initially `GHOSTTY_MOUSE_SHAPE_TEXT` |
| 42 | `MEMORY_USAGE` (3090) | `GhosttyTerminalMemoryUsage*` | sized struct (below) |

`GhosttyTerminalMemoryUsage` (terminal.h:468): `size`, `bool compression_supported`,
then per-screen (`primary_` / `alternate_` prefixes, add both for totals):
`pages`, `virtual_bytes`, `resident_bytes` (the one to budget against),
`compressed_pages`, `compressed_bytes`, `image_bytes` (kitty, *not* included
in resident_bytes). Alternate fields are zero until first used.

### 3.3 Terminal paste (paste.h)

```c
typedef enum { GHOSTTY_PASTE_SOURCE_CLIPBOARD = 0, GHOSTTY_PASTE_SOURCE_TEXT = 1 } GhosttyPasteSource; /* paste.h:52 */
typedef struct {
  size_t size;
  GhosttyClipboardLocation location;   /* reported to the program on paste events */
  GhosttyPasteSource source;
  const GhosttyString* mimes;  size_t mimes_len;   /* borrowed for the call only */
  GhosttyMimeReader reader;    /* required when mimes_len != 0; called at most once */
  bool allow_unsafe;           /* false → line terminators/bracketed-paste-end injection refused */
} GhosttyPaste;                                        /* paste.h:64 */

GHOSTTY_API GhosttyResult ghostty_terminal_paste(GhosttyTerminal terminal,
                                                 const GhosttyPaste* paste,
                                                 bool* out_pasted);   /* paste.h:146 */
```
Behavior: with mode 5522 set **and** a `CLIPBOARD_READ` callback installed,
the paste is delivered as a kitty paste event; otherwise the text is framed
per mode 2004 (bracketed paste) and streamed through `WRITE_PTY` in chunks.
`out_pasted` says whether anything was written. Results: `GHOSTTY_REJECTED`
when unsafe and `allow_unsafe` false (nothing written; confirm with the user
and retry with true); `GHOSTTY_INVALID_VALUE` without a `WRITE_PTY` callback;
`GHOSTTY_IO_ERROR` if the reader fails or no secure entropy exists (wasm
without `RANDOM_SECURE`).

`GhosttyMimeReader` (io.h:151): `{ GhosttyMimeReaderFn read; void* userdata; }`,
`typedef bool (*GhosttyMimeReaderFn)(void* userdata, GhosttyString mime, GhosttyWriter writer);`
(io.h:139) — the callback streams the representation named by `mime` into
`writer` and returns true.

Standalone paste helpers (no terminal needed):

```c
GHOSTTY_API bool ghostty_paste_is_safe(const char* data, size_t len);   /* paste.h:170 */
/* unsafe = contains \n, \r, or the bracketed-paste end sequence \x1b[201~ */
GHOSTTY_API GhosttyResult ghostty_paste_encode(char* data, size_t data_len,
                                               bool bracketed, uint8_t* buf,
                                               size_t buf_len, size_t* out_written); /* paste.h:223 */
```
`paste_encode` strips unsafe control bytes in place (replacing with spaces),
wraps in `\x1b[200~ … \x1b[201~` when `bracketed`, and maps `\n`→`\r` when not.

---

## 4. Render state

### 4.1 Lifecycle and update (render.h)

```c
GHOSTTY_API GhosttyResult ghostty_render_state_new(const GhosttyAllocator* allocator, GhosttyRenderState* state);  /* render.h:623 */
GHOSTTY_API void ghostty_render_state_free(GhosttyRenderState state);   /* render.h:636 */
GHOSTTY_API GhosttyResult ghostty_render_state_update(GhosttyRenderState state, GhosttyTerminal terminal); /* render.h:664 */
```
`update` = begin+end in one call. The two-phase form exists for a lock shared
with an IO thread — hold your terminal lock only for the begin:

```c
GHOSTTY_API GhosttyResult ghostty_render_state_begin_update(GhosttyRenderState state, GhosttyTerminal terminal); /* render.h:696 */
GHOSTTY_API GhosttyResult ghostty_render_state_end_update(GhosttyRenderState state);   /* render.h:713; only touches render-state memory, safe while the terminal is modified */
```
The update captures exactly the viewport (optionally plus overscan, below),
consumes terminal/screen dirty state the same way Ghostty's internal update
does, and snapshots everything needed to draw the frame; after the update the
render state needs no terminal access until the next update.

**Dirty tracking & clearing.** After an update read:

```c
GHOSTTY_API GhosttyResult ghostty_render_state_clean(GhosttyRenderState state);  /* render.h:730 */
```
`clean` marks ALL dirty data consumed: global dirty → `DIRTY_FALSE` and every
per-row flag cleared (idempotent; does not touch terminal-owned dirty state).
Call it only after the whole frame rendered successfully. Partial consumers
clear per row / globally via `ghostty_render_state_set` /
`ghostty_render_state_row_set` instead.

```c
typedef enum { GHOSTTY_RENDER_STATE_DIRTY_FALSE = 0,
               GHOSTTY_RENDER_STATE_DIRTY_PARTIAL = 1,
               GHOSTTY_RENDER_STATE_DIRTY_FULL = 2 } GhosttyRenderStateDirty;  /* render.h:49 */
```
- `FULL`: global state changed — redraw everything.
- `PARTIAL`: some rows changed — redraw incrementally (per-row flags).
- `FALSE`: skip rendering.

Data and option keys:

```c
typedef enum {
  GHOSTTY_RENDER_STATE_DATA_INVALID = 0,
  GHOSTTY_RENDER_STATE_DATA_COLS = 1,          /* uint16_t */
  GHOSTTY_RENDER_STATE_DATA_ROWS = 2,          /* uint16_t, excludes overscan */
  GHOSTTY_RENDER_STATE_DATA_DIRTY = 3,         /* GhosttyRenderStateDirty */
  GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR = 4,  /* fills a pre-allocated GhosttyRenderStateRowIterator */
  GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND = 5,  /* GhosttyColorRgb */
  GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND = 6,
  GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR = 7,      /* NO_VALUE if not explicitly set */
  GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR_HAS_VALUE = 8,  /* bool */
  GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE = 9,          /* GhosttyColorRgb[256] */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE = 10,   /* GhosttyCursorStyle */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE = 11,        /* bool */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING = 12,       /* bool */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_PASSWORD_INPUT = 13, /* bool */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE = 14, /* bool */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X = 15,          /* uint16_t, NO_VALUE if 14 false */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y = 16,
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL = 17, /* bool */
  GHOSTTY_RENDER_STATE_DATA_CURSOR = 18,   /* GhosttyRenderStateCursor, sized; prefer this */
  GHOSTTY_RENDER_STATE_DATA_COLORS = 19,   /* GhosttyRenderStateColors, sized; prefer this */
  GHOSTTY_RENDER_STATE_DATA_OVERSCAN = 20, /* GhosttyRenderStateOverscan of last update */
  GHOSTTY_RENDER_STATE_DATA_OVERSCAN_REQUEST = 21,  /* the pending request */
  GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR = 22,    /* fills a pre-allocated GhosttyRenderStateImageIterator */
  GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION = 23, /* uint64_t, changed when the placement list changed */
} GhosttyRenderStateData;                                     /* render.h:105 */

typedef enum {
  GHOSTTY_RENDER_STATE_OPT_INVALID = 0,
  GHOSTTY_RENDER_STATE_OPT_DIRTY = 1,     /* set GhosttyRenderStateDirty (no default; NULL invalid) */
  GHOSTTY_RENDER_STATE_OPT_OVERSCAN = 2,  /* GhosttyRenderStateOverscan; takes effect next update */
} GhosttyRenderStateOption;                                   /* render.h:222 */

GHOSTTY_API GhosttyResult ghostty_render_state_get(GhosttyRenderState state, GhosttyRenderStateData data, void* out);          /* render.h:755 */
GHOSTTY_API GhosttyResult ghostty_render_state_get_multi(GhosttyRenderState state, size_t count, const GhosttyRenderStateData* keys, void** values, size_t* out_written); /* render.h:788 */
GHOSTTY_API GhosttyResult ghostty_render_state_set(GhosttyRenderState state, GhosttyRenderStateOption option, const void* value); /* render.h:825 */
```
Overscan (render.h:71): `{ uint16_t above; uint16_t below; }` rows to capture
beyond the viewport (for transform/rotation jitter, kmshaunt M5). The update
captures what exists (`above` shrinks near the top of scrollback, `below` is
0 pinned to bottom). Row positions then count from the highest captured row;
use `VIEWPORT_Y` for placement. Expect a full redraw right after changing the
request.

Cursor and colors structs (both sized — `GHOSTTY_INIT_SIZED` before `get`):

```c
typedef struct {                       /* render.h:540 */
  size_t size;
  bool viewport_has_value;   /* false → viewport_x/y/wide_tail are undefined */
  uint16_t viewport_x;       /* in cells */
  uint16_t viewport_y;
  bool wide_tail;            /* cursor on the tail half of a wide char */
  bool visible;              /* from terminal modes */
  bool blinking;
  bool password_input;       /* e.g. OSC 52 hidden input */
  GhosttyCursorStyle visual_style;   /* types.h:96: BAR=0 BLOCK=1 UNDERLINE=2 BLOCK_HOLLOW=3 */
} GhosttyRenderStateCursor;

typedef struct {                       /* render.h:584 */
  size_t size;
  GhosttyColorRgb background;   /* current effective (OSC-overridable) colors */
  GhosttyColorRgb foreground;
  GhosttyColorRgb cursor;       /* only valid when cursor_has_value */
  bool cursor_has_value;
  GhosttyColorRgb palette[256]; /* resolve GHOSTTY_STYLE_COLOR_PALETTE indices here */
} GhosttyRenderStateColors;
```

### 4.2 Rows

```c
GHOSTTY_API GhosttyResult ghostty_render_state_row_iterator_new(const GhosttyAllocator* allocator, GhosttyRenderStateRowIterator* out_iterator); /* render.h:849 */
GHOSTTY_API void ghostty_render_state_row_iterator_free(GhosttyRenderStateRowIterator iterator);   /* render.h:860 */
```
Populate it after every update with `ghostty_render_state_get(state,
GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iter)`; row data is **only valid
until the next update of the render state**.

```c
GHOSTTY_API bool ghostty_render_state_row_iterator_next(GhosttyRenderStateRowIterator iterator);        /* render.h:878, true → moved to a row */
GHOSTTY_API bool ghostty_render_state_row_iterator_next_dirty(GhosttyRenderStateRowIterator iterator,
                                                              uint16_t* out_y);                          /* render.h:903 */
```
`next` visits every captured row top→bottom. `next_dirty` skips clean rows
when dirty is PARTIAL, returns every remaining row when FULL, and nothing
when FALSE; it does not clear dirty state.

Row data (`GhosttyRenderStateRowData`, render.h:438):

| Key | Out | Meaning |
|-----|-----|---------|
| `DIRTY` (441) | `bool*` | current row dirty |
| `RAW` (448) | `GhosttyRow*` | opaque row value for `ghostty_row_get` |
| `CELLS` (452) | `GhosttyRenderStateRowCells*` | populate pre-allocated cells handle (§4.3) |
| `SELECTION` (455) | `GhosttyRenderStateRowSelection*` | sized; `NO_VALUE` if row not in selection |
| `CELLS_RAW` (462) | `GhosttyCellsView*` | one `GhosttyCell` per column, bulk read for FFI; bit layout via `ghostty_type_json` |
| `VIEWPORT_Y` (470) | `int32_t*` | 0..rows-1 in viewport; negative above; ≥rows below (overscan) |
| `ID` (477) | `GhosttyRenderStateRowId*` | row identity across updates; compare both `uint64_t bits[2]` words (render.h:95); zero-init never valid |

```c
typedef struct { size_t size; uint16_t start_x; uint16_t end_x; } GhosttyRenderStateRowSelection; /* render.h:518: end inclusive */
GHOSTTY_API GhosttyResult ghostty_render_state_row_get(GhosttyRenderStateRowIterator iterator, GhosttyRenderStateRowData data, void* out); /* render.h:926 */
GHOSTTY_API GhosttyResult ghostty_render_state_row_get_multi(GhosttyRenderStateRowIterator iterator, size_t count, const GhosttyRenderStateRowData* keys, void** values, size_t* out_written); /* render.h:960 */
GHOSTTY_API GhosttyResult ghostty_render_state_row_set(GhosttyRenderStateRowIterator iterator, GhosttyRenderStateRowOption option, const void* value); /* render.h:987; only OPT_DIRTY=1, no default */
```

### 4.3 Cells — the render cell

The raw `GhosttyCell` is an opaque(ish) **packed uint64_t** (screen.h:73);
decode it either with `ghostty_cell_get` (portable) or by parsing the
`GhosttyCell` descriptor from `ghostty_type_json()` (types.h:640,
`GHOSTTY_API const char *ghostty_type_json(void)` — the ABI manifest, valid
for the process lifetime; bit positions are not otherwise stable). Rows are
opaque `GhosttyRow` (screen.h:87), read only via `ghostty_row_get`.

**Cell fields** (`GhosttyCellData`, screen.h:159; out pointer per key):

| Key | Out | Meaning |
|-----|-----|---------|
| `CODEPOINT` (166) | `uint32_t*` | the cell's primary codepoint; 0 if empty/bg-color-only |
| `CONTENT_TAG` (172) | `GhosttyCellContentTag*` | see below |
| `WIDE` (179) | `GhosttyCellWide*` | see below |
| `HAS_TEXT` (185) | `bool*` |
| `HAS_STYLING` (191) | `bool*` | non-default style |
| `STYLE_ID` (197) | `GhosttyStyleId*` (uint16_t) | index for style lookups from grid refs |
| `HAS_HYPERLINK` (203) | `bool*` |
| `PROTECTED` (209) | `bool*` |
| `SEMANTIC_CONTENT` (215) | `GhosttyCellSemanticContent*` | OSC 133: OUTPUT=0 INPUT=1 PROMPT=2 |
| `COLOR_PALETTE` (222) | `GhosttyColorPaletteIndex*` | only when tag = BG_COLOR_PALETTE |
| `COLOR_RGB` (229) | `GhosttyColorRgb*` | only when tag = BG_COLOR_RGB |

`GhosttyCellContentTag` (screen.h:94): `CODEPOINT=0` (single codepoint, may be
0), `CODEPOINT_GRAPHEME=1` (part of a multi-codepoint cluster — extra
codepoints live in the grapheme store, §10), `BG_COLOR_PALETTE=2` (no text,
background from palette), `BG_COLOR_RGB=3`.

`GhosttyCellWide` (screen.h:116): `NARROW=0` (width 1), `WIDE=1` (width 2),
`SPACER_TAIL=2` (second column of a wide char — **draw nothing**),
`SPACER_HEAD=3` (end-of-line spacer after a wide char on a soft wrap).

Row fields (`GhosttyRowData`, screen.h:272): `WRAP=1` (soft-wrapped row),
`WRAP_CONTINUATION=2`, `GRAPHEME=3` (any cluster cells),
`STYLED=4` (any styled cells; may be a false positive),
`HYPERLINK=5`, `SEMANTIC_PROMPT=6` (`GhosttyRowSemanticPrompt`: NONE=0,
PROMPT=1, PROMPT_CONTINUATION=2, screen.h:252), `KITTY_VIRTUAL_PLACEHOLDER=7`,
`DIRTY=8`.

```c
GHOSTTY_API GhosttyResult ghostty_cell_get(GhosttyCell cell, GhosttyCellData data, void *out);   /* screen.h:351 */
GHOSTTY_API GhosttyResult ghostty_cell_get_multi(GhosttyCell cell, size_t count, const GhosttyCellData* keys, void** values, size_t* out_written); /* screen.h:384 */
GHOSTTY_API GhosttyResult ghostty_row_get(GhosttyRow row, GhosttyRowData data, void *out);       /* screen.h:407 */
GHOSTTY_API GhosttyResult ghostty_row_get_multi(GhosttyRow row, size_t count, const GhosttyRowData* keys, void** values, size_t* out_written); /* screen.h:440 */
```

**Cell iteration from a render state** (`GhosttyRenderStateRowCellsData`,
render.h:999):

```c
GHOSTTY_API GhosttyResult ghostty_render_state_row_cells_new(const GhosttyAllocator* allocator, GhosttyRenderStateRowCells* out_cells); /* render.h:1113 */
GHOSTTY_API void ghostty_render_state_row_cells_free(GhosttyRenderStateRowCells cells);            /* render.h:1246 */
GHOSTTY_API bool ghostty_render_state_row_cells_next(GhosttyRenderStateRowCells cells);            /* render.h:1129, true → moved to a cell */
GHOSTTY_API GhosttyResult ghostty_render_state_row_cells_select(GhosttyRenderStateRowCells cells, uint16_t x); /* render.h:1145 */

GHOSTTY_API GhosttyResult ghostty_render_state_row_cells_get(
    GhosttyRenderStateRowCells cells, GhosttyRenderStateRowCellsData data, void* out);      /* render.h:1167 */
GHOSTTY_API GhosttyResult ghostty_render_state_row_cells_get_multi(
    GhosttyRenderStateRowCells cells, size_t count, const GhosttyRenderStateRowCellsData* keys,
    void** values, size_t* out_written);                                                    /* render.h:1222 */
```
Reuse one cells handle for every row (`ROW_DATA_CELLS` repopulates it). Cell
data keys (render.h:999):

| Key | Out | Meaning |
|-----|-----|---------|
| `RAW` (1004) | `GhosttyCell*` | the packed cell |
| `STYLE` (1007) | `GhosttyStyle*` | default style when the cell has none (§4.4) |
| `GRAPHEMES_LEN` (1011) | `uint32_t*` | total cluster codepoints incl. base; 0 = no text |
| `GRAPHEMES_BUF` (1034) | `GhosttyCodepointBuffer*` | base codepoint first, then combining codepoints |
| `BG_COLOR` (1073) | `GhosttyColorRgb*` | resolved: cell bg (RGB or palette-indexed via render palette) then style bg; `NO_VALUE` → draw terminal default bg |
| `FG_COLOR` (1090) | `GhosttyColorRgb*` | resolved foreground; **bold color handling is NOT applied** — apply bold yourself |
| `SELECTED` (1100) | `bool*` | column inside current row's selection range |
| `HAS_STYLING` (1108) | `bool*` | avoids materializing the raw cell |
| `GRAPHEMES_UTF8` (1118) | `GhosttyBuffer*` | whole cluster encoded UTF-8 (base first, then extras); `OUT_OF_SPACE` with `len`=required bytes when too small; `len`=0 for empty cells |

**`GRAPHEMES_UTF8` is the key R1 hook**: draw the full cluster from it and let
HarfBuzz shape it; cell width always comes from the library (`WIDE` +
`ghostty_unicode_*`, §10), and the glyph is fitted into 1 or 2 cells.

### 4.4 `GhosttyStyle` (style.h:227) — fixed 16-byte layout, no `size` field

```c
typedef enum { GHOSTTY_STYLE_COLOR_NONE = 0, GHOSTTY_STYLE_COLOR_PALETTE = 1,
               GHOSTTY_STYLE_COLOR_RGB = 2 } GhosttyStyleColorTag;    /* style.h:62 */
typedef union { GhosttyColorPaletteIndex palette; GhosttyColorRgb rgb; } GhosttyStyleColorValue; /* style.h:82 */
typedef struct { uint8_t tag; GhosttyStyleColorValue value; } GhosttyStyleColor;                 /* style.h:113 — 4 bytes */

typedef struct {
  GhosttyStyleColor fg_color;        /* foreground: NONE → use terminal default */
  GhosttyStyleColor bg_color;
  GhosttyStyleColor underline_color;
  GhosttyStyleFlags flags;           /* uint16_t, below */
  uint16_t reserved;                 /* 0 from the library; memcmp-comparable */
} GhosttyStyle;                                               /* style.h:227 */
```
Flags (style.h:140): bits 0-7 = `BOLD (1<<0)`, `ITALIC (1<<1)`, `FAINT (1<<2)`,
`BLINK (1<<3)`, `INVERSE (1<<4)` (swap fg/bg when drawing), `INVISIBLE (1<<5)`,
`STRIKETHROUGH (1<<6)`, `OVERLINE (1<<7)`; bits 8-10 = underline style
(`GHOSTTY_STYLE_UNDERLINE(style)` macro, style.h:191, returns a
`GhosttySgrUnderline`, see sgr.h). Helpers:
`ghostty_style_default(GhosttyStyle*)` (style.h:244), `ghostty_style_is_default(const GhosttyStyle*)` (style.h:251).

Colors: `GhosttyColorRgb { uint8_t r,g,b; }` (color.h:66);
`GhosttyColorPaletteIndex` = `uint8_t` (color.h:73). Palette helpers
(color.h): `ghostty_color_palette_default(GhosttyColorRgb* out[256])` (:276),
`ghostty_color_parse("value", len, &rgb)` (:235) accepts X11 names / #rgb
#rrggbb #rrrgggbbb #rrrrggggbbbb / `rgb:r/g/b` / `rgbi:…`,
`ghostty_color_parse_x11` (:213), `ghostty_color_parse_palette_entry`
(:259, `N=COLOR`), `ghostty_color_rgb_get` (:193), luminance/contrast
(:325/:340/:354), X11 name table (:382/:394), palette generation with
`GhosttyColorPaletteMask` bitmask (:307, macros at color.h:110+).

### 4.5 Scrollback vs viewport access (summary)

- The render state captures **only the viewport (+ requested overscan)** —
  rows `VIEWPORT_Y` 0..rows-1, all cells of each row, plus an image placement
  list. That is the drawing path.
- Everything else (scrollback, whole screen, arbitrary cells) goes through
  `ghostty_terminal_grid_ref` with `POINT_TAG_*` (§2.7), tracked refs,
  `ghostty_terminal_scroll_viewport` (§2.5), `DATA_SCROLLBAR`, `DATA_TOTAL_ROWS`,
  `DATA_SCROLLBACK_ROWS`, `DATA_VIEWPORT_ACTIVE`, and the content APIs
  (formatter §11.3 for whole-screen/selection text, search §7 for matches).

---

## 5. Input encoders

### 5.1 Key (key/encoder.h, key/event.h)

Kitty keyboard protocol flags (key/encoder.h:88):
`GHOSTTY_KITTY_KEY_DISABLED 0`, `_DISAMBIGUATE (1<<0)`, `_REPORT_EVENTS (1<<1)`,
`_REPORT_ALTERNATES (1<<2)`, `_REPORT_ALL (1<<3)`, `_REPORT_ASSOCIATED (1<<4)`,
`GHOSTTY_KITTY_KEY_ALL` = all combined. `GhosttyKittyKeyFlags` = uint8_t.
Read current flags with `GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS`.

Encoder options (`GhosttyKeyEncoderOption`, key/encoder.h:107): 
`CURSOR_KEY_APPLICATION=1` (DEC mode 1, bool), `KEYPAD_KEY_APPLICATION=2`
(mode 66), `IGNORE_KEYPAD_WITH_NUMLOCK=3` (mode 1035),
`ALT_ESC_PREFIX=4` (mode 1036), `MODIFY_OTHER_KEYS_STATE_2=5` (bool),
`KITTY_FLAGS=6` (GhosttyKittyKeyFlags), `MACOS_OPTION_AS_ALT=7`
(`GhosttyOptionAsAlt`: FALSE/TRUE/LEFT/RIGHT), `BACKARROW_KEY_MODE=8`
(false → BS emits 0x7f, true → 0x08; mode 67 DECBKM).

```c
GHOSTTY_API GhosttyResult ghostty_key_encoder_new(const GhosttyAllocator *allocator, GhosttyKeyEncoder *encoder); /* key/encoder.h:146 */
GHOSTTY_API void ghostty_key_encoder_free(GhosttyKeyEncoder encoder);        /* key/encoder.h:158 */
GHOSTTY_API GhosttyResult ghostty_key_encoder_set(GhosttyKeyEncoder encoder, GhosttyKeyEncoderOption option, const void *value); /* key/encoder.h:197 */
GHOSTTY_API GhosttyResult ghostty_key_encoder_set_from_terminal(GhosttyKeyEncoder encoder, GhosttyTerminal terminal); /* key/encoder.h:219 */
/* copies modes 1/66/67/1035/1036, modifyOtherKeys, kitty flags from the terminal; resets MACOS_OPTION_AS_ALT to FALSE */
GHOSTTY_API GhosttyResult ghostty_key_encoder_encode(GhosttyKeyEncoder encoder, GhosttyKeyEvent event,
                                                     uint8_t *buf, size_t buf_len, size_t *out_written); /* key/encoder.h:295 */
```
Encode: `SUCCESS` with `out_written` 0 = no output (e.g. unmodified modifier
key); `OUT_OF_SPACE` with `out_written` = needed size (pass NULL/0 first to
measure). Feed the bytes to the pty.

Key event (`GhosttyKeyEvent` opaque, key/event.h:52):
actions `RELEASE=0, PRESS=1, REPEAT=2` (key/event.h:70); mods bitmask
`GhosttyMods` = uint16_t (key/event.h:109): `SHIFT 1<<0, CTRL 1<<1, ALT 1<<2,
SUPER 1<<3, CAPS_LOCK 1<<4, NUM_LOCK 1<<5`, plus right-side bits
`SHIFT_SIDE 1<<6 … SUPER_SIDE 1<<9` (meaningful only when the base bit is
set). Keys are **physical** W3C `KeyboardEvent.code` values
(`GHOSTTY_KEY_A = 20 … GHOSTTY_KEY_F24 = 144`, arrows, numpad, media etc.;
full list key/event.h:122-312). Set the layout-produced text separately as
UTF-8 (must be the *unmodified* character; don't pass C0 controls — leave
empty and the encoder uses the logical key).

```c
GHOSTTY_API GhosttyResult ghostty_key_event_new(const GhosttyAllocator *allocator, GhosttyKeyEvent *event); /* key/event.h:324 */
GHOSTTY_API void ghostty_key_event_free(GhosttyKeyEvent event);                  /* key/event.h:336 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_action(GhosttyKeyEvent, GhosttyKeyAction);     /* key/event.h:349 */
GHOSTTY_API GhosttyKeyAction ghostty_key_event_get_action(GhosttyKeyEvent);                     /* key/event.h:359 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_key(GhosttyKeyEvent, GhosttyKey);               /* key/event.h:372 */
GHOSTTY_API GhosttyKey ghostty_key_event_get_key(GhosttyKeyEvent);                              /* key/event.h:383 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_mods(GhosttyKeyEvent, GhosttyMods);             /* key/event.h:395 */
GHOSTTY_API GhosttyMods ghostty_key_event_get_mods(GhosttyKeyEvent);                            /* key/event.h:405 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_consumed_mods(GhosttyKeyEvent, GhosttyMods);    /* key/event.h:417 */
GHOSTTY_API GhosttyMods ghostty_key_event_get_consumed_mods(GhosttyKeyEvent);                   /* key/event.h:428 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_composing(GhosttyKeyEvent, bool);               /* key/event.h:440 */
GHOSTTY_API bool ghostty_key_event_get_composing(GhosttyKeyEvent);                              /* key/event.h:451 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_utf8(GhosttyKeyEvent, GhosttyString utf8);      /* key/event.h:490 — NOT copied; bytes must outlive the event or the next set */
GHOSTTY_API GhosttyString ghostty_key_event_get_utf8(GhosttyKeyEvent);                          /* key/event.h:513 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_unshifted_codepoint(GhosttyKeyEvent, uint32_t); /* key/event.h:525 */
GHOSTTY_API uint32_t ghostty_key_event_get_unshifted_codepoint(GhosttyKeyEvent);                /* key/event.h:535 */
```

### 5.2 Mouse (mouse.h, mouse/encoder.h, mouse/event.h)

Tracking modes (`GhosttyMouseTrackingMode`, mouse/encoder.h:49): `NONE=0,
X10=1, NORMAL=2` (press/release), `BUTTON=3` (button-event), `ANY=4`.
Formats (`GhosttyMouseFormat`, mouse/encoder.h:74): `X10=0, UTF8=1, SGR=2,
URXVT=3, SGR_PIXELS=4`.

Encoder options (`GhosttyMouseEncoderOption`, mouse/encoder.h:114):
`EVENT=1` (tracking mode, default NONE), `FORMAT=2` (default X10),
`SIZE=3` (`GhosttyMouseEncoderSize`, sized struct, default 1x1 screen/1x1
cells/no padding), `ANY_BUTTON_PRESSED=4` (bool), `TRACK_LAST_CELL=5`
(motion dedup, default false).

```c
typedef struct {              /* mouse/encoder.h:97; sized */
  size_t size;
  uint32_t screen_width, screen_height;
  uint32_t cell_width, cell_height;   /* must be nonzero */
  uint32_t padding_top, padding_bottom, padding_right, padding_left;
} GhosttyMouseEncoderSize;

GHOSTTY_API GhosttyResult ghostty_mouse_encoder_new(const GhosttyAllocator *allocator, GhosttyMouseEncoder *encoder); /* mouse/encoder.h:153 */
GHOSTTY_API void ghostty_mouse_encoder_free(GhosttyMouseEncoder encoder);               /* mouse/encoder.h:163 */
GHOSTTY_API GhosttyResult ghostty_mouse_encoder_set(GhosttyMouseEncoder encoder, GhosttyMouseEncoderOption option, const void *value); /* mouse/encoder.h:190 */
GHOSTTY_API GhosttyResult ghostty_mouse_encoder_set_from_terminal(GhosttyMouseEncoder encoder, GhosttyTerminal terminal); /* mouse/encoder.h:209; sets mode+format, clears last-cell state */
GHOSTTY_API GhosttyResult ghostty_mouse_encoder_reset(GhosttyMouseEncoder encoder);     /* mouse/encoder.h:223 */
GHOSTTY_API GhosttyResult ghostty_mouse_encoder_encode(GhosttyMouseEncoder encoder, GhosttyMouseEvent event,
                                                       uint8_t *buf, size_t buf_len, size_t *out_written); /* mouse/encoder.h:262 */
```
Mouse event (mouse/event.h): action `PRESS=0, RELEASE=1, MOTION=2`
(mouse/event.h:62); button `UNKNOWN=0 … ELEVEN=11` (mouse/event.h:75);
position `GhosttyMousePosition { float x; float y; }` in **surface-space
pixels** (mouse/event.h:93). Setter/getter pairs at mouse/event.h:83-228
(`..._new`, `_free`, `_set_action`/`_get_action`, `_set_button`/`_get_button`
(returns `GHOSTTY_NO_VALUE` when no button — normal for motion; use
`_clear_button` to unset), `_set_mods`/`_get_mods`, `_set_position`/
`_get_position`). Feed the encoded bytes to the pty.

**There is no "mouse mode changed" callback** — poll
`GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING` (or refresh the encoder with
`set_from_terminal`) after writes, and read the OSC 22 pointer shape from
`GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE` (`GhosttyMouseShape`, mouse.h:37: DEFAULT
… TEXT=8 … NWSE_RESIZE=31 … ZOOM_OUT=33). kmshaunt's software cursor maps
`MOUSE_SHAPE` changes to its cursor bitmap (kmscon `cursor` config).

### 5.3 Focus (focus.h)

```c
typedef enum { GHOSTTY_FOCUS_GAINED = 0, GHOSTTY_FOCUS_LOST = 1 } GhosttyFocusEvent; /* focus.h:54 */
GHOSTTY_API GhosttyResult ghostty_focus_encode(GhosttyFocusEvent event,
                                               uint8_t* buf, size_t buf_len, size_t* out_written); /* focus.h:68 */
```
`CSI I` on gain, `CSI O` on loss. Only send while mode 1004 (`GHOSTTY_MODE_FOCUS_EVENT`)
is set — read via `GHOSTTY_TERMINAL_DATA_MODE`.

---

## 6. Selection

### 6.1 The `GhosttySelection` value (selection.h:210)

```c
typedef struct {
  GhosttyGridRef start;    /* included; keeps the user's drag direction · 16 bytes */
  GhosttyGridRef end;
  bool rectangle;          /* true = block between opposite corners */
} GhosttySelection;
```
Frozen (40 bytes on 64-bit). Both ends are **untracked** refs → the snapshot
dies at the next mutating terminal call; install it into the terminal with
`GHOSTTY_TERMINAL_OPT_SELECTION` (which copies it into long-lived tracked
state) or keep `GhosttyTrackedGridRef`s. `start` may come *after* `end`
(upward drag); normalize with `ghostty_terminal_selection_ordered`.

```c
typedef struct { GhosttySelection* ptr; size_t cap; size_t len; } GhosttySelectionBuffer; /* selection.h:245; query with ptr=NULL cap=0 */
```

### 6.2 Deriving selections (selection.h)

```c
typedef struct { size_t size; GhosttyGridRef ref;
                 const uint32_t* boundary_codepoints; size_t boundary_codepoints_len; } GhosttyTerminalSelectWordOptions;       /* selection.h:267, sized */
typedef struct { size_t size; GhosttyGridRef start, end;
                 const uint32_t* boundary_codepoints; size_t boundary_codepoints_len; } GhosttyTerminalSelectWordBetweenOptions; /* selection.h:298, sized */
typedef struct { size_t size; GhosttyGridRef ref;
                 const uint32_t* whitespace; size_t whitespace_len;
                 bool semantic_prompt_boundary; } GhosttyTerminalSelectLineOptions;     /* selection.h:322, sized */

GHOSTTY_API GhosttyResult ghostty_terminal_select_word(GhosttyTerminal terminal, const GhosttyTerminalSelectWordOptions* options, GhosttySelection* out_selection);        /* selection.h:792 */
GHOSTTY_API GhosttyResult ghostty_terminal_select_word_between(GhosttyTerminal terminal, const GhosttyTerminalSelectWordBetweenOptions* options, GhosttySelection* out_selection); /* selection.h:828 */
GHOSTTY_API GhosttyResult ghostty_terminal_select_line(GhosttyTerminal terminal, const GhosttyTerminalSelectLineOptions* options, GhosttySelection* out_selection);        /* selection.h:849 */
GHOSTTY_API GhosttyResult ghostty_terminal_select_all(GhosttyTerminal terminal, GhosttySelection* out_selection);   /* selection.h:868 */
GHOSTTY_API GhosttyResult ghostty_terminal_select_output(GhosttyTerminal terminal, const GhosttyGridRef* ref, GhosttySelection* out_selection); /* selection.h:898 — semantic output via OSC 133 */
```
All return snapshots; install them with `GHOSTTY_TERMINAL_OPT_SELECTION`.
NULL/empty `boundary_codepoints`/`whitespace` = library defaults. For double
click + drag: two `select_word_between` calls (click→drag and drag→click) and
combine outer bounds (`start = A.start; end = B.end`).

### 6.3 Working with selections (selection.h)

```c
typedef enum { FORWARD=0, REVERSE=1, MIRRORED_FORWARD=2, MIRRORED_REVERSE=3 } GhosttySelectionOrder; /* selection.h:347 */
typedef enum { LEFT=0, RIGHT=1, UP=2, DOWN=3, HOME=4, END=5,
               PAGE_UP=6, PAGE_DOWN=7, BEGINNING_OF_LINE=8, END_OF_LINE=9 } GhosttySelectionAdjust;   /* selection.h:365 */

GHOSTTY_API GhosttyResult ghostty_terminal_selection_adjust(GhosttyTerminal terminal, GhosttySelection* selection, GhosttySelectionAdjust adjustment); /* selection.h:934 — mutates in place, moves the logical end endpoint */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_order(GhosttyTerminal terminal, const GhosttySelection* selection, GhosttySelectionOrder* out_order); /* selection.h:958 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_ordered(GhosttyTerminal terminal, const GhosttySelection* selection, GhosttySelectionOrder desired, GhosttySelection* out_selection); /* selection.h:989 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_contains(GhosttyTerminal terminal, const GhosttySelection* selection, GhosttyPoint point, bool* out_contains); /* selection.h:1018 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_equal(GhosttyTerminal terminal, const GhosttySelection* a, const GhosttySelection* b, bool* out_equal); /* selection.h:1048 */
```
All of these require refs that are valid untracked snapshots for the active
screen (same terminal, no mutation since produced); validity is a documented
precondition, not checked.

### 6.4 Reading the selected text

There is no "copy selection" function; format any `GhosttySelection` with the
formatter (§11.3): `ghostty_formatter_terminal_new`, set
`GHOSTTY_FORMATTER_OPT_SELECTION` to the selection, `EMIT=PLAIN`, `UNWRAP=true`,
`TRIM=true` (that exact combination is what Ghostty copies to the clipboard),
then `format_alloc`/`format_buf`. For a live renderer, the render state gives
per-row hit-testing for free: `ROW_DATA_SELECTION` (inclusive `start_x..end_x`),
or per-cell `ROW_CELLS_DATA_SELECTED`.

### 6.5 Gesture API (selection.h)

`GhosttySelectionGesture` (opaque, selection.h:57) interprets pointer events;
`GhosttySelectionGestureEvent` (selection.h:79) is a reusable, type-fixed
event object.

```c
GHOSTTY_API GhosttyResult ghostty_selection_gesture_new(const GhosttyAllocator* allocator, GhosttySelectionGesture* out_gesture); /* selection.h:665 */
GHOSTTY_API void ghostty_selection_gesture_free(GhosttySelectionGesture gesture, GhosttyTerminal terminal); /* selection.h:689 — pass the terminal most recently used, or NULL if it was freed */
GHOSTTY_API void ghostty_selection_gesture_reset(GhosttySelectionGesture gesture, GhosttyTerminal terminal); /* selection.h:705 */

GHOSTTY_API GhosttyResult ghostty_selection_gesture_get(GhosttySelectionGesture gesture, GhosttyTerminal terminal,
                                                        GhosttySelectionGestureData data, void* value);  /* selection.h:728 */
GHOSTTY_API GhosttyResult ghostty_selection_gesture_get_multi(GhosttySelectionGesture gesture, GhosttyTerminal terminal,
                                                              size_t count, const GhosttySelectionGestureData* keys,
                                                              void** values, size_t* out_written);       /* selection.h:762 */
```
Gesture data (`GhosttySelectionGestureData`, selection.h:394): `CLICK_COUNT`
(uint8_t*, 0 = inactive), `DRAGGED` (bool*), `AUTOSCROLL`
(`GhosttySelectionGestureAutoscroll`, selection.h:383: NONE/UP/DOWN),
`BEHAVIOR` (`GhosttySelectionGestureBehavior`), `ANCHOR`
(`GhosttyGridRef*` untracked snapshot, `NO_VALUE` if none).

```c
typedef enum { CELL=0, WORD=1, LINE=2, OUTPUT=3 } GhosttySelectionGestureBehavior;         /* selection.h:381 */
typedef struct { GhosttySelectionGestureBehavior single_click, double_click, triple_click; } GhosttySelectionGestureBehaviors; /* selection.h:397; default: cell, word, line */
typedef struct { uint32_t columns, cell_width, padding_left, screen_height; } GhosttySelectionGestureGeometry; /* selection.h:413; cell_width & screen_height must be nonzero */

typedef enum { PRESS=0, RELEASE=1, DRAG=2, AUTOSCROLL_TICK=3, DEEP_PRESS=4 } GhosttySelectionGestureEventType; /* selection.h:448 */

typedef enum {  /* selection.h:461 */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_INVALID = 0,
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF = 1,               /* GhosttyGridRef* — REQUIRED for PRESS and DRAG; optional for RELEASE (unset = pointer missed a cell) */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION = 2,          /* GhosttySurfacePosition* — PRESS/DRAG/AUTOSCROLL_TICK */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE = 3,   /* double* pixels */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS = 4,           /* uint64_t* monotonic; unset → single-click only */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS = 5,/* uint64_t* */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_WORD_BOUNDARY_CODEPOINTS = 6, /* GhosttyCodepoints* — copied into the event; default = Ghostty's */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_BEHAVIORS = 7,         /* GhosttySelectionGestureBehaviors*; default cell/word/line */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE = 8,         /* bool* */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY = 9,          /* GhosttySelectionGestureGeometry* — REQUIRED for DRAG, AUTOSCROLL_TICK */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT = 10,         /* GhosttyPointCoordinate* — REQUIRED for AUTOSCROLL_TICK */
} GhosttySelectionGestureEventOption;

GHOSTTY_API GhosttyResult ghostty_selection_gesture_event_new(const GhosttyAllocator* allocator,
                                                              GhosttySelectionGestureEvent* out_event,
                                                              GhosttySelectionGestureEventType type);   /* selection.h:547 */
GHOSTTY_API void ghostty_selection_gesture_event_free(GhosttySelectionGestureEvent event);               /* selection.h:561 */
GHOSTTY_API GhosttyResult ghostty_selection_gesture_event_set(GhosttySelectionGestureEvent event,
                                                              GhosttySelectionGestureEventOption option,
                                                              const void* value); /* selection.h:580; NULL clears */
GHOSTTY_API GhosttyResult ghostty_selection_gesture_event(GhosttySelectionGesture gesture,
                                                          GhosttyTerminal terminal,
                                                          GhosttySelectionGestureEvent event,
                                                          GhosttySelection* out_selection); /* selection.h:639 */
```
`ghostty_selection_gesture_event` dispatches to the operation matching the
event's fixed type:

- **PRESS**: `REF` required; applies click-count logic (repeat distance +
  interval in the event), picks the behavior from the table, and returns the
  selection. It does **not** install the selection on the terminal — the
  caller does that (`GHOSTTY_TERMINAL_OPT_SELECTION`).
- **DRAG**: `REF` + `GEOMETRY` required; extends the selection, autoscroll
  request updated (`GESTURE_DATA_AUTOSCROLL`).
- **AUTOSCROLL_TICK**: `VIEWPORT` + `GEOMETRY` required; scrolls the viewport
  exactly one row in the reported direction, then continues the drag at that
  viewport coordinate. You own the timer; tick faster = scroll faster. A tick
  returns `NO_VALUE` (and scrolls nothing) when there is no direction; if the
  original pressed cell left the active screen it resets the gesture.
- **RELEASE**: only `REF` valid and optional; updates state, returns
  `NO_VALUE` (no selection produced).
- **DEEP_PRESS**: only `WORD_BOUNDARY_CODEPOINTS` valid, optional.

Out-selection is always a snapshot with normal lifespan; `out_selection` may
be NULL to apply the event and discard. Serialize gesture calls with terminal
mutations (gestures hold tracked refs).

---

## 7. Search

Full search over active area + scrollback of both screens (search.h). A
`GhosttySearch` borrows its terminal (free in either order; after the
terminal dies, terminal-needing calls fail cleanly).

```c
typedef enum { RUNNING=0, FEED_REQUIRED=1, COMPLETE=2 } GhosttySearchStatus;  /* search.h:52 */
typedef enum { GHOSTTY_SEARCH_SCROLL_IF_NEEDED=0, GHOSTTY_SEARCH_SCROLL_NONE=1 } GhosttySearchScroll; /* search.h:74 */

GHOSTTY_API GhosttyResult ghostty_search_new(const GhosttyAllocator* allocator, GhosttySearch* out_search, GhosttyTerminal terminal); /* search.h:239 */
GHOSTTY_API void ghostty_search_free(GhosttySearch search);                   /* search.h:257 */
GHOSTTY_API GhosttyResult ghostty_search_tick(GhosttySearch search, GhosttySearchStatus* out_status);  /* search.h:276; never touches the terminal — thread-safe */
GHOSTTY_API GhosttyResult ghostty_search_feed(GhosttySearch search);          /* search.h:301; reads the terminal; bounded work; serialize */
GHOSTTY_API GhosttyResult ghostty_search_run(GhosttySearch search);           /* search.h:322; blocking feed+tick loop; serialize */
GHOSTTY_API GhosttyResult ghostty_search_select_next(GhosttySearch search);   /* search.h:356; next = toward older content, wraps; feeds first */
GHOSTTY_API GhosttyResult ghostty_search_select_prev(GhosttySearch search);   /* search.h:374 */
GHOSTTY_API GhosttyResult ghostty_search_set(GhosttySearch search, GhosttySearchOption option, const void* value); /* search.h:400 */
GHOSTTY_API GhosttyResult ghostty_search_get(GhosttySearch search, GhosttySearchData data, void* value);           /* search.h:427 — never touches the terminal */
GHOSTTY_API GhosttyResult ghostty_search_get_multi(GhosttySearch search, size_t count, const GhosttySearchData* keys, void** values, size_t* out_written); /* search.h:464 */
```
Options (`GhosttySearchOption`, search.h:135): `NEEDLE=1` (const
`GhosttyString*`, copied; byte-exact except ASCII case-insensitive; changing
it restarts from scratch, setting the same one keeps results; NULL/empty
clears; requires serialization — touches terminal tracked state),
`SELECT_SCROLL=4` (const `GhosttySearchScroll*`).

Data (`GhosttySearchData`, search.h:91): `STATUS=1`, `NEEDLE=2`
(borrowed `GhosttyString`, `NO_VALUE` if unset), `TOTAL_MATCHES=3`
(size_t, 0 until first feed), `SELECTED_INDEX=4` (size_t; 0 = newest),
`SELECTED_MATCH=5` (`GhosttySelection*` snapshot), `MATCHES=6`
(`GhosttySelectionBuffer*`, newest→oldest; query capacity with NULL/0),
`VIEWPORT_MATCHES=7` (`GhosttySelectionBuffer*`; page-grained, may include
matches just outside the viewport; convert with `point_from_grid_ref` and
clip), `SELECT_SCROLL=8`. Note the selected index space is newest-first:
render "index+1 of total".

---

## 8. Effects: callbacks (complete list)

All registered via `ghostty_terminal_set`, one userdata per terminal
(`GHOSTTY_TERMINAL_OPT_USERDATA`), fired synchronously inside VT writes. The
docs call these the 19 effects. Zero/cleared callback = that request is
ignored (queries get **no answer** until `WRITE_PTY` is set). Callbacks must
not call `ghostty_terminal_vt_write*` on the same terminal (§0.4).

### 8.1 Replies to the pty

```c
/* terminal.h:1971 */
typedef void (*GhosttyTerminalWritePtyFn)(GhosttyTerminal terminal, void* userdata,
                                          const uint8_t* data, size_t len);
```
**Fires:** any time the terminal needs to write back to the pty. This is the
single sink for *every* reply the library generates itself: DECRQM/DECRPM
mode reports, DSR answers, the default DA responses, XTWINOPS and mode-2048
size reports, color-scheme reports, title reports (CSI 21 t, if enabled),
DECRQCRA checksums, XTGETTCAP TN, OSC 7501 support answers, clipboard
protocol status codes, XTVERSION, ENQ replies, and the report Ghostty
encodes when a `SIZE`/`COLOR_SCHEME`/`DEVICE_ATTRIBUTES` callback returns
true. `data` is valid only for the call; copy or write immediately (write to
your pty master fd, staying in order — replies from the unknown-sequence
callback also flow through here if you route them that way).

### 8.2 Notifications without replies

```c
/* terminal.h:575 */
typedef void (*GhosttyTerminalBellFn)(GhosttyTerminal terminal, void* userdata);
/* Fires: BEL (0x07). Nothing else. kmshaunt: forward to the VT (kmscon `bell`). */

/* terminal.h:1889 */
typedef void (*GhosttyTerminalTitleChangedFn)(GhosttyTerminal terminal, void* userdata);
/* Fires: OSC 0 / OSC 2. Read the new value with GHOSTTY_TERMINAL_DATA_TITLE inside the callback. */

/* terminal.h:1947 */
typedef void (*GhosttyTerminalPwdChangedFn)(GhosttyTerminal terminal, void* userdata);
/* Fires: OSC 7 (file:// URI, unparsed), OSC 9 (ConEmu CurrentDir), OSC 1337 CurrentDir.
   Read with GHOSTTY_TERMINAL_DATA_PWD. Also fires on clear (empty string). */

/* terminal.h:1921 */
typedef void (*GhosttyTerminalRenderHoldFn)(GhosttyTerminal terminal, void* userdata, bool held);
/* Fires (always in pairs): held=true when mode 2026 (synchronized output) is set;
   held=false when it is reset, or on full reset, or on ghostty_terminal_resize().
   While held, skip presenting frames / batch them (kmshaunt: defer the page flip
   until released). Changing the mode with GHOSTTY_TERMINAL_OPT_MODE never fires it. */

/* terminal.h:1176 */
typedef void (*GhosttyTerminalDesktopNotificationFn)(GhosttyTerminal terminal, void* userdata,
                                                     const GhosttyTerminalDesktopNotification* notification);
/* Fires: OSC 9 / OSC 777. Struct (terminal.h:1164, frozen 32B):
   { GhosttyString title; GhosttyString body; } — borrowed. */

/* terminal.h:1239 */
typedef void (*GhosttyTerminalProgressReportFn)(GhosttyTerminal terminal, void* userdata,
                                                const GhosttyTerminalProgressReport* report);
/* Fires: OSC 9;4. Struct (terminal.h:1215, frozen 8B):
   { GhosttyTerminalProgressState state; int8_t progress; }
   state ∈ REMOVE=0, SET=1, ERROR=2, INDETERMINATE=3, PAUSE=4 (terminal.h:1193);
   progress 0..100 or -1 when omitted. */

/* terminal.h:1469 */
typedef void (*GhosttyTerminalProgramStatusFn)(GhosttyTerminal terminal, void* userdata,
                                               const GhosttyTerminalProgramStatus* report);
/* Fires: each valid OSC 7501 report (see struct terminal.h:1320: state, kind,
   progress -1..100, id, app, title, message — all strings borrowed; only
   fully validated reports arrive). While this callback is set, an
   `OSC 7501 ; ?` query is answered through WRITE_PTY with the accepted
   states/kinds. Reset (RIS) clears records: CLEAR report first, then RESET fires. */

/* terminal.h:1620 */
typedef void (*GhosttyTerminalSemanticPromptFn)(GhosttyTerminal terminal, void* userdata,
                                                const GhosttyTerminalSemanticPrompt* event);
/* Fires: OSC 133 shell-integration steps. Struct (terminal.h:1559, frozen 48B):
   { GhosttySemanticPromptKind kind; GhosttySemanticPromptPromptKind prompt_kind;
     bool has_exit_code; int32_t exit_code; GhosttyString command; GhosttyString error; }
   kind ∈ INVALID=0, PROMPT_START=1, INPUT_START=2, OUTPUT_START=3, COMMAND_END=4
   (terminal.h:1535); prompt_kind ∈ PRIMARY=0, RIGHT=1, CONTINUATION=2,
   SECONDARY=3 (terminal.h:1563). Terminal screen is already updated when it fires;
   malformed sequences never fire it. */

/* terminal.h:1657 */
typedef void (*GhosttyTerminalResetFn)(GhosttyTerminal terminal, void* userdata);
/* Fires: full reset (RIS, ESC c) — AFTER the terminal reset itself. Title/pwd
   callbacks are NOT fired for the cleared title/pwd; update your own display here.
   Host-driven ghostty_terminal_reset() doesn't fire it either (it only ends a
   render hold via RENDER_HOLD). Soft reset (DECSTR, CSI ! p) doesn't fire it. */

/* terminal.h:1731 */
typedef void (*GhosttyTerminalResizeWindowFn)(GhosttyTerminal terminal, void* userdata,
                                              const GhosttyTerminalResizeWindow* request);
/* Fires: CSI 8 ; rows ; cols t (tag GRID=0, terminal.h:1681; value.grid =
   { uint16_t rows; uint16_t columns; }, 0 = keep). The terminal is NOT resized
   by this; you decide, then call ghostty_terminal_resize() yourself. Treat as
   opt-in (any program resizing the window is a nuisance). */
```

### 8.3 Queries the host must answer (library formats + sends via WRITE_PTY)

```c
/* terminal.h:1761 */
typedef bool (*GhosttyTerminalColorSchemeFn)(GhosttyTerminal terminal, void* userdata,
                                             GhosttyColorScheme* out_scheme);
/* Fires: CSI ? 996 n. Return true after filling *out_scheme (LIGHT=0/DARK=1,
   device.h:118) to answer CSI ? 997 ; 1|2 n; false ignores. *out_scheme is
   zeroed (LIGHT) before the call. */

/* terminal.h:1807 */
typedef bool (*GhosttyTerminalDeviceAttributesFn)(GhosttyTerminal terminal, void* userdata,
                                                  GhosttyDeviceAttributes* out_attrs);
/* Fires: CSI c (DA1), CSI > c (DA2), CSI = c (DA3). Return true after filling
   the sub-struct matching the request (fill all three for simplicity); false →
   library defaults. *out_attrs is zeroed first. Struct (device.h:150):
   { GhosttyDeviceAttributesPrimary primary; GhosttyDeviceAttributesSecondary secondary;
     GhosttyDeviceAttributesTertiary tertiary; }
   primary  = { uint16_t conformance_level; uint16_t features[64]; size_t num_features; }   (device.h:134)
   secondary= { uint16_t device_type; uint16_t firmware_version; uint16_t rom_cartridge; }  (device.h:143)
   tertiary = { uint32_t unit_id; }  /* 8 uppercase hex digits */                           (device.h:151)
   Constants (device.h): GHOSTTY_DA_CONFORMANCE_VT220=62 (× 22 feature list),
   GHOSTTY_DA_FEATURE_ANSI_COLOR=22, GHOSTTY_DA_FEATURE_CLIPBOARD=52,
   GHOSTTY_DA_DEVICE_TYPE_VT220=1, …
   Library defaults when unset: CSI ? 62 ; 22 c · CSI > 1 ; 0 ; 0 c · DCS ! | 00000000 ST. */

/* terminal.h:1867 */
typedef bool (*GhosttyTerminalSizeFn)(GhosttyTerminal terminal, void* userdata,
                                      GhosttySizeReportSize* out_size);
/* Fires: XTWINOPS CSI 14/16/18/19 t and when VT input enables in-band size
   reports (mode 2048). Return true after filling
   { uint16_t rows; uint16_t columns; uint32_t cell_width; uint32_t cell_height; }
   (size_report.h:57) → the library encodes the matching report through
   WRITE_PTY (mode 2048: ESC [ 48 ; rows ; cols ; height ; width t). False
   suppresses the report. Zeroed before the call. kmshaunt: copy geometry from
   the window state. */

/* terminal.h:1825 */
typedef GhosttyString (*GhosttyTerminalEnquiryFn)(GhosttyTerminal terminal, void* userdata);
/* Fires: ENQ (0x05). Return the response bytes (e.g. a DA-style string);
   they must stay valid until the callback returns. Zero-length = no response. */

/* terminal.h:1990 */
typedef GhosttyString (*GhosttyTerminalXtversionFn)(GhosttyTerminal terminal, void* userdata);
/* Fires: CSI > q. Return e.g. "kmshaunt 0.1"; zero-length → default "libghostty". */
```
All five return values/payloads are turned into bytes the library writes
through `WRITE_PTY` in order — the host never formats these replies itself.
(For encoding the same reports **without** a terminal, use the building
blocks: `ghostty_size_report_encode` size_report.h:81, `ghostty_color_scheme_report_encode`
color_scheme.h:65, `ghostty_mode_report_encode` modes.h:190.)

### 8.4 Clipboard / OSC 52 & kitty clipboard (terminal.h)

```c
/* terminal.h:935 */
typedef void (*GhosttyTerminalClipboardWriteFn)(GhosttyTerminal terminal, void* userdata,
                                                const GhosttyClipboardWrite* write);
```
Fires for every write request: OSC 52 (`ESC ] 52 ; <clipboard> ; <base64> ST`),
iTerm2 OSC 1337 Copy, and kitty OSC 5522 write transactions, normalized to an
atomic set of decoded MIME representations. **The VT stream is paused while
this callback runs** — the write must be answered before returning:

```c
typedef enum { GHOSTTY_CLIPBOARD_LOCATION_STANDARD=0, _SELECTION=1, _PRIMARY=2 } GhosttyClipboardLocation; /* terminal.h:741 */
typedef struct { GhosttyString mime; GhosttyString data; } GhosttyClipboardContent; /* terminal.h:765, frozen */

struct GhosttyClipboardWrite {                       /* terminal.h:873, frozen 64B */
  GhosttyClipboardLocation location;
  const GhosttyClipboardContent* contents;  size_t contents_len;  /* 0 entries = clear the destination */
  GhosttyString name;                       /* requesting program name if the protocol carries one */
  bool granted;                             /* session grant already held → skip permission prompt */
  bool can_remember;                        /* may offer remember via the reply */
  const void* ctx;                          /* do not touch */
  GhosttyClipboardWriteReplyFn reply;
};
typedef enum { SUCCESS=0, DENIED=1, UNSUPPORTED=2, BUSY=3, INVALID_DATA=4, IO_ERROR=5 } GhosttyClipboardWriteResult; /* terminal.h:780 */
typedef struct { size_t size; GhosttyClipboardWriteResult result; bool remember; } GhosttyClipboardWriteReply; /* terminal.h:818, sized */
typedef void (*GhosttyClipboardWriteReplyFn)(const GhosttyClipboardWrite* write, const GhosttyClipboardWriteReply* reply); /* terminal.h:860 */
```
Answer by calling `write->reply(write, &reply)` before returning (more than
once is safely ignored; returning without replying denies the write). The
result becomes OSC 5522 status (DONE/EPERM/ENOSYS/EBUSY/EINVAL/EIO) through
WRITE_PTY; OSC 52 and OSC 1337 discard it. `remember=true` only honored on
success when `can_remember`.

```c
/* terminal.h:1133 */
typedef void (*GhosttyTerminalClipboardReadFn)(GhosttyTerminal terminal, void* userdata,
                                               const GhosttyClipboardRead* read);
```
Fires for OSC 52 `c;?` reads and OSC 5522 reads. Also enables kitty paste
events (mode 5522): `ghostty_terminal_paste` then sends the program an event
instead of text, and the follow-up read arrives with `granted` set. **Synchronous**:
answer before returning (a modal prompt is acceptable here — the stream waits).

```c
struct GhosttyClipboardRead {                  /* terminal.h:1048, frozen 72B */
  GhosttyClipboardLocation location;
  const GhosttyString* mimes;  size_t mimes_len; /* requested MIME types in preference order */
  bool list;                     /* also deliver GhosttyClipboardReadReply::available */
  GhosttyString name;
  bool granted;
  bool can_remember;
  const void* ctx;
  GhosttyClipboardReadReplyFn reply;
};
typedef enum { SUCCESS=0, DENIED=1, UNSUPPORTED=2, BUSY=3, IO_ERROR=4 } GhosttyClipboardReadResult; /* terminal.h:947 */
typedef struct {
  size_t size;
  GhosttyClipboardReadResult result;
  const GhosttyClipboardContent* contents;  size_t contents_len;  /* one rep per requested mime on success */
  const GhosttyString* available;           size_t available_len; /* MIME list, when read->list */
  bool remember;
} GhosttyClipboardReadReply;                                     /* terminal.h:985, sized */
typedef void (*GhosttyClipboardReadReplyFn)(const GhosttyClipboardRead* read, const GhosttyClipboardReadReply* reply); /* terminal.h:1073 */
```
Non-success answers an empty clipboard (OSC 52) or the matching OSC 5522
status (EPERM/ENOSYS/EBUSY/EIO) via WRITE_PTY. OSC 52 uses the first
text/plain representation. A `list`-only request (no mimes) is served
without a prompt — don't prompt for it, and don't consume one-time passwords.

### 8.5 Unknown sequences — the kmscon private-OSC hook

```c
typedef enum { APC = 0, OSC = 1 } GhosttyTerminalUnknownSequenceTag;   /* terminal.h:593 */
typedef struct { bool truncated; GhosttyString content; } GhosttyTerminalUnknownStringSequence;  /* terminal.h:611 */
typedef struct {
  bool truncated;                 /* longer than UNKNOWN_MAX_BYTES or OOM */
  GhosttyString content;          /* everything between ESC ] and the terminator, INCLUDING the number,
                                     e.g. "7400;status=busy"; binary-safe, not NUL-terminated, valid only during the call */
  GhosttyOscTerminator terminator; /* ST = ESC \ | BEL (osc.h:122) — end any reply the same way */
} GhosttyTerminalUnknownOscSequence;                               /* terminal.h:637 */
typedef union { GhosttyTerminalUnknownStringSequence apc;
                GhosttyTerminalUnknownOscSequence osc;
                uint64_t _padding[16]; } GhosttyTerminalUnknownSequenceValue;  /* terminal.h:665 */
typedef struct { GhosttyTerminalUnknownSequenceTag tag;
                 GhosttyTerminalUnknownSequenceValue value; } GhosttyTerminalUnknownSequence;  /* terminal.h:687 */

/* terminal.h:722 */
typedef void (*GhosttyTerminalUnknownSequenceFn)(GhosttyTerminal terminal, void* userdata,
                                                 const GhosttyTerminalUnknownSequence* sequence);
```
- Fires once per **complete** APC or OSC whose number this build does not
  implement (check `tag` first; new kinds may appear in later versions).
- Requires `GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES` > 0 or nothing is ever
  reported (≤2048 keeps a terminal-owned buffer, allocations-free).
- Not reported: sequences cut short by CAN/SUB/abort, sequences the library
  implements even if malformed, and supported protocols you disabled.
- The callback runs inside `vt_write`. It may write a reply to the pty
  (in order with the library's own replies) — do **not** call
  `ghostty_terminal_vt_write()` on the same terminal.
- **kmscon's private `setBackground` / `setForeground` OSCs (M2) come through
  here.** Parse `content` (it starts with the OSC number); implement the
  kmscon-specific numbers, update the palette/config, and optionally answer
  with the same terminator the program used via WRITE_PTY. Take the exact
  kmscon numbers from kmscon's source when wiring M2; the delivery mechanics
  and reply path are exactly this callback.

### 8.6 Non-callback state changes you poll

There is intentionally **no mode-change callback** (this includes mouse
modes). After writes, poll: `GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING`,
`DATA_MOUSE_SHAPE` (OSC 22), `DATA_ACTIVE_SCREEN` (alt-screen switch: re-fetch
the kitty storage handle — the pointer is screen-bound),
`DATA_CURSOR_AT_PROMPT`, `DATA_KITTY_KEYBOARD_FLAGS`, and
`DATA_SCROLLBAR` (diff yourself, one poll per frame or per write batch).

---

## 9. Kitty graphics

### 9.1 Storage handle

```c
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_get(GhosttyKittyGraphics graphics,
                                                     GhosttyKittyGraphicsData data, void* out); /* kitty_graphics.h:479 */
```
Obtain the handle with `ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics)`.
The `GhosttyKittyGraphics` pointer is **borrowed from the active screen and
invalidated by mutating terminal calls** (`vt_write`, `reset`, …) — re-fetch
it each frame and after writes. (`animation_tick` invalidates only *image*
handles and pixel pointers, not the storage handle itself.) Data keys
(`GhosttyKittyGraphicsData`, kitty_graphics.h:49):

- `PLACEMENT_ITERATOR = 1` — populate a pre-allocated placement iterator
  (§9.3) with all placements from storage (iterator data valid until the next
  terminal mutation).
- `GENERATION = 2` — `uint64_t*`; changes whenever a program sends, replaces,
  places, or deletes an image; 0 = storage empty. Never reused (not by
  another screen, reset, or terminal) → safe as a cache key. **Does not**
  capture placements moving on screen (scroll/resize); use
  `GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION` for "when to re-read
  the render image list".

### 9.2 Images

```c
GHOSTTY_API GhosttyKittyGraphicsImage ghostty_kitty_graphics_image(GhosttyKittyGraphics graphics,
                                                                   uint32_t image_id); /* kitty_graphics.h:545; NULL if absent/disabled */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_image_get(GhosttyKittyGraphicsImage image,
                                                           GhosttyKittyGraphicsImageData data, void* out); /* kitty_graphics.h:564 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_image_get_multi(GhosttyKittyGraphicsImage image, size_t count,
                                                                 const GhosttyKittyGraphicsImageData* keys,
                                                                 void** values, size_t* out_written);        /* kitty_graphics.h:600 */
```
The image handle is borrowed and valid until the next mutating terminal call
(read pixels *and* then draw within the same frame; re-lookup after `vt_write`
or `animation_tick`). Image data (`GhosttyKittyGraphicsImageData`,
kitty_graphics.h:275): `ID=1` (uint32_t), `NUMBER=2`, `WIDTH=3`, `HEIGHT=4`
(pixels), `FORMAT=5` (`GhosttyKittyImageFormat`: RGB=0 RGBA=1 PNG=2 GRAY_ALPHA=3
GRAY=4 — stored images are always fully decoded, **never PNG**),
`COMPRESSION=6` (always NONE; zlib is inflated before storage),
`PIXELS=7` (`GhosttyString*` — raw decoded pixels, uploaded straight to the
GPU; `NO_VALUE` while the image is still arriving — the data counts against
the storage limit from the start, use `EXPECTED_LEN` to reserve;
for animations it's the current frame's pixels), `EXPECTED_LEN=8`
(size_t, width×height×bpp even before arrival), `GENERATION=9` (uint64_t —
changes when the pixels may change: send/replace/animation frame; never 0 for
a stored image; the render state reports the same value per placement as
`IMAGE_GENERATION`; texture-cache key = (protocol, image_id, generation)).

### 9.3 Placements (storage side)

```c
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_iterator_new(const GhosttyAllocator* allocator,
                                                                        GhosttyKittyGraphicsPlacementIterator* out_iterator); /* kitty_graphics.h:627 */
GHOSTTY_API void ghostty_kitty_graphics_placement_iterator_free(GhosttyKittyGraphicsPlacementIterator iterator); /* kitty_graphics.h:638 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_iterator_set(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsPlacementIteratorOption option, const void* value);  /* kitty_graphics.h:660 */
GHOSTTY_API bool ghostty_kitty_graphics_placement_next(GhosttyKittyGraphicsPlacementIterator iterator);  /* kitty_graphics.h:677 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_get(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsPlacementData data, void* out);   /* kitty_graphics.h:696 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_get_multi(
    GhosttyKittyGraphicsPlacementIterator iterator, size_t count,
    const GhosttyKittyGraphicsPlacementData* keys, void** values, size_t* out_written); /* kitty_graphics.h:732 */
```
`PLACEMENT_ITERATOR_OPT_LAYER = 1` (kitty_graphics.h:227): a uint32_t mask of
`GHOSTTY_IMAGE_LAYER_MASK_*` to visit only certain layers; 0/NULL = all
(default). Placement data (`GhosttyKittyGraphicsPlacementData`, kitty_graphics.h:90):
`IMAGE_ID=1`, `PLACEMENT_ID=2` (uint32_t), `IS_VIRTUAL=3` (bool — unicode
placeholder cells; storage has no position for it),
`X_OFFSET=4`/`Y_OFFSET=5` (pixel offset within the top-left cell),
`SOURCE_X=6`/`SOURCE_Y=7`/`SOURCE_WIDTH=8`/`SOURCE_HEIGHT=9` (crop in image
pixels; 0 width/height = full image), `COLUMNS=10`/`ROWS=11` (cells),
`Z=12` (int32_t).

Geometry queries (all take the iterator positioned on a placement + the
image handle + the terminal; virtual placements return `GHOSTTY_NO_VALUE`
where no position exists):

```c
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_rect(
    GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal, GhosttySelection* out_selection);   /* kitty_graphics.h:764 — bounding rect as a rectangle=true selection */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_pixel_size(
    GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal, uint32_t* out_width, uint32_t* out_height);   /* kitty_graphics.h:788 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_grid_size(
    GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal, uint32_t* out_cols, uint32_t* out_rows);      /* kitty_graphics.h:814 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_viewport_pos(
    GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal, int32_t* out_col, int32_t* out_row);          /* kitty_graphics.h:852; row negative above the viewport; NO_VALUE if entirely outside */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_source_rect(
    GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphicsImage image,
    uint32_t* out_x, uint32_t* out_y, uint32_t* out_width, uint32_t* out_height); /* kitty_graphics.h:877; 0→full, clamped to image bounds */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_render_info(
    GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal, GhosttyKittyGraphicsPlacementRenderInfo* out_info); /* kitty_graphics.h:913 */
```
`GhosttyKittyGraphicsPlacementRenderInfo` (kitty_graphics.h:425, sized):
`pixel_width/height`, `grid_cols/rows`, `viewport_col/row` (meaningful only
when `viewport_visible`), `viewport_visible` (bool), `source_x/y/width/height`.

### 9.4 Animations

```c
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_animation_tick(GhosttyKittyGraphics graphics,
                                                                uint64_t now_ms, uint64_t* next_ms); /* kitty_graphics.h:522 */
```
Advance every playing animation to the frame due at `now_ms` (at most one
frame per call — late calls slow playback, never skip). Frame changes bump
the image `GENERATION` and refresh `PIXELS`. `now_ms` is on **your** clock
(e.g. ms since app start); it must be monotonic and the same clock for the
life of the terminal; `next_ms` is on the same clock. Call **once per frame
you prepare**, never in a loop; schedule your next redraw at `next_ms`.
Return: `SUCCESS` (animation playing, `next_ms` set), `NO_VALUE` (nothing
playing), `UNSUPPORTED` (kitty disabled at build), `INVALID_VALUE`. This call
mutates storage → invalidates image handles/data pointers (§9.2); the storage
handle itself stays valid. The c-vt-kitty-graphics example wins with a
`MIN_FRAME_INTERVAL_MS` floor (~8 ms) so the loop cannot spin.

### 9.5 Storage limit, media, delete/eviction

- Limit: `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT` (uint64_t bytes,
  default 10,000,000, per screen). Zero disables the protocol entirely and
  deletes all images+placements. Eviction happens internally against the
  limit (expected_len counts against it before pixels arrive). Read back via
  `DATA_KITTY_IMAGE_STORAGE_LIMIT`; memory accounting in
  `GhosttyTerminalMemoryUsage::primary_image_bytes` (not part of
  resident_bytes).
- Media: `KITTY_IMAGE_MEDIUM_FILE` (bool, default off), `_TEMP_FILE`
  (GhosttyString — allowed directory; contents copied), `_SHARED_MEM` (bool,
  default off). kmshaunt keeps file/tmp/shm media off while root (M4).
- **Delete** is protocol-driven: `a=d` delete commands (and q=… replies plus
  placement deletes) arrive as APC bytes through `ghostty_terminal_vt_write`
  and are handled by the library; storage-limit eviction is also internal.
  There is **no** `ghostty_kitty_graphics_delete` C function in 1.0.1 —
  deletion only happens via the VT stream and the limit.

### 9.6 Drawing from the render state (the actual frame path)

The render state's image iterator is the drawing list — it includes virtual
and relative placements, positions everything, and covers overscan rows
(do **not** draw from the storage iterator too, or images draw twice):

```c
GHOSTTY_API GhosttyResult ghostty_render_state_image_iterator_new(const GhosttyAllocator* allocator, GhosttyRenderStateImageIterator* out_iterator); /* render.h:1260 */
GHOSTTY_API void ghostty_render_state_image_iterator_free(GhosttyRenderStateImageIterator iterator); /* render.h:1274 */
GHOSTTY_API bool ghostty_render_state_image_iterator_next(GhosttyRenderStateImageIterator iterator); /* render.h:1290 */
GHOSTTY_API GhosttyResult ghostty_render_state_image_get(GhosttyRenderStateImageIterator iterator,
                                                         GhosttyRenderStateImageData data, void* out); /* render.h:1322 */
GHOSTTY_API GhosttyResult ghostty_render_state_image_get_multi(GhosttyRenderStateImageIterator iterator, size_t count,
                                                               const GhosttyRenderStateImageData* keys,
                                                               void** values, size_t* out_written);    /* render.h:1362 */
```
Fill the iterator after each render-state update via
`get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &iter)`; only placements
with something to draw are returned. **The iteration order is not draw
order**: sort by layer, then z ascending. Placement fields
(`GhosttyRenderStateImageData`, render.h:327):

| Key | Out | Meaning |
|-----|-----|---------|
| `PROTOCOL=1` | `GhosttyImageProtocol*` | KITTY=0 (render.h:260); skip protocols you don't support |
| `IMAGE_ID=2` | `uint32_t*` | key into that protocol's storage |
| `IMAGE_GENERATION=3` | `uint64_t*` | texture cache key part |
| `LAYER=4` | `GhosttyImageLayer*` | BELOW_BACKGROUND=0 / BELOW_TEXT=1 / ABOVE_TEXT=2 (types.h:255) |
| `Z=5` | `int32_t*` | within-layer order, lower first; virtual always -1 |
| `VIEWPORT_COL=6` / `VIEWPORT_ROW=7` | `int32_t*` | top-left cell; fixed/relative report full size so may be negative (clip!); row negative above the viewport |
| `GRID_COLS=8` / `GRID_ROWS=9` | `uint32_t*` | cells covered |
| `CELL_OFFSET_X=10` / `CELL_OFFSET_Y=11` | `uint32_t*` | px offset within the top-left cell (virtual: centering, can exceed a cell) |
| `PIXEL_WIDTH=12` / `PIXEL_HEIGHT=13` | `uint32_t*` | destination size in px (cell size from `ghostty_terminal_resize`) |
| `SOURCE_X=14` / `SOURCE_Y=15` / `SOURCE_WIDTH=16` / `SOURCE_HEIGHT=17` | `uint32_t*` | crop rect in image px; scale to PIXEL_* when drawing |
| `KITTY_PLACEMENT_ID=18` | `uint32_t*` | placement id; 0 when the cells asked for none |
| `KITTY_KIND=19` | `GhosttyRenderStateKittyPlacementKind*` | VIRTUAL=0 (one row-tall run of placeholder cells), RELATIVE=1 (pinned to a parent placement; virtual parent → measured from parent's cells; fixed parent → full size from parent's cell), FIXED=2 (cell-pinned, scrolls with text) (render.h:276) |

`GhosttyImageLayer` ↔ z ranges (types.h:255): BELOW_BACKGROUND = z <
INT32_MIN/2; BELOW_TEXT = INT32_MIN/2 ≤ z < 0; ABOVE_TEXT = z ≥ 0. Layer mask
macros: `GHOSTTY_IMAGE_LAYER_MASK_BELOW_BACKGROUND (1u<<0)`, `_BELOW_TEXT
(1u<<1)`, `_ABOVE_TEXT (1u<<2)` (types.h:285-299). Draw order per frame:
BELOW_BACKGROUND → cell backgrounds → BELOW_TEXT → text → ABOVE_TEXT.

`IMAGE_PLACEMENTS_GENERATION` (`DATA_…=23`, render.h:380) changes whenever
the placement list changes (including scroll/resize) — cache "list read"
on it; per-image pixel changes are tracked by `IMAGE_GENERATION`.

---

## 10. Graphemes and cell width

**Reading clusters from cells** (three levels, all give the base codepoint
first, then combining codepoints):
1. Render state per cell: `GRAPHEMES_LEN`, `GRAPHEMES_BUF`
   (`GhosttyCodepointBuffer`), `GRAPHEMES_UTF8` (`GhosttyBuffer`, whole
   cluster as UTF-8 — the ROADMAP R1 hook) — render.h:1011/1034/1118 (§4.3).
2. Grid ref: `ghostty_grid_ref_graphemes(const GhosttyGridRef*, uint32_t* buf,
   size_t buf_len /*in codepoints*/, size_t* out_written)` — grid_ref.h:184.
3. Row/cell flags: `ROW_DATA_GRAPHEME` (screen.h:290).

**Width source** — always the library, never the font:
- `GHOSTTY_CELL_DATA_WIDE` (`GhosttyCellWide`: NARROW/WIDE/SPACER_TAIL/
  SPACER_HEAD) tells you the cell occupies 1 or 2 columns (screen.h:116).
- Standalone measurement utilities (unicode.h), matching the terminal's own
  tables and cluster rules:
  ```c
  GHOSTTY_API uint8_t ghostty_unicode_codepoint_width(uint32_t cp);        /* unicode.h:71; 0/1/2, total, pure, thread-safe */
  GHOSTTY_API size_t  ghostty_unicode_grapheme_width(const uint32_t* cps, size_t len, uint8_t* width); /* unicode.h:147 */
  ```
  `codepoint_width`: 0 for C0/C1, combining marks, default-ignorable (ZWJ/ZWNJ/VS);
  2 for East Asian Wide/Fullwidth + default-emoji-presentation + regional
  indicators (clamped to 2); 1 otherwise (total — never fails). Sum per
  codepoint only when mode 2027 is off.
  `grapheme_width` segments the first cluster with the terminal's mode-2027
  rules (VS16→wide, VS15→narrow when the base is a valid emoji variation
  base; any other width-contributing continuation → wide) and returns the
  number of codepoints consumed (loop over a string; not streaming — buffer
  while it consumes everything). Both pure, allocation-free, thread-safe.
- Mode 2027 (grapheme clustering) is `GHOSTTY_MODE_GRAPHEME_CLUSTER`
  (modes.h:96); kmscon's `grapheme-clustering` toggles it.
- kmshaunt M3 rule: group cells into runs by (face, style, no cursor split),
  shape with HarfBuzz, map clusters back to cells; draw the glyph from the
  full cluster within the 1-or-2-cell box the library reports.

---

## 11. Complete minimal host loop (distilled from the docs examples)

The pattern below is the union of `c-vt-effects`, `c-vt-render`,
`c-vt-kitty-graphics`, `c-vt-encode-key/mouse/focus`, `c-vt-selection-gesture`
and `c-vt-paste`, with the pty wiring from kmshaunt M1.

```c
/* ---- startup (once, single-threaded, before anything else) ---- */
ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, &my_png_decode);   /* libspng shim, §1.3 */
ghostty_sys_set(GHOSTTY_SYS_OPT_LOG,        &ghostty_sys_log_stderr);
/* GHOSTTY_SYS_OPT_RANDOM_SECURE: default on Linux; only wasm needs it */

bool kitty_ok = false;
ghostty_build_info(GHOSTTY_BUILD_INFO_KITTY_GRAPHICS, &kitty_ok);  /* optional check */

/* ---- terminal ---- */
GhosttyTerminal term;
ghostty_terminal_new(NULL, &term, cols, rows);
ghostty_terminal_resize(term, cols, rows, cell_w_px, cell_h_px);   /* cell px once sizes are known */
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_USERDATA, app);    /* one userdata for every callback */
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_WRITE_PTY,      (fp)on_write_pty);   /* REQUIRED for real programs */
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_BELL,           (fp)on_bell);
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,  (fp)on_title);
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_PWD_CHANGED,    (fp)on_pwd);
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_ENQUIRY,        (fp)on_enq);
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_XTVERSION,      (fp)on_xtversion);
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SIZE,           (fp)on_size);       /* CSI 14/16/18/19 t + mode 2048 */
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME,   (fp)on_color_scheme);
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,(fp)on_da);       /* false → built-in VT220 answers */
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,(fp)on_clip_write); /* must answer via write->reply()  */
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, (fp)on_clip_read);  /* must answer via read->reply()   */
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_RENDER_HOLD,    (fp)on_render_hold); /* defer presentation while held */
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_RESET,          (fp)on_reset);
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_RESIZE_WINDOW,  (fp)on_resize_window); /* opt-in */
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE,(fp)on_unknown);   /* kmscon private OSCs land here */
size_t unk = 2048; ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES, &unk);
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_TERMINFO_NAME,  &(GhosttyString){"xterm-ghostty", 13});
size_t limit = 10 * 1024 * 1024; ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &limit);

/* ---- renderers, created once, reused every frame ---- */
GhosttyRenderState rs;                 ghostty_render_state_new(NULL, &rs);
GhosttyRenderStateRowIterator rows;    ghostty_render_state_row_iterator_new(NULL, &rows);
GhosttyRenderStateRowCells cells;      ghostty_render_state_row_cells_new(NULL, &cells);
GhosttyRenderStateImageIterator imgs;  ghostty_render_state_image_iterator_new(NULL, &imgs);
/* key/mouse encoders + selection gesture + search: create once, set_from_terminal / set_needle when needed */

/* ---- main loop: pty-feed side ---- */
for (;;) {
  n = read(pty_master, buf, sizeof buf);          /* pty slave output (program→terminal) */
  ghostty_terminal_vt_write(term, buf, n);        /* callbacks fire inline; WRITE_PTY delivered the replies as bytes to write back */

  if (SIGWINCH/modeselected)                      /* display config changed */
    ghostty_terminal_resize(term, new_cols, new_rows, cell_w, cell_h);  /* reflows primary screen, ends hold */

  /* ---- frame ---- */
  ghostty_render_state_update(rs, term);          /* or begin_update under your terminal lock + end_update after */

  GhosttyRenderStateDirty dirty;
  ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
  if (dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE) {
    GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    GhosttyRenderStateCursor  cursor = GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);

    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rows);
    uint16_t y;
    while (ghostty_render_state_row_iterator_next_dirty(rows, &y)) {
      GhosttyRenderStateRowSelection sel = GHOSTTY_INIT_SIZED(GhosttyRenderStateRowSelection);
      if (ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS)
        apply_selection_range(y, sel.start_x, sel.end_x);
      ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells);
      while (ghostty_render_state_row_cells_next(cells)) {
        GhosttyBuffer utf8 = {0};
        if (ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &utf8) == GHOSTTY_SUCCESS && utf8.len) {
          GhosttyStyle style; GhosttyColorRgb fg, bg;
          ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
          ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg);   /* NO_VALUE → colors.foreground */
          ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg);   /* NO_VALUE → colors.background */
          shape_and_draw_cluster(utf8, style, fg, bg);   /* R1: HarfBuzz the whole cluster; width from the cell */
        }
      }
    }

    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &imgs);
    /* collect placements, sort by LAYER then Z, then draw BELOW_BACKGROUND → bg → BELOW_TEXT → text → ABOVE_TEXT */
    while (ghostty_render_state_image_iterator_next(imgs))
      read IMAGE_ID/IMAGE_GENERATION/LAYER/Z/VIEWPORT_COL/VIEWPORT_ROW/GRID_COLS/GRID_ROWS/
           CELL_OFFSET_*/PIXEL_*/SOURCE_* (+KITTY_KIND, KITTY_PLACEMENT_ID);
      /* texture cache key (KITTY, image_id, generation); fetch pixels via
         ghostty_terminal_get(_, DATA_KITTY_GRAPHICS, &kg) + ghostty_kitty_graphics_image(kg, id) */

    if (kitty_ok) {                                   /* once per frame, never in a loop */
      GhosttyKittyGraphics kg;
      ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &kg);
      uint64_t next;
      if (ghostty_kitty_graphics_animation_tick(kg, now_ms, &next) == GHOSTTY_SUCCESS)
        schedule_redraw(max(next - now_ms, MIN_FRAME_INTERVAL_MS));
    }

    ghostty_render_state_clean(rs);                   /* only after the whole frame drew */
  }

  /* ---- input side (per event) ---- */
  /* key:   build GhosttyKeyEvent, ghostty_key_encoder_set_from_terminal(enc, term),
            ghostty_key_encoder_encode(enc, ev, buf, cap, &n) → write(pty_master, buf, n) */
  /* mouse: ghostty_mouse_encoder_set_from_terminal(enc, term) when modes may have changed;
            optionally route to selection gesture first (§6.5): press → select; drag/tick → extend;
            install resulting selection via GHOSTTY_TERMINAL_OPT_SELECTION */
  /* focus: if mode 1004 set: ghostty_focus_encode(GAINED|LOST, buf, cap, &n) → write to pty */
  /* paste: ghostty_terminal_paste(term, &(GhosttyPaste){ .size=sizeof, .location=PRIMARY,
            .source=CLIPBOARD, .mimes=&mime, .mimes_len=1, .reader=my_reader,
            .allow_unsafe=false }, &out_pasted);  retry allow_unsafe=true after confirm on GHOSTTY_REJECTED */
}
```

`on_write_pty` is simply `write(pty_master, data, len)` (buffered copies not
needed — the callback is synchronous). `on_size` copies the window geometry
into `*out_size` and returns true. `on_da` fills the requested sub-struct and
returns true or false for the built-in VT220 reply. `on_unknown` matches the
OSC number in `sequence->value.osc.content` (kmscon's private
setBackground/setForeground) and answers with the same terminator.

### 11.3 Building blocks worth knowing (secondary for src/vt.zig)

- **Formatter** (formatter.h) — used by kmshaunt for `--print-screenshot`
  style dumps, selection-to-text (§6.4), and tests. `ghostty_formatter_terminal_new`
  (:234), `set`/`get` (:272/:298, options `OPT_EMIT=1` `GhosttyFormatterFormat`
  PLAIN=0/VT=1/HTML=2, `OPT_UNWRAP=2` bool, `OPT_TRIM=3` bool default true,
  `OPT_SELECTION=4` `GhosttySelection` (NULL = whole screen), `OPT_EXTRAS=5`),
  `format(writer)` (:322), `format_buf` (:361), `format_alloc` (:388 — free
  with `ghostty_free(allocator, ptr, len)`), `free` (:403).
- **OSC parser** (osc.h) — standalone `ESC ] … ST/BEL` parsing for host-side
  OSC work: `ghostty_osc_new/free/reset/set/next/end/command_type/command_data`
  (osc.h:279-443); `GhosttyOscTerminator { ST=0, BEL=1 }` (osc.h:122). The
  terminal does all of this internally; only needed outside a terminal.
- **SGR parser** (sgr.h) — `ghostty_sgr_new/free/reset/set_params/next/
  unknown_full/unknown_partial/attribute_tag/attribute_value` (sgr.h:176-315);
  `GhosttySgrUnderline` values used by `GHOSTTY_STYLE_UNDERLINE()`.
- **Modes** (modes.h) — `GhosttyMode` = uint16_t packed (value bits 0-14,
  ANSI flag bit 15); `ghostty_mode_new(value, ansi)` inline (:93),
  `ghostty_mode_value` (:100), `ghostty_mode_ansi` (:107); `ghostty_mode_report_encode`
  (:190). Useful `GHOSTTY_MODE_*` macros (modes.h:49): DEC modes —
  `MOUSE_EVENT_X10` (9), `CURSOR_VISIBLE` (25), `ALT_SCREEN` (1047/1049),
  `KEYPAD_KEYS` (66), `BACKARROW_KEY_MODE` (67), `MOUSE_EVENT_NORMAL/BUTTON/ANY`
  (1000/1002/1003), `FOCUS_EVENT` (1004), `MOUSE_FORMAT_UTF8/SGR/URXVT/SGR_PIXELS`
  (1005/1006/1015/1016), `ALTERNATE_SCROLL` (1007), `IGNORE_KEYPAD_WITH_NUMLOCK`
  (1035), `ALT_ESC_PREFIX` (1036), `BRACKETED_PASTE` (2004),
  `SYNCHRONIZED_OUTPUT` (2026), `GRAPHEME_CLUSTER` (2027),
  `REPORT_COLOR_SCHEME` (2031), `IN_BAND_SIZE_REPORTS` (2048),
  `KITTY_PASTE_EVENTS` (5522); ANSI — `INSERT` (4), `LINEFEED` (20). Read/write
  modes with `GHOSTTY_TERMINAL_OPT_MODE`/`DATA_MODE`/`MODE_DEFAULT`.
- **Color scheme + size report encoders**: see §8.3.
- **Snapshot** (snapshot.h) — encode/decode a full terminal state over a
  `GhosttyWriter`/`GhosttyReader`: `ghostty_snapshot_encode(_buf/_alloc)`
  (:418/:444/:470), `ghostty_snapshot_decoder_new(_buf)/free/set/ready/next/decode/get(_multi)`
  (:498-765). Optional `%snapshot` feature; decoder can page pages in so you
  can draw before history arrives (used by kmscon's restore-from-disk if we
  ever adopt it).
- **wasm.h / types manifest**: `ghostty_type_json()` (types.h:640) is the ABI
  manifest (layouts, enum values, key directions/types, callback descriptors,
  packed `GhosttyCell` bit positions). Bindings should prefer it over
  hardcoded layout, but a Zig wrapper with `b.addTranslateC` reads the C
  structs directly and doesn't need it.