//! src/video/drm3d.zig -- DRM hardware-accelerated video backend (ROADMAP
//! M5.1). GBM + EGL + GLES2 presentation with a glyph-atlas texture and image
//! textures; `hwaccel` selects this backend instead of drm2d.
//!
//! Implements the `video.Backend` vtable. The DRM modeset / page-flip / master
//! / DPMS state machine is drm2d's (docs/reference/drm2d-recipes.md); the
//! difference is the scanout buffer: instead of a dumb buffer + mmap, drm3d
//! renders with GLES2 into a GBM surface and flips the GBM bo's framebuffer.
//!
//! ## Device seams (DrmOps / GbmOps / EglOps / GlOps)
//!
//! All device access goes through four structs of function pointers. `init`
//! takes them, so tests inject fakes and run hermetically (no GPU, no libdrm,
//! no mesa). The DRM seam is drm2d's `DrmOps` verbatim (re-exported below);
//! the production DRM ops are `drm2d.libdrm.ops()`. The GBM/EGL/GL production
//! ops live in the `libgbm`/`libegl`/`libgl` namespaces at the bottom, each of
//! which lazily `@import`s its translate-c module (`gbm-c`/`egl-c`/`gl-c`) so
//! this file compiles and tests without mesa present.
//!
//! Translate-c shims (ROADMAP D3) and the build.zig wiring they need:
//!
//!     src/gbm-c.h  ->  #include <gbm.h>                 (module "gbm-c")
//!     src/egl-c.h  ->  #include <EGL/egl.h> + eglext.h  (module "egl-c")
//!     src/gl-c.h   ->  #include <GLES2/gl2.h> + gl2ext.h(module "gl-c")
//!
//!     const gbm = translateC(b, ..., "src/gbm-c.h", &.{"gbm"});
//!     const egl = translateC(b, ..., "src/egl-c.h", &.{"egl"});
//!     const gl  = translateC(b, ..., "src/gl-c.h",  &.{"glesv2"});
//!     m.addImport("gbm-c", gbm.createModule());
//!     m.addImport("egl-c", egl.createModule());
//!     m.addImport("gl-c",  gl.createModule());
//!     m.linkSystemLibrary("gbm", .{});
//!     m.linkSystemLibrary("egl", .{});     // pkg-config egl  -> libEGL
//!     m.linkSystemLibrary("glesv2", .{});  // pkg-config glesv2 -> libGLESv2
//!     // "libdrm" is already linked for drm2d.
//!
//! ## Presentation sequence (the GBM contract)
//!
//! Mesa's gbm.h is explicit: `gbm_surface_lock_front_buffer` "must be called
//! exactly once after calling eglSwapBuffers"; calling it before any swap is
//! an error, and released bos are recycled. So the correct per-frame order is
//! swap-then-lock (Weston's model), NOT lock-then-render:
//!
//!   setMode:
//!     gbm_surface_create(XRGB8888, w, h, SCANOUT|RENDERING)
//!     eglCreateWindowSurface(gbm surface); eglMakeCurrent
//!     prime: glClear -> eglSwapBuffers -> lock_front_buffer -> AddFB
//!     drmModeSetCrtc(fb of the primed bo)          (recipes #5: before flips)
//!
//!   beginFrame:  refuse if a flip is pending or no free GBM bo; make current;
//!                return the CPU staging Framebuffer (see below).
//!   endFrame:    [present staging via GL: damage rects only, M8.2]
//!                glFlush -> eglSwapBuffers -> lock_front_buffer
//!                -> import bo as EGLImage (EGL_LINUX_DRM_FOURCC_EXT) and bind
//!                   it to a GL texture (glEGLImageTargetTexture2DOES)
//!                -> AddFB (cached per bo) -> drmModePageFlip(EVENT)
//!   FLIP_COMPLETE (readEvents):
//!                gbm_surface_release_buffer(previous scanout bo)
//!                scanout bo := the bo just flipped to
//!
//! The bo being scanned out stays locked until the NEXT flip completes; that
//! is when the previous front is released back to the surface. Releasing it
//! any earlier would let GBM recycle a buffer still on screen.
//!
//! The GBM device is created on the SAME primary fd the backend modesets on,
//! so a locked bo's GEM handle feeds drmModeAddFB directly. recipes §10.2
//! describes the render-node variant (GBM/EGL on renderDN, sharing by
//! dma-buf/PRIME); that is a multi-fd refinement, not needed for the single
//! card M5.1 drives. The EGLImage import below already uses the bo's dma-buf
//! fd, so the GL side is PRIME-shaped regardless.
//!
//! ## How the Renderer contract maps to GL
//!
//! render.zig's `Renderer.renderFrame` draws into a `*Framebuffer` through the
//! CPU accessors. To keep that contract working unchanged, `beginFrame`
//! returns a backend-owned CPU **staging** Framebuffer (xrgb8888, mode-sized).
//! The CPU renderer draws into it; `endFrame` uploads the damage rects to a
//! GL texture and draws them as scissored textured quads into the EGL window
//! surface, then swaps/locks/flips (damage-only presentation, M8.2; empty
//! damage presents the whole frame). This is the "CPU staging buffer the
//! renderer draws into then GL uploads" design the contract allows.
//!
//! A GL-native renderer (the M5 renderer layer) instead drives the GL hooks
//! directly while the context is current:
//!
//!   uploadAtlas(atlas)   upload the a8 + bgra8 glyph pages (generation +
//!                        dirtyRects driven, see src/font/atlas.zig)
//!   drawCells(cells)     draw cell quads sampling the atlas pages
//!   drawImage(img, dst)  upload an RGBA image texture and draw its quad
//!
//! Calling `drawCells`/`drawImage` marks the frame GL-drawn, so `endFrame`
//! skips the staging upload (the GL renderer already rendered to the target).
//! `uploadAtlas` alone does not mark the frame (it only refreshes textures),
//! so a renderer may warm the atlas and still present via CPU staging.
//!
//! The cell shader is a basic textured quad (M5.1 is the backend + atlas/image
//! texture plumbing); the full glyph renderer lands with the renderer layer.
//!
//! ## Damage-only presentation (M8.2)
//!
//! `endFrame(damage)` redraws only the damage rects: each rect is sub-uploaded
//! from staging (glTexSubImage2D), then scissor-cleared and drawn as a quad,
//! so clear/upload/draw touch only damaged pixels. Empty damage presents
//! everything (the Backend contract), as do `full_redraw` (modeset, master
//! take, DPMS wake) and any case the backend cannot prove partial-safe.
//!
//! GBM recycles scanout bos: with N buffers the back buffer holds the frame
//! from N-1 swaps ago, not the previous frame. The backend therefore queries
//! EGL_BUFFER_AGE_EXT and replays the union of the last `age` frames' logical
//! damage (a fixed ring, no allocation). Unknown/zero age, missing history or
//! an overflowing rect list fall back to a full frame. GL-drawn frames
//! (drawCells/drawImage) present whole and record a full-history entry: their
//! delta is the renderer's, not the backend's.
//!
//! beginFrame does not clear the target (a full clear would wipe the recycled
//! back buffer outside the damage); the staging path scissor-clears its rects
//! and the GL hooks clear lazily on the first draw of the frame.
//!
//! ## Cursor
//!
//! drm3d composites the cursor in GL through the renderer, so it does not use
//! a hardware cursor plane: `setCursor` returns error.Unsupported and
//! `supportsHwCursor` returns false, and the renderer draws a software cursor
//! (video.zig documents exactly this fallback).
//!
//! ## Tests
//!
//! Hermetic (fake DrmOps/GbmOps/EglOps/GlOps, no GPU, no C libraries):
//!
//!     nix run nixpkgs#zig -- test src/test_drm3d.zig
//!
//! (src/test_drm3d.zig is the src-level test root: `zig test` rejects imports
//! outside the root file's module path, so the root must sit above video/.)
//!
//! Real wrappers + ABI checks (adds -lc, which the in-file `link_libc` test
//! gate uses to reference the C namespaces). On current nixpkgs the GBM
//! header/lib ship in `libgbm` (mesa-libgbm) and the EGL/GLES2 headers/libs in
//! `libglvnd`; older pins exposed them via `mesa.dev`. The KHR/OES image
//! entry points are resolved at runtime through eglGetProcAddress.
//!
//!     GBM=$(nix build nixpkgs#libgbm^out --print-out-paths --no-link)
//!     GLVND_DEV=$(nix build nixpkgs#libglvnd^dev --print-out-paths --no-link)
//!     GLVND=$(nix build nixpkgs#libglvnd^out --print-out-paths --no-link)
//!     DRM_DEV=$(nix build nixpkgs#libdrm^dev --print-out-paths --no-link)
//!     DRM=$(nix build nixpkgs#libdrm^out --print-out-paths --no-link)
//!     nix run nixpkgs#zig -- translate-c src/gbm-c.h -I$GBM/include -lc > /tmp/gbm_c.zig
//!     nix run nixpkgs#zig -- translate-c src/egl-c.h -I$GLVND_DEV/include -lc > /tmp/egl_c.zig
//!     nix run nixpkgs#zig -- translate-c src/gl-c.h  -I$GLVND_DEV/include -lc > /tmp/gl_c.zig
//!     nix run nixpkgs#zig -- translate-c src/drm-c.h -I$DRM_DEV/include -I$DRM_DEV/include/libdrm -lc > /tmp/drm_c.zig
//!     nix run nixpkgs#zig -- test --dep gbm-c --dep egl-c --dep gl-c --dep drm-c \
//!         -Mroot=src/test_drm3d.zig -Mgbm-c=/tmp/gbm_c.zig -Megl-c=/tmp/egl_c.zig \
//!         -Mgl-c=/tmp/gl_c.zig -Mdrm-c=/tmp/drm_c.zig \
//!         -lc -I$GBM/include -I$GLVND_DEV/include -I$DRM_DEV/include -I$DRM_DEV/include/libdrm \
//!         -L$GBM/lib -L$GLVND/lib -L$DRM/lib -lgbm -lEGL -lGLESv2 -ldrm
//!
//! ## Ordering constraints inherited from drm2d (recipes §12)
//!
//!  - #2  dropMaster waits for in-flight flips before dropping.
//!  - #3  init enumerates read-only; takeMaster re-probes forced.
//!  - #4  one outstanding flip; EBUSY keeps pending set; only FLIP_COMPLETE
//!        clears it.
//!  - #5  SetCrtc before any flip and after DPMS-on (setMode primes a bo).
//!  - #12 buffers are never freed under a pending flip.
//!  - #14 connectors() only re-enumerates.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const video = @import("../video.zig");
const fb = @import("../framebuffer.zig");
const drm2d = @import("drm2d.zig");
const atlas_mod = @import("../font/atlas.zig");

pub const Framebuffer = fb.Framebuffer;
pub const PixelFormat = fb.PixelFormat;
pub const Damage = fb.Damage;
pub const Mode = video.Mode;
pub const ConnectorInfo = video.ConnectorInfo;
pub const DpmsState = video.DpmsState;

pub const GlyphAtlas = atlas_mod.GlyphAtlas;
pub const AtlasRect = atlas_mod.Rect;

// The DRM seam is drm2d's, re-exported so callers pass one DrmOps type to both
// backends and the production ops are drm2d.libdrm.ops().
pub const DrmOps = drm2d.DrmOps;
pub const ModeInfo = drm2d.ModeInfo;
pub const Resources = drm2d.Resources;
pub const Connector = drm2d.Connector;
pub const Encoder = drm2d.Encoder;
pub const Property = drm2d.Property;
pub const PropValue = drm2d.PropValue;
pub const Clip = drm2d.Clip;
pub const Connection = drm2d.Connection;
pub const drmc = drm2d.drm;
pub const connectorTypeName = drm2d.connectorTypeName;

// GPU selection + hotplug are shared with drm2d (M5.3/M5.5).
pub const GpuSelection = drm2d.GpuSelection;
pub const GpuCandidate = drm2d.GpuCandidate;
pub const gpuIgnored = drm2d.gpuIgnored;
pub const selectGpus = drm2d.selectGpus;
pub const enumerateGpus = drm2d.enumerateGpus;
pub const freeGpuCandidates = drm2d.freeGpuCandidates;
pub const HotplugOps = drm2d.HotplugOps;
pub const HotplugEvent = drm2d.HotplugEvent;
pub const Hotplug = drm2d.Hotplug;

// ---------------------------------------------------------------------------
// GBM / EGL / GL constants (values verified against the pinned mesa headers).
// ---------------------------------------------------------------------------

pub const gbm = struct {
    pub const FORMAT_XRGB8888: u32 = 0x34325258; // == DRM_FORMAT_XRGB8888
    pub const BO_USE_SCANOUT: u32 = 1 << 0;
    pub const BO_USE_RENDERING: u32 = 1 << 2;
};

pub const egl = struct {
    pub const NONE: i32 = 0x3038;
    pub const WIDTH: i32 = 0x3057;
    pub const HEIGHT: i32 = 0x3056;
    pub const RED_SIZE: i32 = 0x3024;
    pub const GREEN_SIZE: i32 = 0x3023;
    pub const BLUE_SIZE: i32 = 0x3022;
    pub const ALPHA_SIZE: i32 = 0x3021;
    pub const SURFACE_TYPE: i32 = 0x3033;
    pub const WINDOW_BIT: i32 = 0x0004;
    pub const RENDERABLE_TYPE: i32 = 0x3040;
    pub const OPENGL_ES2_BIT: i32 = 0x0004;
    pub const CONTEXT_CLIENT_VERSION: i32 = 0x3098;
    pub const OPENGL_ES_API: u32 = 0x30A0;
    // EGL_EXT_image_dma_buf_import
    pub const LINUX_DMA_BUF_EXT: u32 = 0x3270;
    pub const LINUX_DRM_FOURCC_EXT: i32 = 0x3271;
    pub const DMA_BUF_PLANE0_FD_EXT: i32 = 0x3272;
    pub const DMA_BUF_PLANE0_OFFSET_EXT: i32 = 0x3273;
    pub const DMA_BUF_PLANE0_PITCH_EXT: i32 = 0x3274;
    // EGL_EXT_image_dma_buf_import_modifiers
    pub const DMA_BUF_PLANE0_MODIFIER_LO_EXT: i32 = 0x3443;
    pub const DMA_BUF_PLANE0_MODIFIER_HI_EXT: i32 = 0x3444;
    // EGL_EXT_buffer_age: age of the back buffer contents in frames
    // (0 = undefined). Drives damage-only presentation (M8.2).
    pub const BUFFER_AGE_EXT: i32 = 0x313D;
};

pub const gl = struct {
    pub const FALSE: u32 = 0;
    pub const TRUE: u32 = 1;
    pub const TRIANGLE_STRIP: u32 = 0x0005;
    pub const COLOR_BUFFER_BIT: u32 = 0x4000;
    pub const BLEND: u32 = 0x0BE2;
    pub const SCISSOR_TEST: u32 = 0x0C11;
    pub const SRC_ALPHA: u32 = 0x0302;
    pub const ONE_MINUS_SRC_ALPHA: u32 = 0x0303;
    pub const TEXTURE_2D: u32 = 0x0DE1;
    pub const TEXTURE0: u32 = 0x84C0;
    pub const TEXTURE_MAG_FILTER: u32 = 0x2800;
    pub const TEXTURE_MIN_FILTER: u32 = 0x2801;
    pub const TEXTURE_WRAP_S: u32 = 0x2802;
    pub const TEXTURE_WRAP_T: u32 = 0x2803;
    pub const NEAREST: i32 = 0x2600;
    pub const LINEAR: i32 = 0x2601;
    pub const CLAMP_TO_EDGE: i32 = 0x812F;
    pub const UNPACK_ALIGNMENT: u32 = 0x0CF5;
    pub const ALPHA: u32 = 0x1906;
    pub const RED: u32 = 0x1903;
    pub const RGBA: u32 = 0x1908;
    pub const BGRA: u32 = 0x80E1; // GL_EXT_texture_format_BGRA8888
    pub const UNSIGNED_BYTE: u32 = 0x1401;
    pub const FLOAT: u32 = 0x1406;
    pub const ARRAY_BUFFER: u32 = 0x8892;
    pub const STATIC_DRAW: u32 = 0x88E4;
    pub const FRAGMENT_SHADER: u32 = 0x8B30;
    pub const VERTEX_SHADER: u32 = 0x8B31;
    pub const COMPILE_STATUS: u32 = 0x8B81;
    pub const LINK_STATUS: u32 = 0x8B82;
};

/// DRM format modifiers (drm_fourcc.h). Linear / invalid import omits the
/// modifier attribs; a tiled bo passes its modifier through the modifiers ext.
pub const DRM_FORMAT_MOD_LINEAR: u64 = 0;
pub const DRM_FORMAT_MOD_INVALID: u64 = 0x00FF_FFFF_FFFF_FFFF;

// ---------------------------------------------------------------------------
// GBM seam
// ---------------------------------------------------------------------------

pub const GbmDevice = *anyopaque;
pub const GbmSurface = *anyopaque;
pub const GbmBo = *anyopaque;

/// Snapshot of a locked bo's scanout parameters. `handle` is the GEM handle on
/// the GBM device's fd (the primary fd here), `stride` the bytes per row.
pub const GbmBoInfo = struct {
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
    handle: u32,
    modifier: u64,
};

pub const GbmOps = struct {
    ctx: ?*anyopaque = null,

    create_device: *const fn (ctx: ?*anyopaque, fd: i32) anyerror!GbmDevice,
    destroy_device: *const fn (ctx: ?*anyopaque, dev: GbmDevice) void,
    surface_create: *const fn (ctx: ?*anyopaque, dev: GbmDevice, width: u32, height: u32, format: u32, flags: u32) anyerror!GbmSurface,
    surface_destroy: *const fn (ctx: ?*anyopaque, surf: GbmSurface) void,
    /// Must be called exactly once after eglSwapBuffers (gbm.h contract).
    lock_front_buffer: *const fn (ctx: ?*anyopaque, surf: GbmSurface) anyerror!GbmBo,
    release_buffer: *const fn (ctx: ?*anyopaque, surf: GbmSurface, bo: GbmBo) void,
    has_free_buffers: *const fn (ctx: ?*anyopaque, surf: GbmSurface) bool,
    bo_info: *const fn (ctx: ?*anyopaque, bo: GbmBo) GbmBoInfo,
    /// Export the bo as a dma-buf fd for EGLImage import; caller closes it.
    bo_get_fd: *const fn (ctx: ?*anyopaque, bo: GbmBo) anyerror!i32,
    close_fd: *const fn (ctx: ?*anyopaque, fd: i32) void,
};

// ---------------------------------------------------------------------------
// EGL seam
// ---------------------------------------------------------------------------

pub const EglDisplay = *anyopaque;
pub const EglConfig = *anyopaque;
pub const EglContext = *anyopaque;
pub const EglSurface = *anyopaque;
pub const EglImage = *anyopaque;

pub const EglOps = struct {
    ctx: ?*anyopaque = null,

    get_display: *const fn (ctx: ?*anyopaque, native: GbmDevice) anyerror!EglDisplay,
    initialize: *const fn (ctx: ?*anyopaque, dpy: EglDisplay) anyerror!void,
    terminate: *const fn (ctx: ?*anyopaque, dpy: EglDisplay) void,
    bind_api: *const fn (ctx: ?*anyopaque, api: u32) anyerror!void,
    /// Fill `configs` and return how many matched (0 = none).
    choose_config: *const fn (ctx: ?*anyopaque, dpy: EglDisplay, attribs: []const i32, configs: []EglConfig) anyerror!usize,
    create_context: *const fn (ctx: ?*anyopaque, dpy: EglDisplay, config: EglConfig, share: ?EglContext, attribs: []const i32) anyerror!EglContext,
    destroy_context: *const fn (ctx: ?*anyopaque, dpy: EglDisplay, context: EglContext) void,
    create_window_surface: *const fn (ctx: ?*anyopaque, dpy: EglDisplay, config: EglConfig, win: GbmSurface, attribs: []const i32) anyerror!EglSurface,
    destroy_surface: *const fn (ctx: ?*anyopaque, dpy: EglDisplay, surf: EglSurface) void,
    make_current: *const fn (ctx: ?*anyopaque, dpy: EglDisplay, draw: ?EglSurface, read: ?EglSurface, context: ?EglContext) anyerror!void,
    swap_buffers: *const fn (ctx: ?*anyopaque, dpy: EglDisplay, surf: EglSurface) anyerror!void,
    create_image: *const fn (ctx: ?*anyopaque, dpy: EglDisplay, context: ?EglContext, target: u32, buffer: ?*anyopaque, attribs: []const i32) anyerror!EglImage,
    destroy_image: *const fn (ctx: ?*anyopaque, dpy: EglDisplay, image: EglImage) void,
    /// EGL_BUFFER_AGE_EXT query: age of the back buffer in frames, or null
    /// when the query fails / the extension is absent (present everything).
    buffer_age: *const fn (ctx: ?*anyopaque, dpy: EglDisplay, surf: EglSurface) ?i32,
};

// ---------------------------------------------------------------------------
// GL seam (GLES2 + GL_OES_EGL_image)
// ---------------------------------------------------------------------------

pub const GlOps = struct {
    ctx: ?*anyopaque = null,

    create_shader: *const fn (ctx: ?*anyopaque, kind: u32) anyerror!u32,
    shader_source: *const fn (ctx: ?*anyopaque, shader: u32, src: [*:0]const u8) void,
    compile_shader: *const fn (ctx: ?*anyopaque, shader: u32) void,
    get_shaderiv: *const fn (ctx: ?*anyopaque, shader: u32, pname: u32, out: *i32) void,
    delete_shader: *const fn (ctx: ?*anyopaque, shader: u32) void,
    create_program: *const fn (ctx: ?*anyopaque) anyerror!u32,
    attach_shader: *const fn (ctx: ?*anyopaque, program: u32, shader: u32) void,
    link_program: *const fn (ctx: ?*anyopaque, program: u32) void,
    get_programiv: *const fn (ctx: ?*anyopaque, program: u32, pname: u32, out: *i32) void,
    use_program: *const fn (ctx: ?*anyopaque, program: u32) void,
    delete_program: *const fn (ctx: ?*anyopaque, program: u32) void,
    get_attrib_location: *const fn (ctx: ?*anyopaque, program: u32, name: [*:0]const u8) i32,
    get_uniform_location: *const fn (ctx: ?*anyopaque, program: u32, name: [*:0]const u8) i32,
    enable_vertex_attrib_array: *const fn (ctx: ?*anyopaque, index: u32) void,
    vertex_attrib_pointer: *const fn (ctx: ?*anyopaque, index: u32, size: i32, kind: u32, normalized: bool, stride: i32, ptr: ?*const anyopaque) void,
    gen_buffers: *const fn (ctx: ?*anyopaque, n: usize, ids: []u32) void,
    delete_buffers: *const fn (ctx: ?*anyopaque, n: usize, ids: []const u32) void,
    bind_buffer: *const fn (ctx: ?*anyopaque, target: u32, id: u32) void,
    buffer_data: *const fn (ctx: ?*anyopaque, target: u32, size: usize, data: ?*const anyopaque, usage: u32) void,
    uniform1i: *const fn (ctx: ?*anyopaque, loc: i32, v: i32) void,
    uniform1f: *const fn (ctx: ?*anyopaque, loc: i32, v: f32) void,
    uniform2f: *const fn (ctx: ?*anyopaque, loc: i32, x: f32, y: f32) void,
    uniform4f: *const fn (ctx: ?*anyopaque, loc: i32, x: f32, y: f32, z: f32, w: f32) void,
    draw_arrays: *const fn (ctx: ?*anyopaque, mode: u32, first: i32, count: i32) void,
    viewport: *const fn (ctx: ?*anyopaque, x: i32, y: i32, w: i32, h: i32) void,
    clear_color: *const fn (ctx: ?*anyopaque, r: f32, g: f32, b: f32, a: f32) void,
    clear: *const fn (ctx: ?*anyopaque, mask: u32) void,
    scissor: *const fn (ctx: ?*anyopaque, x: i32, y: i32, w: i32, h: i32) void,
    active_texture: *const fn (ctx: ?*anyopaque, unit: u32) void,
    gen_textures: *const fn (ctx: ?*anyopaque, n: usize, ids: []u32) void,
    delete_textures: *const fn (ctx: ?*anyopaque, n: usize, ids: []const u32) void,
    bind_texture: *const fn (ctx: ?*anyopaque, target: u32, id: u32) void,
    tex_image_2d: *const fn (ctx: ?*anyopaque, target: u32, level: i32, internalformat: i32, w: i32, h: i32, border: i32, format: u32, kind: u32, pixels: ?*const anyopaque) void,
    tex_sub_image_2d: *const fn (ctx: ?*anyopaque, target: u32, level: i32, x: i32, y: i32, w: i32, h: i32, format: u32, kind: u32, pixels: ?*const anyopaque) void,
    tex_parameteri: *const fn (ctx: ?*anyopaque, target: u32, pname: u32, param: i32) void,
    pixel_storei: *const fn (ctx: ?*anyopaque, pname: u32, param: i32) void,
    enable: *const fn (ctx: ?*anyopaque, cap: u32) void,
    disable: *const fn (ctx: ?*anyopaque, cap: u32) void,
    blend_func: *const fn (ctx: ?*anyopaque, src: u32, dst: u32) void,
    /// glEGLImageTargetTexture2DOES: bind an imported EGLImage to a texture.
    image_target_texture_2d: *const fn (ctx: ?*anyopaque, target: u32, image: EglImage) void,
    flush: *const fn (ctx: ?*anyopaque) void,
};

// ---------------------------------------------------------------------------
// GL renderer interface types (the hooks the renderer layer calls)
// ---------------------------------------------------------------------------

/// One cell quad. `x/y/w/h` is the destination rect in framebuffer pixels
/// (top-left origin); `sx/sy/sw/sh` the source rect in atlas pixels; `page`
/// selects the atlas page (0 = a8 coverage, 1 = bgra8 color). `fg` is the
/// 0xRRGGBB tint for coverage glyphs (ignored for color glyphs).
pub const Cell = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    sx: u16,
    sy: u16,
    sw: u16,
    sh: u16,
    page: u8,
    fg: u32 = 0xFFFFFF,
};

/// An RGBA8 image for `drawImage`: tightly packed row-major, exactly
/// width*height*4 bytes (the render/image.zig `Image` layout).
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
};

// ---------------------------------------------------------------------------
// Enumeration state (mirrors drm2d; the helpers there are private, so the
// snapshot->Conn logic is replicated against the shared drm2d seam types).
// ---------------------------------------------------------------------------

fn dpmsValue(state: DpmsState) u64 {
    return switch (state) {
        .on => drmc.DPMS_ON,
        .standby => drmc.DPMS_STANDBY,
        .suspend_ => drmc.DPMS_SUSPEND,
        .off => drmc.DPMS_OFF,
    };
}

fn toVideoMode(m: ModeInfo, mm_width: u32, mm_height: u32) Mode {
    var refresh_mhz: u32 = m.vrefresh *| 1000;
    const htotal: u64 = m.htotal;
    const vtotal: u64 = m.vtotal;
    if (m.clock > 0 and htotal > 0 and vtotal > 0) {
        const mhz = @as(u64, m.clock) * 1_000_000 / (htotal * vtotal);
        refresh_mhz = @intCast(@min(mhz, std.math.maxInt(u32)));
    }
    return .{
        .width_px = m.hdisplay,
        .height_px = m.vdisplay,
        .refresh_mhz = refresh_mhz,
        .width_mm = mm_width,
        .height_mm = mm_height,
    };
}

const Conn = struct {
    id: u32,
    connector_type: u32,
    type_id: u32,
    connected: bool,
    mm_width: u32,
    mm_height: u32,
    encoder_id: u32,
    encoders: []u32,
    modes: []ModeInfo,
    info_modes: []Mode,
    name: []u8,
    dpms_prop_id: ?u32,
    /// Index into `modes` of the mode the connector is currently driven at,
    /// recovered from its bound CRTC (use-original-mode); null when unknown.
    current_mode: ?usize = null,

    fn deinit(self: *Conn, allocator: Allocator) void {
        allocator.free(self.encoders);
        allocator.free(self.modes);
        allocator.free(self.info_modes);
        allocator.free(self.name);
        self.* = undefined;
    }
};

fn freeConns(allocator: Allocator, conns: []Conn) void {
    for (conns) |*c| c.deinit(allocator);
    allocator.free(conns);
}

fn enumerateConnectors(allocator: Allocator, ops: DrmOps, fd: i32, res: *const Resources, force_probe: bool) ![]Conn {
    var list: std.ArrayList(Conn) = .empty;
    errdefer {
        for (list.items) |*c| c.deinit(allocator);
        list.deinit(allocator);
    }
    for (res.connectors) |cid| {
        var snap = ops.get_connector(ops.ctx, fd, allocator, cid, force_probe) catch continue;
        defer snap.deinit(allocator);
        try list.append(allocator, try connFromSnapshot(allocator, ops, fd, &snap));
    }
    return list.toOwnedSlice(allocator);
}

fn connFromSnapshot(allocator: Allocator, ops: DrmOps, fd: i32, snap: *const Connector) !Conn {
    const type_name = connectorTypeName(snap.connector_type) orelse "Unknown";
    const name = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ type_name, snap.connector_type_id });
    errdefer allocator.free(name);

    const modes = try allocator.dupe(ModeInfo, snap.modes);
    errdefer allocator.free(modes);

    const info_modes = try allocator.alloc(Mode, modes.len);
    errdefer allocator.free(info_modes);
    for (modes, 0..) |m, i| info_modes[i] = toVideoMode(m, snap.mm_width, snap.mm_height);

    const encoders = try allocator.dupe(u32, snap.encoders);
    errdefer allocator.free(encoders);

    var dpms_prop_id: ?u32 = null;
    if (snap.connection == .connected) {
        for (snap.props) |p| {
            const prop = ops.get_property(ops.ctx, fd, p.id) catch continue;
            if (std.mem.eql(u8, prop.nameSlice(), "DPMS")) {
                dpms_prop_id = prop.prop_id;
                break;
            }
        }
    }

    // Current mode (use-original-mode, recipes §2.4): follow the bound
    // encoder to its CRTC and match the live mode by resolution + clock.
    // Skipped when the seam lacks get_crtc (current_mode stays null).
    var current_mode: ?usize = null;
    if (snap.connection == .connected and snap.encoder_id != 0) {
        if (ops.get_crtc) |get_crtc| {
            if (ops.get_encoder(ops.ctx, fd, snap.encoder_id)) |enc| {
                if (enc.crtc_id != 0) {
                    if (get_crtc(ops.ctx, fd, enc.crtc_id)) |crtc| {
                        if (crtc.mode_valid) {
                            for (modes, 0..) |m, i| {
                                if (m.hdisplay == crtc.mode.hdisplay and
                                    m.vdisplay == crtc.mode.vdisplay and
                                    m.clock == crtc.mode.clock)
                                {
                                    current_mode = i;
                                    break;
                                }
                            }
                        }
                    } else |_| {}
                }
            } else |_| {}
        }
    }

    return .{
        .id = snap.connector_id,
        .connector_type = snap.connector_type,
        .type_id = snap.connector_type_id,
        .connected = snap.connection == .connected,
        .mm_width = snap.mm_width,
        .mm_height = snap.mm_height,
        .encoder_id = snap.encoder_id,
        .encoders = encoders,
        .modes = modes,
        .info_modes = info_modes,
        .name = name,
        .dpms_prop_id = dpms_prop_id,
        .current_mode = current_mode,
    };
}

fn buildInfos(allocator: Allocator, conns: []const Conn, card_path: []const u8) ![]ConnectorInfo {
    const infos = try allocator.alloc(ConnectorInfo, conns.len);
    errdefer allocator.free(infos);
    const card_name = std.fs.path.basename(card_path);
    for (conns, 0..) |c, i| {
        var preferred: ?usize = null;
        for (c.modes, 0..) |m, j| {
            if (m.isPreferred()) {
                preferred = j;
                break;
            }
        }
        if (preferred == null and c.modes.len > 0) preferred = 0;
        infos[i] = .{
            .name = c.name,
            .card_name = card_name,
            .connected = c.connected,
            .modes = c.info_modes,
            .preferred_mode = preferred,
            .current_mode = c.current_mode,
        };
    }
    return infos;
}

const Crtc = struct { id: u32, index: usize };

/// Cached GL uniform/attrib locations for the textured-quad program.
const QuadProgram = struct {
    program: u32,
    a_pos: u32,
    u_dst: i32,
    u_src: i32,
    u_viewport: i32,
    u_texsize: i32,
    u_color: i32,
    u_opacity: i32,
    u_coverage: i32,
    u_tex: i32,
};

/// The DRM hardware-accelerated backend. One instance per card; M5.1 drives
/// the first connected connector (multi-output is the layout layer's job).
///
/// Lifecycle: init (open, enumerate read-only, GBM device + EGL context) ->
/// takeMaster -> setMode (GBM surface + prime + SetCrtc) -> frame loop ->
/// dropMaster -> deinit.
pub const Drm3d = struct {
    allocator: Allocator,
    ops: DrmOps,
    gbm_ops: GbmOps,
    egl_ops: EglOps,
    gl_ops: GlOps,
    fd: i32,
    card_path: []u8,
    card_name: []u8,
    master: bool = false,

    resources: Resources,
    conns: []Conn,
    infos: []ConnectorInfo,
    chosen: ?usize,

    active: ?Active = null,
    dpms: DpmsState = .on,

    // GBM / EGL objects (device + context live from init; surface per mode).
    gbm_dev: GbmDevice,
    egl_dpy: EglDisplay,
    egl_config: EglConfig,
    egl_ctx: EglContext,
    gbm_surf: ?GbmSurface = null,
    egl_surf: ?EglSurface = null,

    // Scanout bo state. `scanout` is the bo currently on screen (locked);
    // `flipping` is the bo the in-flight flip targets (locked). The previous
    // scanout bo is released when the flip completes.
    scanout: ?GbmBo = null,
    flipping: ?GbmBo = null,
    flip_pending: bool = false,
    full_redraw: bool = true,
    /// Hotplug event source (M5.5), created by enableHotplug.
    hotplug: ?Hotplug = null,
    /// bo pointer -> fb id, for the life of the current GBM surface.
    fb_cache: std.AutoHashMap(usize, u32),

    // CPU staging buffer handed out by beginFrame (Renderer contract).
    staging: ?Framebuffer = null,
    /// True when drawCells/drawImage rendered this frame (skip staging upload).
    gl_frame: bool = false,
    /// True when drawCells/drawImage already cleared the target this frame
    /// (beginFrame no longer clears; see presentStaging).
    frame_cleared: bool = false,
    /// Logical damage of the last frames, newest first (M8.2). GBM recycles
    /// scanout bos: the back buffer holds the frame from `age` swaps ago
    /// (EGL_EXT_buffer_age), so presenting it needs the union of the last
    /// `age` frames' damage. Entries store the renderer's damage, not the
    /// (possibly larger) region actually redrawn.
    damage_history: [damage_history_len]DamageEntry = @splat(DamageEntry{}),
    history_len: usize = 0,
    /// Scratch for the merged present rects (effectiveDamage output).
    present_rects: [present_rect_cap]Damage = undefined,
    /// Tight row-copy scratch for sub-width staging uploads (GLES2 has no
    /// UNPACK_ROW_LENGTH). Grows on demand, freed in deinit.
    upload_scratch: []u8 = &.{},

    // GL objects.
    quad: ?QuadProgram = null,
    quad_vbo: u32 = 0,
    atlas_a8_tex: u32 = 0,
    atlas_bgra_tex: u32 = 0,
    atlas_w: u16 = 0,
    atlas_h: u16 = 0,
    atlas_generation: u64 = 0,
    atlas_have_gen: bool = false,
    staging_tex: u32 = 0,
    /// Allocated size of staging_tex: partial uploads need a stable storage
    /// allocation, reallocated only when the staging size changes.
    staging_tex_w: u32 = 0,
    staging_tex_h: u32 = 0,
    image_tex: u32 = 0,
    presented_tex: u32 = 0,
    presented_image: ?EglImage = null,

    const flip_cookie: u64 = 0x4B4D_5348_4155_4E54; // "KMSHAUNT"

    const Active = struct {
        connector_id: u32,
        mode_idx: usize,
        crtc_id: u32,
        crtc_index: usize,
        mode: ModeInfo,
    };

    /// One frame of logical damage, clipped + merged. `full` marks an unknown
    /// delta (empty damage = present everything, or a GL-drawn frame).
    const DamageEntry = struct {
        full: bool = true,
        n: usize = 0,
        rects: [damage_entry_cap]Damage = undefined,
    };

    const damage_history_len = 8; // frames kept for buffer-age replay
    const damage_entry_cap = 16; // merged rects per frame; more = full frame
    const present_rect_cap = 64; // merged rects per present; more = full frame

    /// Open the card, enumerate read-only, create the GBM device and the EGL
    /// display/config/context. The GBM surface + window surface are created in
    /// setMode (they are mode-sized). Master is NOT taken here (the seat calls
    /// takeMaster). Returns error.NoConnectedDisplay when nothing is connected,
    /// error.Unsupported when GBM/EGL/GLES2 cannot be brought up.
    pub fn init(allocator: Allocator, card_path: ?[]const u8, ops: DrmOps, gbm_ops: GbmOps, egl_ops: EglOps, gl_ops: GlOps) !*Drm3d {
        const path = card_path orelse "/dev/dri/card0";
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);

        const fd = try ops.open(ops.ctx, path_z.ptr);
        errdefer ops.close(ops.ctx, fd);

        ops.set_client_cap(ops.ctx, fd, drmc.CLIENT_CAP_UNIVERSAL_PLANES, 1) catch {};

        const card_path_owned = try allocator.dupe(u8, path);
        errdefer allocator.free(card_path_owned);
        const card_name_owned = try allocator.dupe(u8, std.fs.path.basename(path));
        errdefer allocator.free(card_name_owned);

        var resources = try ops.get_resources(ops.ctx, fd, allocator);
        errdefer resources.deinit(allocator);
        const conns = try enumerateConnectors(allocator, ops, fd, &resources, false);
        errdefer freeConns(allocator, conns);
        const infos = try buildInfos(allocator, conns, card_path_owned);
        errdefer allocator.free(infos);

        const chosen = for (conns, 0..) |c, i| {
            if (c.connected and c.modes.len > 0) break i;
        } else null;
        if (chosen == null) return error.NoConnectedDisplay;

        // GBM device on the primary fd; EGL display on the GBM device.
        const gbm_dev = try gbm_ops.create_device(gbm_ops.ctx, fd);
        errdefer gbm_ops.destroy_device(gbm_ops.ctx, gbm_dev);
        const egl_dpy = try egl_ops.get_display(egl_ops.ctx, gbm_dev);
        try egl_ops.initialize(egl_ops.ctx, egl_dpy);
        errdefer egl_ops.terminate(egl_ops.ctx, egl_dpy);
        try egl_ops.bind_api(egl_ops.ctx, egl.OPENGL_ES_API);

        const config_attribs = [_]i32{
            egl.SURFACE_TYPE,     egl.WINDOW_BIT,
            egl.RENDERABLE_TYPE,  egl.OPENGL_ES2_BIT,
            egl.RED_SIZE,         8,
            egl.GREEN_SIZE,       8,
            egl.BLUE_SIZE,        8,
            egl.ALPHA_SIZE,       8,
            egl.NONE,
        };
        var configs: [1]EglConfig = undefined;
        const n = try egl_ops.choose_config(egl_ops.ctx, egl_dpy, &config_attribs, &configs);
        if (n == 0) return error.Unsupported;
        const egl_config = configs[0];

        const ctx_attribs = [_]i32{ egl.CONTEXT_CLIENT_VERSION, 2, egl.NONE };
        const egl_ctx = try egl_ops.create_context(egl_ops.ctx, egl_dpy, egl_config, null, &ctx_attribs);
        errdefer egl_ops.destroy_context(egl_ops.ctx, egl_dpy, egl_ctx);

        const self = try allocator.create(Drm3d);
        self.* = .{
            .allocator = allocator,
            .ops = ops,
            .gbm_ops = gbm_ops,
            .egl_ops = egl_ops,
            .gl_ops = gl_ops,
            .fd = fd,
            .card_path = card_path_owned,
            .card_name = card_name_owned,
            .resources = resources,
            .conns = conns,
            .infos = infos,
            .chosen = chosen,
            .gbm_dev = gbm_dev,
            .egl_dpy = egl_dpy,
            .egl_config = egl_config,
            .egl_ctx = egl_ctx,
            .fb_cache = std.AutoHashMap(usize, u32).init(allocator),
        };
        return self;
    }

    /// Release everything. Order: wait for flips, release locked bos, drop
    /// master, tear down GL (context still current), unbind, destroy the EGL
    /// surface/context, terminate EGL, RmFB the cached fbs, destroy the GBM
    /// surface then device, free enumeration + staging, close the fd.
    pub fn deinit(self: *Drm3d) void {
        if (self.flip_pending) self.waitFlip() catch {};
        self.releaseLockedBuffers();
        if (self.hotplug) |*h| h.deinit();
        self.ops.drop_master(self.ops.ctx, self.fd) catch {};

        self.destroyGl();
        self.egl_ops.make_current(self.egl_ops.ctx, self.egl_dpy, null, null, null) catch {};
        if (self.egl_surf) |s| self.egl_ops.destroy_surface(self.egl_ops.ctx, self.egl_dpy, s);
        self.egl_ops.destroy_context(self.egl_ops.ctx, self.egl_dpy, self.egl_ctx);
        self.egl_ops.terminate(self.egl_ops.ctx, self.egl_dpy);

        self.removeCachedFbs();
        if (self.gbm_surf) |s| self.gbm_ops.surface_destroy(self.gbm_ops.ctx, s);
        self.gbm_ops.destroy_device(self.gbm_ops.ctx, self.gbm_dev);

        if (self.staging) |*s| s.destroy(self.allocator);
        if (self.upload_scratch.len > 0) self.allocator.free(self.upload_scratch);
        self.fb_cache.deinit();
        freeConns(self.allocator, self.conns);
        self.allocator.free(self.infos);
        self.resources.deinit(self.allocator);
        self.allocator.free(self.card_path);
        self.allocator.free(self.card_name);
        self.ops.close(self.ops.ctx, self.fd);
        self.allocator.destroy(self);
    }

    pub fn backend(self: *Drm3d) video.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The DRM fd for the epoll loop; on readability call readEvents.
    pub fn eventFd(self: *const Drm3d) i32 {
        return self.fd;
    }

    /// Choose a mode index for connector `connector_idx` (M5.3), identical
    /// to drm2d: a matching mode= spec, else use-original-mode keeps the
    /// current mode, else preferred, else mode 0 (layout.selectMode). Null
    /// when the connector has no modes.
    pub fn selectModeIndex(self: *const Drm3d, connector_idx: usize, spec: ?video.ModeSpec, use_original: bool) !?usize {
        if (connector_idx >= self.conns.len) return null;
        const conn = &self.conns[connector_idx];
        if (conn.info_modes.len == 0) return null;
        const candidates = try self.allocator.alloc(video.layout.ModeCandidate, conn.info_modes.len);
        defer self.allocator.free(candidates);
        for (conn.info_modes, 0..) |m, i| {
            candidates[i] = .{
                .width = m.width_px,
                .height = m.height_px,
                .refresh_hz = (m.refresh_mhz + 500) / 1000,
            };
        }
        var preferred: ?usize = null;
        for (conn.modes, 0..) |m, j| {
            if (m.isPreferred()) {
                preferred = j;
                break;
            }
        }
        if (preferred == null) preferred = 0;
        return video.layout.selectMode(candidates, spec, use_original, preferred, conn.current_mode);
    }

    /// Enable the hotplug event source (M5.5); see drm2d.enableHotplug. The
    /// loop polls hotplugFd() and re-probes via connectors() on events.
    pub fn enableHotplug(self: *Drm3d, ops: HotplugOps) !void {
        if (self.hotplug != null) return;
        self.hotplug = try Hotplug.init(ops);
    }

    /// The hotplug monitor fd for the epoll loop, or null when not enabled.
    pub fn hotplugFd(self: *const Drm3d) ?i32 {
        if (self.hotplug) |*h| return h.fd();
        return null;
    }

    /// Drain pending hotplug events; true when at least one arrived.
    pub fn pollHotplug(self: *Drm3d) !bool {
        if (self.hotplug) |*h| return h.poll();
        return false;
    }

    // ------------------------------------------------------------------
    // Master handoff (mirrors drm2d, constraints #2/#3)
    // ------------------------------------------------------------------

    pub fn takeMaster(self: *Drm3d) !void {
        if (self.master) return;
        const already = self.ops.is_master(self.ops.ctx, self.fd) catch false;
        if (!already) try self.ops.set_master(self.ops.ctx, self.fd);
        self.master = true;
        _ = try self.connectors();
        if (self.active) |act| {
            if (self.scanout) |bo| {
                const fb_id = try self.fbIdFor(bo);
                try self.ops.set_crtc(self.ops.ctx, self.fd, act.crtc_id, fb_id, 0, 0, &.{act.connector_id}, &act.mode);
                self.full_redraw = true;
                if (self.dpms != .on) try self.applyDpms(self.dpms);
            }
        }
    }

    pub fn dropMaster(self: *Drm3d) !void {
        if (!self.master) return;
        if (self.flip_pending) self.waitFlip() catch {};
        self.ops.drop_master(self.ops.ctx, self.fd) catch |err| switch (err) {
            error.InvalidArgument => {},
            else => return err,
        };
        self.master = false;
    }

    pub fn isMaster(self: *const Drm3d) bool {
        return self.master;
    }

    // ------------------------------------------------------------------
    // Enumeration (constraint #14: re-enumerate only)
    // ------------------------------------------------------------------

    pub fn connectors(self: *Drm3d) ![]const ConnectorInfo {
        var new_res = try self.ops.get_resources(self.ops.ctx, self.fd, self.allocator);
        errdefer new_res.deinit(self.allocator);
        const new_conns = try enumerateConnectors(self.allocator, self.ops, self.fd, &new_res, self.master);
        errdefer freeConns(self.allocator, new_conns);
        const new_infos = try buildInfos(self.allocator, new_conns, self.card_path);
        errdefer self.allocator.free(new_infos);

        self.resources.deinit(self.allocator);
        freeConns(self.allocator, self.conns);
        self.allocator.free(self.infos);
        self.resources = new_res;
        self.conns = new_conns;
        self.infos = new_infos;

        if (self.active) |act| {
            const idx = self.connIndex(act.connector_id);
            const still_connected = if (idx) |i| self.conns[i].connected else false;
            if (idx) |i| self.infos[i].current_mode = act.mode_idx;
            if (!still_connected and !self.flip_pending) {
                self.teardownDisplay();
                self.active = null;
            }
        }
        return self.infos;
    }

    fn connIndex(self: *const Drm3d, connector_id: u32) ?usize {
        for (self.conns, 0..) |c, i| {
            if (c.id == connector_id) return i;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Modeset
    // ------------------------------------------------------------------

    /// Modeset connector `connector_idx` to `mode_idx`. Recreates the GBM
    /// surface + EGL window surface at the new size, primes a first bo and
    /// runs SetCrtc before any flip (constraint #5). Requires master.
    pub fn setMode(self: *Drm3d, connector_idx: usize, mode_idx: usize) !void {
        if (connector_idx >= self.conns.len) return error.InvalidConnector;
        const conn = &self.conns[connector_idx];
        if (!conn.connected) return error.NotConnected;
        if (mode_idx >= conn.modes.len) return error.InvalidMode;
        const mode = conn.modes[mode_idx];
        if (mode.hdisplay == 0 or mode.vdisplay == 0) return error.InvalidMode;

        const crtc = try self.findCrtc(conn);
        if (self.flip_pending) try self.waitFlip();

        self.teardownDisplay();

        const surf = try self.gbm_ops.surface_create(
            self.gbm_ops.ctx,
            self.gbm_dev,
            mode.hdisplay,
            mode.vdisplay,
            gbm.FORMAT_XRGB8888,
            gbm.BO_USE_SCANOUT | gbm.BO_USE_RENDERING,
        );
        self.gbm_surf = surf;
        errdefer {
            self.gbm_ops.surface_destroy(self.gbm_ops.ctx, surf);
            self.gbm_surf = null;
        }

        const win = try self.egl_ops.create_window_surface(self.egl_ops.ctx, self.egl_dpy, self.egl_config, surf, &.{egl.NONE});
        self.egl_surf = win;
        errdefer {
            self.egl_ops.destroy_surface(self.egl_ops.ctx, self.egl_dpy, win);
            self.egl_surf = null;
        }
        try self.egl_ops.make_current(self.egl_ops.ctx, self.egl_dpy, win, win, self.egl_ctx);

        // (Re)allocate the CPU staging buffer at the mode size.
        if (self.staging) |*s| s.destroy(self.allocator);
        self.staging = try Framebuffer.create(self.allocator, mode.hdisplay, mode.vdisplay, .xrgb8888, null);

        try self.initGl();
        self.gl_ops.viewport(self.gl_ops.ctx, 0, 0, @intCast(mode.hdisplay), @intCast(mode.vdisplay));

        // Prime: render a clear frame, swap, lock the first bo, AddFB. This
        // gives SetCrtc a valid fb before any page flip (constraint #5).
        self.gl_ops.disable(self.gl_ops.ctx, gl.SCISSOR_TEST);
        self.gl_ops.clear_color(self.gl_ops.ctx, 0, 0, 0, 1);
        self.gl_ops.clear(self.gl_ops.ctx, gl.COLOR_BUFFER_BIT);
        const bo = try self.swapAndLock();
        const fb_id = try self.fbIdFor(bo);
        self.ops.set_crtc(self.ops.ctx, self.fd, crtc.id, fb_id, 0, 0, &.{conn.id}, &mode) catch |err| {
            self.gbm_ops.release_buffer(self.gbm_ops.ctx, surf, bo);
            return err;
        };
        self.scanout = bo;

        self.active = .{
            .connector_id = conn.id,
            .mode_idx = mode_idx,
            .crtc_id = crtc.id,
            .crtc_index = crtc.index,
            .mode = mode,
        };
        self.flip_pending = false;
        self.full_redraw = true;
        self.history_len = 0;
        self.infos[connector_idx].current_mode = mode_idx;

        if (self.dpms != .on) try self.applyDpms(self.dpms);
    }

    fn findCrtc(self: *Drm3d, conn: *const Conn) !Crtc {
        if (conn.encoder_id != 0) {
            if (self.ops.get_encoder(self.ops.ctx, self.fd, conn.encoder_id)) |enc| {
                if (enc.crtc_id != 0) {
                    for (self.resources.crtcs, 0..) |cid, j| {
                        if (cid == enc.crtc_id) return .{ .id = cid, .index = j };
                    }
                }
            } else |_| {}
        }
        for (conn.encoders) |eid| {
            const enc = self.ops.get_encoder(self.ops.ctx, self.fd, eid) catch continue;
            for (self.resources.crtcs, 0..) |cid, j| {
                if (j >= 32) break;
                if (enc.possible_crtcs & (@as(u32, 1) << @intCast(j)) != 0) {
                    return .{ .id = cid, .index = j };
                }
            }
        }
        return error.NoCrtcAvailable;
    }

    // ------------------------------------------------------------------
    // Frame loop
    // ------------------------------------------------------------------

    /// The CPU staging buffer to draw into (Renderer contract). error.Busy
    /// while a flip is in flight or no GBM bo is free to render into. Does
    /// NOT clear the target: the back buffer is a recycled GBM bo whose
    /// contents outside the damage must survive (M8.2). The staging path
    /// scissor-clears its rects in endFrame; the GL hooks clear lazily on
    /// the first draw of the frame.
    pub fn beginFrame(self: *Drm3d) !*Framebuffer {
        if (self.active == null) return error.NoActiveDisplay;
        if (self.flip_pending) return error.Busy;
        const surf = self.gbm_surf orelse return error.NoActiveDisplay;
        if (!self.gbm_ops.has_free_buffers(self.gbm_ops.ctx, surf)) return error.Busy;
        try self.egl_ops.make_current(self.egl_ops.ctx, self.egl_dpy, self.egl_surf, self.egl_surf, self.egl_ctx);
        self.gl_frame = false;
        self.frame_cleared = false;
        return &self.staging.?;
    }

    /// Submit a page flip presenting the rendered frame (returns once
    /// SUBMITTED), restricted to `damage` (empty slice = present everything,
    /// video.Backend contract). The CPU staging path redraws only the damage
    /// rects plus the buffer-age replay (M8.2); a GL-drawn frame is already
    /// on the target and presents whole. Then swap -> lock -> EGLImage ->
    /// AddFB -> flip. EBUSY keeps pending set (constraint #4). Refuses while
    /// off (recipes §7.2.3).
    pub fn endFrame(self: *Drm3d, damage: []const Damage) !void {
        const act = self.active orelse return error.NoActiveDisplay;
        if (self.flip_pending) return error.Busy;
        if (self.dpms != .on) return error.DisplayOff;

        if (!self.gl_frame) {
            const rects = self.effectiveDamage(damage, act);
            self.presentStaging(rects) catch |err| {
                // The back buffer may be partially drawn: go full next frame.
                self.full_redraw = true;
                return err;
            };
        }

        const bo = self.swapAndLock() catch |err| {
            self.full_redraw = true;
            return err;
        };
        // The swap landed: this frame's content is in the bo regardless of
        // the flip outcome below (EBUSY keeps it locked for the retry).
        // Record the logical delta: empty damage / GL frames are unknown.
        self.pushDamageHistory(damage, self.gl_frame or damage.len == 0);
        try self.importPresentedBo(bo);
        const fb_id = try self.fbIdFor(bo);

        self.ops.page_flip(self.ops.ctx, self.fd, act.crtc_id, fb_id, drmc.PAGE_FLIP_EVENT, flip_cookie) catch |err| switch (err) {
            error.Busy => {
                self.flip_pending = true;
                self.flipping = bo;
                return error.Busy;
            },
            else => {
                // The flip was not submitted: give the bo back to the surface.
                self.gbm_ops.release_buffer(self.gbm_ops.ctx, self.gbm_surf.?, bo);
                return err;
            },
        };
        self.flip_pending = true;
        self.flipping = bo;
        self.full_redraw = false;
    }

    // ------------------------------------------------------------------
    // Damage-only presentation (M8.2)
    // ------------------------------------------------------------------

    /// The region endFrame must redraw, or null for a full frame. GBM
    /// recycles scanout bos, so the back buffer holds the frame from `age`
    /// swaps ago (EGL_EXT_buffer_age); presenting it needs the union of the
    /// last `age` frames' logical damage (this frame + age-1 history).
    /// Full frame when: full_redraw, empty damage (contract), unknown age,
    /// insufficient history, or too many rects to merge. An empty result
    /// means the back buffer is already current (present without drawing).
    fn effectiveDamage(self: *Drm3d, damage: []const Damage, act: Active) ?[]const Damage {
        if (self.full_redraw or damage.len == 0) return null;
        const win = self.egl_surf orelse return null;
        const age = self.egl_ops.buffer_age(self.egl_ops.ctx, self.egl_dpy, win) orelse return null;
        if (age <= 0) return null; // undefined back buffer contents
        const history: usize = @intCast(age - 1);
        if (history > self.history_len) return null;

        var n = collectClipped(damage, act.mode.hdisplay, act.mode.vdisplay, &self.present_rects);
        if (n > present_rect_cap) return null;
        for (self.damage_history[0..history]) |*e| {
            if (e.full) return null;
            if (n + e.n > present_rect_cap) return null;
            @memcpy(self.present_rects[n..][0..e.n], e.rects[0..e.n]);
            n += e.n;
        }
        n = coalesceRects(self.present_rects[0..n]);
        return self.present_rects[0..n];
    }

    /// Record this frame's logical damage (the renderer's delta, NOT the
    /// region actually redrawn) for future buffer-age replays. `full` marks
    /// an unknown delta: empty damage presents everything, and GL-drawn
    /// frames are composited by the renderer, not the backend.
    fn pushDamageHistory(self: *Drm3d, damage: []const Damage, full: bool) void {
        var i = @min(self.history_len, damage_history_len - 1);
        while (i > 0) : (i -= 1) self.damage_history[i] = self.damage_history[i - 1];
        self.history_len = @min(self.history_len + 1, damage_history_len);
        var e = &self.damage_history[0];
        e.* = .{};
        if (full) return;
        const act = self.active orelse return;
        var n = collectClipped(damage, act.mode.hdisplay, act.mode.vdisplay, &self.present_rects);
        if (n > present_rect_cap) return;
        n = coalesceRects(self.present_rects[0..n]);
        if (n > damage_entry_cap) return;
        e.full = false;
        e.n = n;
        @memcpy(e.rects[0..n], self.present_rects[0..n]);
    }

    /// The first draw of a GL-drawn frame clears the whole target (the
    /// beginFrame clear moved here so damage-only staging frames keep the
    /// recycled back buffer outside their rects).
    fn clearForGlFrame(self: *Drm3d) void {
        if (self.frame_cleared) return;
        self.frame_cleared = true;
        const g = self.gl_ops;
        g.disable(g.ctx, gl.SCISSOR_TEST);
        g.clear_color(g.ctx, 0, 0, 0, 1);
        g.clear(g.ctx, gl.COLOR_BUFFER_BIT);
    }

    /// Clip damage to the mode, dropping empty/out-of-bounds rects. Returns
    /// the count, or out.len + 1 when the input does not fit.
    fn collectClipped(damage: []const Damage, w: u32, h: u32, out: []Damage) usize {
        var n: usize = 0;
        for (damage) |d| {
            const c = d.clipTo(w, h) orelse continue;
            if (n == out.len) return out.len + 1;
            out[n] = c;
            n += 1;
        }
        return n;
    }

    /// Merge overlapping and edge-adjacent rects in place (half-open, like
    /// drm2d's DirtyFB clips); returns the merged count.
    fn coalesceRects(rects: []Damage) usize {
        var n = rects.len;
        var changed = true;
        while (changed) {
            changed = false;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var j = i + 1;
                while (j < n) {
                    if (rectsTouch(rects[i], rects[j])) {
                        rects[i] = rects[i].boundingBox(rects[j]);
                        rects[j] = rects[n - 1];
                        n -= 1;
                        changed = true;
                    } else j += 1;
                }
            }
        }
        return n;
    }

    /// Overlap or edge-adjacency for non-empty half-open rects.
    fn rectsTouch(a: Damage, b: Damage) bool {
        return a.x <= b.x + b.w and b.x <= a.x + a.w and
            a.y <= b.y + b.h and b.y <= a.y + a.h;
    }

    pub fn flipPending(self: *const Drm3d) bool {
        return self.flip_pending;
    }

    /// Block until the pending flip completes, bounded at 1000 ms (recipes
    /// §5.4). error.Timeout leaves the pending flag set.
    pub fn waitFlip(self: *Drm3d) !void {
        if (!self.flip_pending) return;
        var waited_ms: i32 = 0;
        while (self.flip_pending) {
            try self.readEvents();
            if (!self.flip_pending) return;
            if (waited_ms >= 1000) return error.Timeout;
            try self.ops.poll(self.ops.ctx, self.fd, 100);
            waited_ms += 100;
        }
    }

    /// Drain the DRM event fd. FLIP_COMPLETE for our CRTC + cookie clears the
    /// pending flag, releases the previous scanout bo and adopts the new one.
    pub fn readEvents(self: *Drm3d) !void {
        var buf: [1024]u8 align(8) = undefined;
        while (true) {
            const n = self.ops.read(self.ops.ctx, self.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (n == 0) return;
            try self.parseEvents(buf[0..n]);
            if (n < buf.len) return;
        }
    }

    fn parseEvents(self: *Drm3d, bytes: []const u8) !void {
        var off: usize = 0;
        while (off + 8 <= bytes.len) {
            const typ = std.mem.readInt(u32, bytes[off..][0..4], .little);
            const len = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
            if (len < 8 or off + len > bytes.len) return error.MalformedEvent;
            if (typ == drmc.EVENT_FLIP_COMPLETE and len >= 32) {
                const user_data = std.mem.readInt(u64, bytes[off + 8 ..][0..8], .little);
                const crtc_id = std.mem.readInt(u32, bytes[off + 28 ..][0..4], .little);
                if (user_data == flip_cookie and self.flip_pending) {
                    if (self.active) |act| {
                        if (crtc_id == 0 or crtc_id == act.crtc_id) {
                            self.completeFlip();
                        }
                    }
                }
            }
            off += len;
        }
    }

    /// The flip landed: release the bo that was on screen, adopt the new one.
    fn completeFlip(self: *Drm3d) void {
        const surf = self.gbm_surf orelse return;
        if (self.scanout) |old| {
            self.gbm_ops.release_buffer(self.gbm_ops.ctx, surf, old);
        }
        self.scanout = self.flipping;
        self.flipping = null;
        self.flip_pending = false;
    }

    pub fn needsFullRedraw(self: *const Drm3d) bool {
        return self.full_redraw;
    }

    // ------------------------------------------------------------------
    // DPMS (mirrors drm2d, constraint #5 wake re-modeset)
    // ------------------------------------------------------------------

    pub fn setDpms(self: *Drm3d, state: DpmsState) !void {
        const act = self.active orelse return error.NoActiveDisplay;
        const was = self.dpms;
        try self.applyDpms(state);
        self.dpms = state;
        if (state == .on and was != .on) {
            if (self.flip_pending) try self.waitFlip();
            if (self.scanout) |bo| {
                const fb_id = try self.fbIdFor(bo);
                try self.ops.set_crtc(self.ops.ctx, self.fd, act.crtc_id, fb_id, 0, 0, &.{act.connector_id}, &act.mode);
            }
            self.full_redraw = true;
        }
    }

    fn applyDpms(self: *Drm3d, state: DpmsState) !void {
        const act = self.active orelse return error.NoActiveDisplay;
        const idx = self.connIndex(act.connector_id) orelse return error.NoActiveDisplay;
        const prop_id = self.conns[idx].dpms_prop_id orelse return error.Unsupported;
        try self.ops.connector_set_property(self.ops.ctx, self.fd, act.connector_id, prop_id, dpmsValue(state));
    }

    pub fn dpmsState(self: *const Drm3d) DpmsState {
        return self.dpms;
    }

    // ------------------------------------------------------------------
    // Cursor: GL backend composites it in the renderer (software fallback).
    // ------------------------------------------------------------------

    pub fn setCursor(self: *Drm3d, img: ?*Framebuffer, x: i32, y: i32) !void {
        _ = self;
        _ = img;
        _ = x;
        _ = y;
        return error.Unsupported;
    }

    pub fn supportsHwCursor(self: *const Drm3d) bool {
        _ = self;
        return false;
    }

    // ------------------------------------------------------------------
    // GBM / EGL helpers
    // ------------------------------------------------------------------

    /// glFlush -> eglSwapBuffers -> lock_front_buffer (the gbm.h contract).
    fn swapAndLock(self: *Drm3d) !GbmBo {
        const surf = self.gbm_surf orelse return error.NoActiveDisplay;
        const win = self.egl_surf orelse return error.NoActiveDisplay;
        self.gl_ops.flush(self.gl_ops.ctx);
        try self.egl_ops.swap_buffers(self.egl_ops.ctx, self.egl_dpy, win);
        return self.gbm_ops.lock_front_buffer(self.gbm_ops.ctx, surf);
    }

    /// AddFB for a bo, cached by bo pointer for the surface's lifetime.
    fn fbIdFor(self: *Drm3d, bo: GbmBo) !u32 {
        const key = @intFromPtr(bo);
        if (self.fb_cache.get(key)) |id| return id;
        const info = self.gbm_ops.bo_info(self.gbm_ops.ctx, bo);
        const id = try self.ops.add_fb(self.ops.ctx, self.fd, info.width, info.height, 24, 32, info.stride, info.handle);
        try self.fb_cache.put(key, id);
        return id;
    }

    fn removeCachedFbs(self: *Drm3d) void {
        var it = self.fb_cache.valueIterator();
        while (it.next()) |id| {
            self.ops.rm_fb(self.ops.ctx, self.fd, id.*) catch {};
        }
        self.fb_cache.clearRetainingCapacity();
    }

    fn releaseLockedBuffers(self: *Drm3d) void {
        const surf = self.gbm_surf orelse return;
        if (self.scanout) |bo| {
            self.gbm_ops.release_buffer(self.gbm_ops.ctx, surf, bo);
            self.scanout = null;
        }
        if (self.flipping) |bo| {
            self.gbm_ops.release_buffer(self.gbm_ops.ctx, surf, bo);
            self.flipping = null;
        }
    }

    /// Import the locked front bo as an EGLImage (dma-buf + fourcc) and bind
    /// it to a GL texture. The previous frame's image is destroyed first. The
    /// dma-buf fd is closed after import (EGL takes its own reference).
    fn importPresentedBo(self: *Drm3d, bo: GbmBo) !void {
        const info = self.gbm_ops.bo_info(self.gbm_ops.ctx, bo);
        const dmabuf = try self.gbm_ops.bo_get_fd(self.gbm_ops.ctx, bo);
        defer self.gbm_ops.close_fd(self.gbm_ops.ctx, dmabuf);

        var attribs: [16]i32 = undefined;
        var n: usize = 0;
        attribs[n] = egl.WIDTH;
        attribs[n + 1] = @intCast(info.width);
        n += 2;
        attribs[n] = egl.HEIGHT;
        attribs[n + 1] = @intCast(info.height);
        n += 2;
        attribs[n] = egl.LINUX_DRM_FOURCC_EXT;
        attribs[n + 1] = @intCast(info.format);
        n += 2;
        attribs[n] = egl.DMA_BUF_PLANE0_FD_EXT;
        attribs[n + 1] = dmabuf;
        n += 2;
        attribs[n] = egl.DMA_BUF_PLANE0_OFFSET_EXT;
        attribs[n + 1] = 0;
        n += 2;
        attribs[n] = egl.DMA_BUF_PLANE0_PITCH_EXT;
        attribs[n + 1] = @intCast(info.stride);
        n += 2;
        if (info.modifier != DRM_FORMAT_MOD_LINEAR and info.modifier != DRM_FORMAT_MOD_INVALID) {
            attribs[n] = egl.DMA_BUF_PLANE0_MODIFIER_LO_EXT;
            attribs[n + 1] = @bitCast(@as(u32, @truncate(info.modifier)));
            n += 2;
            attribs[n] = egl.DMA_BUF_PLANE0_MODIFIER_HI_EXT;
            attribs[n + 1] = @bitCast(@as(u32, @truncate(info.modifier >> 32)));
            n += 2;
        }
        attribs[n] = egl.NONE;
        n += 1;

        const image = try self.egl_ops.create_image(
            self.egl_ops.ctx,
            self.egl_dpy,
            null, // EGL_NO_CONTEXT required for dma-buf import
            egl.LINUX_DMA_BUF_EXT,
            null, // buffer must be NULL for dma-buf import
            attribs[0..n],
        );
        errdefer self.egl_ops.destroy_image(self.egl_ops.ctx, self.egl_dpy, image);

        if (self.presented_tex == 0) {
            var ids: [1]u32 = undefined;
            self.gl_ops.gen_textures(self.gl_ops.ctx, 1, &ids);
            self.presented_tex = ids[0];
            self.gl_ops.bind_texture(self.gl_ops.ctx, gl.TEXTURE_2D, self.presented_tex);
            self.gl_ops.tex_parameteri(self.gl_ops.ctx, gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
            self.gl_ops.tex_parameteri(self.gl_ops.ctx, gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            self.gl_ops.tex_parameteri(self.gl_ops.ctx, gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            self.gl_ops.tex_parameteri(self.gl_ops.ctx, gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        } else {
            self.gl_ops.bind_texture(self.gl_ops.ctx, gl.TEXTURE_2D, self.presented_tex);
        }
        self.gl_ops.image_target_texture_2d(self.gl_ops.ctx, gl.TEXTURE_2D, image);

        if (self.presented_image) |old| {
            self.egl_ops.destroy_image(self.egl_ops.ctx, self.egl_dpy, old);
        }
        self.presented_image = image;
    }

    /// Tear down the per-mode display (surface + window surface + staging +
    /// cached fbs + locked bos). The EGL context and GL program survive a
    /// modeset; only the size-dependent objects are rebuilt.
    fn teardownDisplay(self: *Drm3d) void {
        self.releaseLockedBuffers();
        self.history_len = 0;
        if (self.presented_image) |img| {
            self.egl_ops.destroy_image(self.egl_ops.ctx, self.egl_dpy, img);
            self.presented_image = null;
        }
        self.removeCachedFbs();
        if (self.egl_surf) |s| {
            self.egl_ops.make_current(self.egl_ops.ctx, self.egl_dpy, null, null, self.egl_ctx) catch {};
            self.egl_ops.destroy_surface(self.egl_ops.ctx, self.egl_dpy, s);
            self.egl_surf = null;
        }
        if (self.gbm_surf) |s| {
            self.gbm_ops.surface_destroy(self.gbm_ops.ctx, s);
            self.gbm_surf = null;
        }
        if (self.staging) |*s| {
            s.destroy(self.allocator);
            self.staging = null;
        }
        self.scanout = null;
        self.flipping = null;
    }

    // ------------------------------------------------------------------
    // GL renderer (textured-quad plumbing)
    // ------------------------------------------------------------------

    const vertex_src: [*:0]const u8 =
        \\attribute vec2 a_pos;
        \\uniform vec4 u_dst;
        \\uniform vec2 u_viewport;
        \\uniform vec4 u_src;
        \\uniform vec2 u_texsize;
        \\varying vec2 v_uv;
        \\void main() {
        \\  vec2 px = u_dst.xy + a_pos * u_dst.zw;
        \\  vec2 clip = vec2(px.x / u_viewport.x * 2.0 - 1.0,
        \\                   1.0 - px.y / u_viewport.y * 2.0);
        \\  gl_Position = vec4(clip, 0.0, 1.0);
        \\  v_uv = (u_src.xy + a_pos * u_src.zw) / u_texsize;
        \\}
    ;

    const fragment_src: [*:0]const u8 =
        \\precision mediump float;
        \\varying vec2 v_uv;
        \\uniform sampler2D u_tex;
        \\uniform vec4 u_color;
        \\uniform float u_opacity;
        \\uniform int u_coverage;
        \\void main() {
        \\  vec4 t = texture2D(u_tex, v_uv);
        \\  if (u_coverage == 1) {
        \\    gl_FragColor = vec4(u_color.rgb, u_color.a * t.a * u_opacity);
        \\  } else {
        \\    gl_FragColor = vec4(t.rgb, t.a * u_opacity);
        \\  }
        \\}
    ;

    fn initGl(self: *Drm3d) !void {
        if (self.quad != null) return; // program survives modesets
        const g = self.gl_ops;
        const ctx = g.ctx;

        const vs = try g.create_shader(ctx, gl.VERTEX_SHADER);
        defer g.delete_shader(ctx, vs);
        g.shader_source(ctx, vs, vertex_src);
        g.compile_shader(ctx, vs);
        var ok: i32 = 0;
        g.get_shaderiv(ctx, vs, gl.COMPILE_STATUS, &ok);
        if (ok == 0) return error.ShaderCompileFailed;

        const fs = try g.create_shader(ctx, gl.FRAGMENT_SHADER);
        defer g.delete_shader(ctx, fs);
        g.shader_source(ctx, fs, fragment_src);
        g.compile_shader(ctx, fs);
        g.get_shaderiv(ctx, fs, gl.COMPILE_STATUS, &ok);
        if (ok == 0) return error.ShaderCompileFailed;

        const prog = try g.create_program(ctx);
        errdefer g.delete_program(ctx, prog);
        g.attach_shader(ctx, prog, vs);
        g.attach_shader(ctx, prog, fs);
        g.link_program(ctx, prog);
        g.get_programiv(ctx, prog, gl.LINK_STATUS, &ok);
        if (ok == 0) return error.ProgramLinkFailed;

        const a_pos = g.get_attrib_location(ctx, prog, "a_pos");
        if (a_pos < 0) return error.ShaderCompileFailed;

        self.quad = .{
            .program = prog,
            .a_pos = @intCast(a_pos),
            .u_dst = g.get_uniform_location(ctx, prog, "u_dst"),
            .u_src = g.get_uniform_location(ctx, prog, "u_src"),
            .u_viewport = g.get_uniform_location(ctx, prog, "u_viewport"),
            .u_texsize = g.get_uniform_location(ctx, prog, "u_texsize"),
            .u_color = g.get_uniform_location(ctx, prog, "u_color"),
            .u_opacity = g.get_uniform_location(ctx, prog, "u_opacity"),
            .u_coverage = g.get_uniform_location(ctx, prog, "u_coverage"),
            .u_tex = g.get_uniform_location(ctx, prog, "u_tex"),
        };

        // Unit quad (triangle strip): (0,0) (1,0) (0,1) (1,1).
        const verts = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };
        var vbo: [1]u32 = undefined;
        g.gen_buffers(ctx, 1, &vbo);
        self.quad_vbo = vbo[0];
        g.bind_buffer(ctx, gl.ARRAY_BUFFER, self.quad_vbo);
        g.buffer_data(ctx, gl.ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gl.STATIC_DRAW);

        g.use_program(ctx, prog);
        g.enable_vertex_attrib_array(ctx, @intCast(a_pos));
        g.vertex_attrib_pointer(ctx, @intCast(a_pos), 2, gl.FLOAT, false, 0, null);
        g.enable(ctx, gl.BLEND);
        g.blend_func(ctx, gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        g.pixel_storei(ctx, gl.UNPACK_ALIGNMENT, 1);
    }

    fn destroyGl(self: *Drm3d) void {
        const g = self.gl_ops;
        const ctx = g.ctx;
        if (self.presented_tex != 0) {
            g.delete_textures(ctx, 1, &.{self.presented_tex});
            self.presented_tex = 0;
        }
        if (self.staging_tex != 0) {
            g.delete_textures(ctx, 1, &.{self.staging_tex});
            self.staging_tex = 0;
        }
        if (self.image_tex != 0) {
            g.delete_textures(ctx, 1, &.{self.image_tex});
            self.image_tex = 0;
        }
        if (self.atlas_a8_tex != 0) {
            g.delete_textures(ctx, 1, &.{self.atlas_a8_tex});
            self.atlas_a8_tex = 0;
        }
        if (self.atlas_bgra_tex != 0) {
            g.delete_textures(ctx, 1, &.{self.atlas_bgra_tex});
            self.atlas_bgra_tex = 0;
        }
        if (self.quad_vbo != 0) {
            g.delete_buffers(ctx, 1, &.{self.quad_vbo});
            self.quad_vbo = 0;
        }
        if (self.quad) |q| {
            g.delete_program(ctx, q.program);
            self.quad = null;
        }
        self.atlas_have_gen = false;
    }

    fn ensureTexture(self: *Drm3d, slot: *u32) void {
        if (slot.* != 0) return;
        var ids: [1]u32 = undefined;
        self.gl_ops.gen_textures(self.gl_ops.ctx, 1, &ids);
        slot.* = ids[0];
        self.gl_ops.bind_texture(self.gl_ops.ctx, gl.TEXTURE_2D, slot.*);
        self.gl_ops.tex_parameteri(self.gl_ops.ctx, gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        self.gl_ops.tex_parameteri(self.gl_ops.ctx, gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        self.gl_ops.tex_parameteri(self.gl_ops.ctx, gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        self.gl_ops.tex_parameteri(self.gl_ops.ctx, gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    }

    /// Upload the glyph atlas's a8 + bgra8 pages. Skips entirely while the
    /// atlas generation is unchanged; otherwise uploads only the dirty rects
    /// (full page on first upload / resize), then clears the atlas dirty list.
    /// a8 goes up as GL_ALPHA coverage, bgra8 as GL_BGRA color.
    pub fn uploadAtlas(self: *Drm3d, atlas: *const GlyphAtlas) !void {
        if (self.active == null) return error.NoActiveDisplay;
        if (self.atlas_have_gen and atlas.generation == self.atlas_generation and
            atlas.width == self.atlas_w and atlas.height == self.atlas_h)
        {
            return;
        }
        const g = self.gl_ops;
        const ctx = g.ctx;
        const resize = atlas.width != self.atlas_w or atlas.height != self.atlas_h or !self.atlas_have_gen;

        self.ensureTexture(&self.atlas_a8_tex);
        self.ensureTexture(&self.atlas_bgra_tex);

        const w: i32 = @intCast(atlas.width);
        const h: i32 = @intCast(atlas.height);
        if (resize) {
            g.bind_texture(ctx, gl.TEXTURE_2D, self.atlas_a8_tex);
            g.tex_image_2d(ctx, gl.TEXTURE_2D, 0, @intCast(gl.ALPHA), w, h, 0, gl.ALPHA, gl.UNSIGNED_BYTE, atlas.a8.ptr);
            g.bind_texture(ctx, gl.TEXTURE_2D, self.atlas_bgra_tex);
            g.tex_image_2d(ctx, gl.TEXTURE_2D, 0, @intCast(gl.BGRA), w, h, 0, gl.BGRA, gl.UNSIGNED_BYTE, atlas.bgra8.ptr);
        } else {
            for (atlas.dirtyRects()) |r| {
                const rx: i32 = @intCast(r.x);
                const ry: i32 = @intCast(r.y);
                const rw: i32 = @intCast(r.width);
                const rh: i32 = @intCast(r.height);
                // a8: one byte per pixel, page stride = width.
                const a8_off = @as(usize, r.y) * atlas.width + r.x;
                g.bind_texture(ctx, gl.TEXTURE_2D, self.atlas_a8_tex);
                g.pixel_storei(ctx, gl.UNPACK_ALIGNMENT, 1);
                g.tex_sub_image_2d(ctx, gl.TEXTURE_2D, 0, rx, ry, rw, rh, gl.ALPHA, gl.UNSIGNED_BYTE, atlas.a8.ptr + a8_off);
                // bgra8: four bytes per pixel, page stride = width*4.
                const bgra_off = (@as(usize, r.y) * atlas.width + r.x) * 4;
                g.bind_texture(ctx, gl.TEXTURE_2D, self.atlas_bgra_tex);
                g.tex_sub_image_2d(ctx, gl.TEXTURE_2D, 0, rx, ry, rw, rh, gl.BGRA, gl.UNSIGNED_BYTE, atlas.bgra8.ptr + bgra_off);
            }
        }

        self.atlas_w = atlas.width;
        self.atlas_h = atlas.height;
        self.atlas_generation = atlas.generation;
        self.atlas_have_gen = true;
        // The atlas is const here; the caller (renderer) clears dirty after a
        // successful upload pass via atlas.clearDirty(). We do not mutate it.
    }

    /// Draw cell quads sampling the atlas pages. Marks the frame GL-drawn.
    pub fn drawCells(self: *Drm3d, cells: []const Cell) !void {
        if (self.active == null) return error.NoActiveDisplay;
        const q = self.quad orelse return error.NoActiveDisplay;
        if (cells.len == 0) return;
        self.gl_frame = true;
        self.clearForGlFrame();
        const act = self.active.?;
        const g = self.gl_ops;
        const ctx = g.ctx;
        g.use_program(ctx, q.program);
        g.bind_buffer(ctx, gl.ARRAY_BUFFER, self.quad_vbo);
        g.enable_vertex_attrib_array(ctx, q.a_pos);
        g.vertex_attrib_pointer(ctx, q.a_pos, 2, gl.FLOAT, false, 0, null);
        g.uniform2f(ctx, q.u_viewport, @floatFromInt(act.mode.hdisplay), @floatFromInt(act.mode.vdisplay));
        g.uniform2f(ctx, q.u_texsize, @floatFromInt(self.atlas_w), @floatFromInt(self.atlas_h));
        g.uniform1i(ctx, q.u_tex, 0);
        g.active_texture(ctx, gl.TEXTURE0);

        for (cells) |c| {
            const tex = if (c.page == 0) self.atlas_a8_tex else self.atlas_bgra_tex;
            g.bind_texture(ctx, gl.TEXTURE_2D, tex);
            g.uniform4f(ctx, q.u_dst, @floatFromInt(c.x), @floatFromInt(c.y), @floatFromInt(c.w), @floatFromInt(c.h));
            g.uniform4f(ctx, q.u_src, @floatFromInt(c.sx), @floatFromInt(c.sy), @floatFromInt(c.sw), @floatFromInt(c.sh));
            const coverage: i32 = if (c.page == 0) 1 else 0;
            g.uniform1i(ctx, q.u_coverage, coverage);
            const r: f32 = @floatFromInt((c.fg >> 16) & 0xFF);
            const gg: f32 = @floatFromInt((c.fg >> 8) & 0xFF);
            const b: f32 = @floatFromInt(c.fg & 0xFF);
            g.uniform4f(ctx, q.u_color, r / 255.0, gg / 255.0, b / 255.0, 1.0);
            g.uniform1f(ctx, q.u_opacity, 1.0);
            g.draw_arrays(ctx, gl.TRIANGLE_STRIP, 0, 4);
        }
    }

    /// Upload an RGBA image to a texture and draw its quad at `dst`. Marks the
    /// frame GL-drawn. M5.1 uses a single scratch image texture; the renderer
    /// layer's image cache (render/image.zig) decides what to re-upload.
    pub fn drawImage(self: *Drm3d, img: Image, dst: Damage) !void {
        if (self.active == null) return error.NoActiveDisplay;
        const q = self.quad orelse return error.NoActiveDisplay;
        if (img.width == 0 or img.height == 0) return error.InvalidImage;
        if (img.pixels.len < @as(usize, img.width) * img.height * 4) return error.InvalidImage;
        self.gl_frame = true;
        self.clearForGlFrame();
        const act = self.active.?;
        const g = self.gl_ops;
        const ctx = g.ctx;

        self.ensureTexture(&self.image_tex);
        g.bind_texture(ctx, gl.TEXTURE_2D, self.image_tex);
        g.tex_image_2d(ctx, gl.TEXTURE_2D, 0, @intCast(gl.RGBA), @intCast(img.width), @intCast(img.height), 0, gl.RGBA, gl.UNSIGNED_BYTE, img.pixels.ptr);

        g.use_program(ctx, q.program);
        g.bind_buffer(ctx, gl.ARRAY_BUFFER, self.quad_vbo);
        g.enable_vertex_attrib_array(ctx, q.a_pos);
        g.vertex_attrib_pointer(ctx, q.a_pos, 2, gl.FLOAT, false, 0, null);
        g.active_texture(ctx, gl.TEXTURE0);
        g.bind_texture(ctx, gl.TEXTURE_2D, self.image_tex);
        g.uniform1i(ctx, q.u_tex, 0);
        g.uniform2f(ctx, q.u_viewport, @floatFromInt(act.mode.hdisplay), @floatFromInt(act.mode.vdisplay));
        g.uniform2f(ctx, q.u_texsize, @floatFromInt(img.width), @floatFromInt(img.height));
        g.uniform4f(ctx, q.u_dst, @floatFromInt(dst.x), @floatFromInt(dst.y), @floatFromInt(dst.w), @floatFromInt(dst.h));
        g.uniform4f(ctx, q.u_src, 0, 0, @floatFromInt(img.width), @floatFromInt(img.height));
        g.uniform1i(ctx, q.u_coverage, 0);
        g.uniform4f(ctx, q.u_color, 1, 1, 1, 1);
        g.uniform1f(ctx, q.u_opacity, 1.0);
        g.draw_arrays(ctx, gl.TRIANGLE_STRIP, 0, 4);
    }

    /// Present the CPU staging buffer into the target. `rects` null = full
    /// frame: full upload, full clear, full-screen quad. Otherwise (M8.2)
    /// damage-only: sub-upload each rect, then scissor-clear + draw a quad
    /// per rect, so clear/upload/draw touch only damaged pixels. xrgb8888
    /// memory is B,G,R,X, so it uploads as GL_BGRA (no swizzle) and the
    /// unused X byte arrives as alpha 0. The staging buffer is already the
    /// composited frame, so it is presented with blending off: SRC_ALPHA
    /// blending would discard every pixel whose X byte is 0 (all CPU-drawn
    /// content, i.e. the whole terminal). Blending is restored afterwards for
    /// the transparent GL hooks (drawCells/drawImage).
    fn presentStaging(self: *Drm3d, rects: ?[]const Damage) !void {
        if (rects) |rs| {
            if (rs.len == 0) return; // nothing changed: the back buffer is current
        }
        const s = self.staging orelse return error.NoActiveDisplay;
        const q = self.quad orelse return error.NoActiveDisplay;
        const act = self.active.?;
        const g = self.gl_ops;
        const ctx = g.ctx;
        const w: i32 = @intCast(s.width);
        const h: i32 = @intCast(s.height);

        self.ensureTexture(&self.staging_tex);
        g.bind_texture(ctx, gl.TEXTURE_2D, self.staging_tex);
        if (rects == null or self.staging_tex_w != s.width or self.staging_tex_h != s.height) {
            g.tex_image_2d(ctx, gl.TEXTURE_2D, 0, @intCast(gl.BGRA), w, h, 0, gl.BGRA, gl.UNSIGNED_BYTE, s.mem.ptr);
            self.staging_tex_w = s.width;
            self.staging_tex_h = s.height;
        }

        g.use_program(ctx, q.program);
        g.bind_buffer(ctx, gl.ARRAY_BUFFER, self.quad_vbo);
        g.enable_vertex_attrib_array(ctx, q.a_pos);
        g.vertex_attrib_pointer(ctx, q.a_pos, 2, gl.FLOAT, false, 0, null);
        g.active_texture(ctx, gl.TEXTURE0);
        g.bind_texture(ctx, gl.TEXTURE_2D, self.staging_tex);
        g.uniform1i(ctx, q.u_tex, 0);
        g.uniform2f(ctx, q.u_viewport, @floatFromInt(act.mode.hdisplay), @floatFromInt(act.mode.vdisplay));
        g.uniform2f(ctx, q.u_texsize, @floatFromInt(s.width), @floatFromInt(s.height));
        g.uniform1i(ctx, q.u_coverage, 0);
        g.uniform4f(ctx, q.u_color, 1, 1, 1, 1);
        g.uniform1f(ctx, q.u_opacity, 1.0);
        g.clear_color(ctx, 0, 0, 0, 1);
        // Opaque copy: the X byte is padding, not coverage (see the doc
        // comment). Restore the blend state for the GL hooks.
        g.disable(ctx, gl.BLEND);
        defer g.enable(ctx, gl.BLEND);

        if (rects) |rs| {
            for (rs) |r| {
                const pixels = try self.stagingRectPixels(s, r);
                g.pixel_storei(ctx, gl.UNPACK_ALIGNMENT, 1);
                g.tex_sub_image_2d(ctx, gl.TEXTURE_2D, 0, @intCast(r.x), @intCast(r.y), @intCast(r.w), @intCast(r.h), gl.BGRA, gl.UNSIGNED_BYTE, pixels);
            }
            g.enable(ctx, gl.SCISSOR_TEST);
            for (rs) |r| {
                const rx: i32 = @intCast(r.x);
                const ry: i32 = @intCast(r.y);
                const rw: i32 = @intCast(r.w);
                const rh: i32 = @intCast(r.h);
                // GL's scissor origin is bottom-left; the quad shader maps
                // top-left framebuffer pixels, so flip the rect vertically.
                g.scissor(ctx, rx, h - ry - rh, rw, rh);
                g.clear(ctx, gl.COLOR_BUFFER_BIT);
                g.uniform4f(ctx, q.u_dst, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
                g.uniform4f(ctx, q.u_src, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
                g.draw_arrays(ctx, gl.TRIANGLE_STRIP, 0, 4);
            }
            g.disable(ctx, gl.SCISSOR_TEST);
        } else {
            g.clear(ctx, gl.COLOR_BUFFER_BIT);
            g.uniform4f(ctx, q.u_dst, 0, 0, @floatFromInt(s.width), @floatFromInt(s.height));
            g.uniform4f(ctx, q.u_src, 0, 0, @floatFromInt(s.width), @floatFromInt(s.height));
            g.draw_arrays(ctx, gl.TRIANGLE_STRIP, 0, 4);
        }
    }

    /// Upload source for a staging rect: full-width rects upload in place
    /// (tight rows); sub-width rects are row-copied into the tight scratch,
    /// because GLES2 has no UNPACK_ROW_LENGTH.
    fn stagingRectPixels(self: *Drm3d, s: Framebuffer, r: Damage) ![*]const u8 {
        const row_bytes = @as(usize, r.w) * 4;
        if (r.w == s.width and s.pitch == s.width * 4) {
            return s.mem.ptr + @as(usize, r.y) * s.pitch;
        }
        const need = row_bytes * r.h;
        if (self.upload_scratch.len < need) {
            if (self.upload_scratch.len > 0) self.allocator.free(self.upload_scratch);
            self.upload_scratch = try self.allocator.alloc(u8, need);
        }
        var y: u32 = 0;
        while (y < r.h) : (y += 1) {
            const src = s.mem.ptr + (@as(usize, r.y + y) * s.pitch + @as(usize, r.x) * 4);
            const dst = self.upload_scratch.ptr + @as(usize, y) * row_bytes;
            @memcpy(dst[0..row_bytes], src[0..row_bytes]);
        }
        return self.upload_scratch.ptr;
    }

    // ------------------------------------------------------------------
    // vtable
    // ------------------------------------------------------------------

    const vtable = video.Backend.VTable{
        .deinit = vtDeinit,
        .connectors = vtConnectors,
        .setMode = vtSetMode,
        .beginFrame = vtBeginFrame,
        .endFrame = vtEndFrame,
        .flipPending = vtFlipPending,
        .waitFlip = vtWaitFlip,
        .setDpms = vtSetDpms,
        .setCursor = vtSetCursor,
        .supportsHwCursor = vtSupportsHwCursor,
    };

    fn cast(ptr: *anyopaque) *Drm3d {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }
    fn vtConnectors(ptr: *anyopaque) anyerror![]const ConnectorInfo {
        return cast(ptr).connectors();
    }
    fn vtSetMode(ptr: *anyopaque, connector_idx: usize, mode_idx: usize) anyerror!void {
        return cast(ptr).setMode(connector_idx, mode_idx);
    }
    fn vtBeginFrame(ptr: *anyopaque) anyerror!*Framebuffer {
        return cast(ptr).beginFrame();
    }
    fn vtEndFrame(ptr: *anyopaque, damage: []const Damage) anyerror!void {
        return cast(ptr).endFrame(damage);
    }
    fn vtFlipPending(ptr: *anyopaque) bool {
        return cast(ptr).flipPending();
    }
    fn vtWaitFlip(ptr: *anyopaque) anyerror!void {
        return cast(ptr).waitFlip();
    }
    fn vtSetDpms(ptr: *anyopaque, state: DpmsState) anyerror!void {
        return cast(ptr).setDpms(state);
    }
    fn vtSetCursor(ptr: *anyopaque, img: ?*Framebuffer, x: i32, y: i32) anyerror!void {
        return cast(ptr).setCursor(img, x, y);
    }
    fn vtSupportsHwCursor(ptr: *anyopaque) bool {
        return cast(ptr).supportsHwCursor();
    }
};

// ---------------------------------------------------------------------------
// Real GBM / EGL / GL implementations. Each namespace lazily imports its
// translate-c module so the hermetic test build never resolves it. Referenced
// only through *.ops() (production) or the link_libc-gated test below.
// ---------------------------------------------------------------------------

pub const libgbm = struct {
    const c = @import("gbm-c");

    pub fn ops() GbmOps {
        return .{
            .create_device = createDevice,
            .destroy_device = destroyDevice,
            .surface_create = surfaceCreate,
            .surface_destroy = surfaceDestroy,
            .lock_front_buffer = lockFrontBuffer,
            .release_buffer = releaseBuffer,
            .has_free_buffers = hasFreeBuffers,
            .bo_info = boInfo,
            .bo_get_fd = boGetFd,
            .close_fd = closeFd,
        };
    }

    fn createDevice(_: ?*anyopaque, fd: i32) !GbmDevice {
        return @ptrCast(c.gbm_create_device(fd) orelse return error.Unsupported);
    }
    fn destroyDevice(_: ?*anyopaque, dev: GbmDevice) void {
        c.gbm_device_destroy(@ptrCast(dev));
    }
    fn surfaceCreate(_: ?*anyopaque, dev: GbmDevice, width: u32, height: u32, format: u32, flags: u32) !GbmSurface {
        return @ptrCast(c.gbm_surface_create(@ptrCast(dev), width, height, format, flags) orelse return error.Unsupported);
    }
    fn surfaceDestroy(_: ?*anyopaque, surf: GbmSurface) void {
        c.gbm_surface_destroy(@ptrCast(surf));
    }
    fn lockFrontBuffer(_: ?*anyopaque, surf: GbmSurface) !GbmBo {
        return @ptrCast(c.gbm_surface_lock_front_buffer(@ptrCast(surf)) orelse return error.Busy);
    }
    fn releaseBuffer(_: ?*anyopaque, surf: GbmSurface, bo: GbmBo) void {
        c.gbm_surface_release_buffer(@ptrCast(surf), @ptrCast(bo));
    }
    fn hasFreeBuffers(_: ?*anyopaque, surf: GbmSurface) bool {
        return c.gbm_surface_has_free_buffers(@ptrCast(surf)) != 0;
    }
    fn boInfo(_: ?*anyopaque, bo: GbmBo) GbmBoInfo {
        const b: *c.struct_gbm_bo = @ptrCast(bo);
        return .{
            .width = c.gbm_bo_get_width(b),
            .height = c.gbm_bo_get_height(b),
            .stride = c.gbm_bo_get_stride(b),
            .format = c.gbm_bo_get_format(b),
            .handle = c.gbm_bo_get_handle(b).u32,
            .modifier = c.gbm_bo_get_modifier(b),
        };
    }
    fn boGetFd(_: ?*anyopaque, bo: GbmBo) !i32 {
        const fd = c.gbm_bo_get_fd(@ptrCast(bo));
        if (fd < 0) return error.Unsupported;
        return fd;
    }
    fn closeFd(_: ?*anyopaque, fd: i32) void {
        _ = std.os.linux.close(fd);
    }
};

pub const libegl = struct {
    const c = @import("egl-c");

    pub fn ops() EglOps {
        return .{
            .get_display = getDisplay,
            .initialize = initialize,
            .terminate = terminate,
            .bind_api = bindApi,
            .choose_config = chooseConfig,
            .create_context = createContext,
            .destroy_context = destroyContext,
            .create_window_surface = createWindowSurface,
            .destroy_surface = destroySurface,
            .make_current = makeCurrent,
            .swap_buffers = swapBuffers,
            .create_image = createImage,
            .destroy_image = destroyImage,
            .buffer_age = bufferAge,
        };
    }

    fn getDisplay(_: ?*anyopaque, native: GbmDevice) !EglDisplay {
        const dpy = c.eglGetDisplay(@ptrCast(native));
        if (dpy == null) return error.Unsupported;
        return @ptrCast(dpy);
    }
    fn initialize(_: ?*anyopaque, dpy: EglDisplay) !void {
        if (c.eglInitialize(@ptrCast(dpy), null, null) == c.EGL_FALSE) return error.Unsupported;
    }
    fn terminate(_: ?*anyopaque, dpy: EglDisplay) void {
        _ = c.eglTerminate(@ptrCast(dpy));
    }
    fn bindApi(_: ?*anyopaque, api: u32) !void {
        if (c.eglBindAPI(api) == c.EGL_FALSE) return error.Unsupported;
    }
    fn chooseConfig(_: ?*anyopaque, dpy: EglDisplay, attribs: []const i32, configs: []EglConfig) !usize {
        var num: c.EGLint = 0;
        if (c.eglChooseConfig(@ptrCast(dpy), attribs.ptr, @ptrCast(configs.ptr), @intCast(configs.len), &num) == c.EGL_FALSE)
            return error.Unsupported;
        return @intCast(num);
    }
    fn createContext(_: ?*anyopaque, dpy: EglDisplay, config: EglConfig, share: ?EglContext, attribs: []const i32) !EglContext {
        const ctx = c.eglCreateContext(@ptrCast(dpy), @ptrCast(config), if (share) |s| @ptrCast(s) else null, attribs.ptr);
        if (ctx == null) return error.Unsupported;
        return @ptrCast(ctx);
    }
    fn destroyContext(_: ?*anyopaque, dpy: EglDisplay, context: EglContext) void {
        _ = c.eglDestroyContext(@ptrCast(dpy), @ptrCast(context));
    }
    fn createWindowSurface(_: ?*anyopaque, dpy: EglDisplay, config: EglConfig, win: GbmSurface, attribs: []const i32) !EglSurface {
        // EGLNativeWindowType is an integer (uintptr_t) on the GBM platform.
        const native_win: c.EGLNativeWindowType = @intCast(@intFromPtr(win));
        const surf = c.eglCreateWindowSurface(@ptrCast(dpy), @ptrCast(config), native_win, attribs.ptr);
        if (surf == null) return error.Unsupported;
        return @ptrCast(surf);
    }
    fn destroySurface(_: ?*anyopaque, dpy: EglDisplay, surf: EglSurface) void {
        _ = c.eglDestroySurface(@ptrCast(dpy), @ptrCast(surf));
    }
    fn makeCurrent(_: ?*anyopaque, dpy: EglDisplay, draw: ?EglSurface, read: ?EglSurface, context: ?EglContext) !void {
        const ok = c.eglMakeCurrent(
            @ptrCast(dpy),
            if (draw) |s| @ptrCast(s) else null,
            if (read) |s| @ptrCast(s) else null,
            if (context) |ctx| @ptrCast(ctx) else null,
        );
        if (ok == c.EGL_FALSE) return error.Unsupported;
    }
    fn swapBuffers(_: ?*anyopaque, dpy: EglDisplay, surf: EglSurface) !void {
        if (c.eglSwapBuffers(@ptrCast(dpy), @ptrCast(surf)) == c.EGL_FALSE) return error.Unsupported;
    }
    // eglCreateImageKHR / eglDestroyImageKHR are extension entry points that
    // libglvnd does not export directly; resolve via eglGetProcAddress (cached).
    var p_create_image: c.PFNEGLCREATEIMAGEKHRPROC = null;
    var p_destroy_image: c.PFNEGLDESTROYIMAGEKHRPROC = null;

    fn createImage(_: ?*anyopaque, dpy: EglDisplay, context: ?EglContext, target: u32, buffer: ?*anyopaque, attribs: []const i32) !EglImage {
        if (p_create_image == null) {
            p_create_image = @ptrCast(c.eglGetProcAddress("eglCreateImageKHR"));
        }
        const f = p_create_image orelse return error.Unsupported;
        const img = f(
            @ptrCast(dpy),
            if (context) |ctx| @ptrCast(ctx) else null,
            target,
            @ptrCast(buffer),
            attribs.ptr,
        );
        if (img == null) return error.Unsupported;
        return @ptrCast(img);
    }
    fn destroyImage(_: ?*anyopaque, dpy: EglDisplay, image: EglImage) void {
        if (p_destroy_image == null) {
            p_destroy_image = @ptrCast(c.eglGetProcAddress("eglDestroyImageKHR"));
        }
        if (p_destroy_image) |f| _ = f(@ptrCast(dpy), @ptrCast(image));
    }
    fn bufferAge(_: ?*anyopaque, dpy: EglDisplay, surf: EglSurface) ?i32 {
        var age: c.EGLint = 0;
        if (c.eglQuerySurface(@ptrCast(dpy), @ptrCast(surf), egl.BUFFER_AGE_EXT, &age) == c.EGL_FALSE) return null;
        return age;
    }
};

pub const libgl = struct {
    const c = @import("gl-c");
    const egl_c = @import("egl-c");

    pub fn ops() GlOps {
        return .{
            .create_shader = createShader,
            .shader_source = shaderSource,
            .compile_shader = compileShader,
            .get_shaderiv = getShaderiv,
            .delete_shader = deleteShader,
            .create_program = createProgram,
            .attach_shader = attachShader,
            .link_program = linkProgram,
            .get_programiv = getProgramiv,
            .use_program = useProgram,
            .delete_program = deleteProgram,
            .get_attrib_location = getAttribLocation,
            .get_uniform_location = getUniformLocation,
            .enable_vertex_attrib_array = enableVertexAttribArray,
            .vertex_attrib_pointer = vertexAttribPointer,
            .gen_buffers = genBuffers,
            .delete_buffers = deleteBuffers,
            .bind_buffer = bindBuffer,
            .buffer_data = bufferData,
            .uniform1i = uniform1i,
            .uniform1f = uniform1f,
            .uniform2f = uniform2f,
            .uniform4f = uniform4f,
            .draw_arrays = drawArrays,
            .viewport = viewport,
            .clear_color = clearColor,
            .clear = clear,
            .scissor = scissor,
            .active_texture = activeTexture,
            .gen_textures = genTextures,
            .delete_textures = deleteTextures,
            .bind_texture = bindTexture,
            .tex_image_2d = texImage2D,
            .tex_sub_image_2d = texSubImage2D,
            .tex_parameteri = texParameteri,
            .pixel_storei = pixelStorei,
            .enable = enable,
            .disable = disable,
            .blend_func = blendFunc,
            .image_target_texture_2d = imageTargetTexture2D,
            .flush = flush,
        };
    }

    fn createShader(_: ?*anyopaque, kind: u32) !u32 {
        const s = c.glCreateShader(kind);
        if (s == 0) return error.Unsupported;
        return s;
    }
    fn shaderSource(_: ?*anyopaque, shader: u32, src: [*:0]const u8) void {
        const ptr: [*c]const u8 = src;
        c.glShaderSource(shader, 1, &ptr, null);
    }
    fn compileShader(_: ?*anyopaque, shader: u32) void {
        c.glCompileShader(shader);
    }
    fn getShaderiv(_: ?*anyopaque, shader: u32, pname: u32, out: *i32) void {
        c.glGetShaderiv(shader, pname, out);
    }
    fn deleteShader(_: ?*anyopaque, shader: u32) void {
        c.glDeleteShader(shader);
    }
    fn createProgram(_: ?*anyopaque) !u32 {
        const p = c.glCreateProgram();
        if (p == 0) return error.Unsupported;
        return p;
    }
    fn attachShader(_: ?*anyopaque, program: u32, shader: u32) void {
        c.glAttachShader(program, shader);
    }
    fn linkProgram(_: ?*anyopaque, program: u32) void {
        c.glLinkProgram(program);
    }
    fn getProgramiv(_: ?*anyopaque, program: u32, pname: u32, out: *i32) void {
        c.glGetProgramiv(program, pname, out);
    }
    fn useProgram(_: ?*anyopaque, program: u32) void {
        c.glUseProgram(program);
    }
    fn deleteProgram(_: ?*anyopaque, program: u32) void {
        c.glDeleteProgram(program);
    }
    fn getAttribLocation(_: ?*anyopaque, program: u32, name: [*:0]const u8) i32 {
        return c.glGetAttribLocation(program, name);
    }
    fn getUniformLocation(_: ?*anyopaque, program: u32, name: [*:0]const u8) i32 {
        return c.glGetUniformLocation(program, name);
    }
    fn enableVertexAttribArray(_: ?*anyopaque, index: u32) void {
        c.glEnableVertexAttribArray(index);
    }
    fn vertexAttribPointer(_: ?*anyopaque, index: u32, size: i32, kind: u32, normalized: bool, stride: i32, ptr: ?*const anyopaque) void {
        c.glVertexAttribPointer(index, size, kind, if (normalized) gl.TRUE else gl.FALSE, stride, ptr);
    }
    fn genBuffers(_: ?*anyopaque, n: usize, ids: []u32) void {
        c.glGenBuffers(@intCast(n), ids.ptr);
    }
    fn deleteBuffers(_: ?*anyopaque, n: usize, ids: []const u32) void {
        c.glDeleteBuffers(@intCast(n), ids.ptr);
    }
    fn bindBuffer(_: ?*anyopaque, target: u32, id: u32) void {
        c.glBindBuffer(target, id);
    }
    fn bufferData(_: ?*anyopaque, target: u32, size: usize, data: ?*const anyopaque, usage: u32) void {
        c.glBufferData(target, @intCast(size), data, usage);
    }
    fn uniform1i(_: ?*anyopaque, loc: i32, v: i32) void {
        c.glUniform1i(loc, v);
    }
    fn uniform1f(_: ?*anyopaque, loc: i32, v: f32) void {
        c.glUniform1f(loc, v);
    }
    fn uniform2f(_: ?*anyopaque, loc: i32, x: f32, y: f32) void {
        c.glUniform2f(loc, x, y);
    }
    fn uniform4f(_: ?*anyopaque, loc: i32, x: f32, y: f32, z: f32, w: f32) void {
        c.glUniform4f(loc, x, y, z, w);
    }
    fn drawArrays(_: ?*anyopaque, mode: u32, first: i32, count: i32) void {
        c.glDrawArrays(mode, first, count);
    }
    fn viewport(_: ?*anyopaque, x: i32, y: i32, w: i32, h: i32) void {
        c.glViewport(x, y, w, h);
    }
    fn clearColor(_: ?*anyopaque, r: f32, g: f32, b: f32, a: f32) void {
        c.glClearColor(r, g, b, a);
    }
    fn clear(_: ?*anyopaque, mask: u32) void {
        c.glClear(mask);
    }
    fn scissor(_: ?*anyopaque, x: i32, y: i32, w: i32, h: i32) void {
        c.glScissor(x, y, w, h);
    }
    fn activeTexture(_: ?*anyopaque, unit: u32) void {
        c.glActiveTexture(unit);
    }
    fn genTextures(_: ?*anyopaque, n: usize, ids: []u32) void {
        c.glGenTextures(@intCast(n), ids.ptr);
    }
    fn deleteTextures(_: ?*anyopaque, n: usize, ids: []const u32) void {
        c.glDeleteTextures(@intCast(n), ids.ptr);
    }
    fn bindTexture(_: ?*anyopaque, target: u32, id: u32) void {
        c.glBindTexture(target, id);
    }
    fn texImage2D(_: ?*anyopaque, target: u32, level: i32, internalformat: i32, w: i32, h: i32, border: i32, format: u32, kind: u32, pixels: ?*const anyopaque) void {
        c.glTexImage2D(target, level, internalformat, w, h, border, format, kind, pixels);
    }
    fn texSubImage2D(_: ?*anyopaque, target: u32, level: i32, x: i32, y: i32, w: i32, h: i32, format: u32, kind: u32, pixels: ?*const anyopaque) void {
        c.glTexSubImage2D(target, level, x, y, w, h, format, kind, pixels);
    }
    fn texParameteri(_: ?*anyopaque, target: u32, pname: u32, param: i32) void {
        c.glTexParameteri(target, pname, param);
    }
    fn pixelStorei(_: ?*anyopaque, pname: u32, param: i32) void {
        c.glPixelStorei(pname, param);
    }
    fn enable(_: ?*anyopaque, cap: u32) void {
        c.glEnable(cap);
    }
    fn disable(_: ?*anyopaque, cap: u32) void {
        c.glDisable(cap);
    }
    fn blendFunc(_: ?*anyopaque, src: u32, dst: u32) void {
        c.glBlendFunc(src, dst);
    }
    // glEGLImageTargetTexture2DOES is an OES extension libglvnd does not export
    // directly; resolve via eglGetProcAddress (cached).
    var p_image_target: c.PFNGLEGLIMAGETARGETTEXTURE2DOESPROC = null;

    fn imageTargetTexture2D(_: ?*anyopaque, target: u32, image: EglImage) void {
        if (p_image_target == null) {
            p_image_target = @ptrCast(egl_c.eglGetProcAddress("glEGLImageTargetTexture2DOES"));
        }
        if (p_image_target) |f| f(target, @ptrCast(image));
    }
    fn flush(_: ?*anyopaque) void {
        c.glFlush();
    }
};

// With -lc and the C modules present (real-wrapper verification build), also
// compile the GBM/EGL/GL namespaces. The hermetic build has link_libc=false,
// so the branch is never analyzed and the C imports stay optional.
test {
    if (comptime @import("builtin").link_libc) {
        std.testing.refAllDecls(libgbm);
        std.testing.refAllDecls(libegl);
        std.testing.refAllDecls(libgl);
    }
}

// ---------------------------------------------------------------------------
// Hermetic tests: fake DRM device + fake GBM/EGL/GL GPU. No C libraries, no
// /dev/dri, no GPU.
// ---------------------------------------------------------------------------

const testing = std.testing;

const fake_mode_1024 = drm2dMode(1024, 768, 65000, 1344, 806, false, "1024x768");
const fake_mode_1080 = drm2dMode(1920, 1080, 148500, 2200, 1125, true, "1920x1080");
const fake_modes_hdmi = [_]ModeInfo{ fake_mode_1024, fake_mode_1080 };

fn drm2dMode(w: u16, h: u16, clock: u32, htotal: u16, vtotal: u16, preferred: bool, name: []const u8) ModeInfo {
    var m: ModeInfo = std.mem.zeroes(ModeInfo);
    m.clock = clock;
    m.hdisplay = w;
    m.htotal = htotal;
    m.vdisplay = h;
    m.vtotal = vtotal;
    m.vrefresh = @intCast(@as(u64, clock) * 1000 / (@as(u64, htotal) * vtotal));
    m.type = if (preferred) drmc.MODE_TYPE_PREFERRED else 0;
    @memcpy(m.name[0..name.len], name);
    return m;
}

const FakeProp = struct { id: u32, name: []const u8, value: u64 = 0 };
const fake_props_dpms = [_]FakeProp{ .{ .id = 1, .name = "EDID" }, .{ .id = 7, .name = "DPMS", .value = 0 } };

const FakeConn = struct {
    id: u32,
    type: u32,
    type_id: u32,
    connected: bool = true,
    mm_width: u32 = 530,
    mm_height: u32 = 300,
    modes: []const ModeInfo = &fake_modes_hdmi,
    encoder_id: u32 = 51,
    encoders: []const u32 = &.{},
    props: []const FakeProp = &fake_props_dpms,
};
const fake_connectors = [_]FakeConn{
    .{ .id = 61, .type = 1, .type_id = 1, .connected = false, .encoder_id = 0, .encoders = &.{51} },
    .{ .id = 62, .type = 11, .type_id = 1 },
};
const fake_encoders = [_]drm2d.Encoder{
    .{ .encoder_id = 51, .encoder_type = 0, .crtc_id = 41, .possible_crtcs = 0b01, .possible_clones = 0 },
};

// -- Fake DRM device (only the calls drm3d makes; the rest are stubs) --

const FakeDrm = struct {
    allocator: Allocator,
    master: bool = false,
    next_fd: i32 = 7,
    next_fb: u32 = 200,
    fail_set_master: ?anyerror = null,
    fail_drop_master: ?anyerror = null,
    fail_page_flip: ?anyerror = null,
    auto_flip_event: bool = false,
    events: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(DrmCall) = .empty,
    set_crtc_calls: std.ArrayList(SetCrtcCall) = .empty,
    flip_calls: std.ArrayList(FlipCall) = .empty,
    prop_calls: std.ArrayList(PropCall) = .empty,
    add_fb_calls: std.ArrayList(AddFbCall) = .empty,
    probe_flags: std.ArrayList(bool) = .empty,
    opened_path: ?[]u8 = null,

    const DrmCall = enum { open, close, set_master, drop_master, is_master, get_cap, set_client_cap, get_resources, get_connector, get_encoder, get_property, set_crtc, add_fb, rm_fb, page_flip, set_property, read, poll };
    const SetCrtcCall = struct { crtc_id: u32, fb_id: u32, connector_ids: []u32, mode: ?ModeInfo };
    const FlipCall = struct { crtc_id: u32, fb_id: u32, flags: u32, user_data: u64 };
    const PropCall = struct { connector_id: u32, prop_id: u32, value: u64 };
    const AddFbCall = struct { width: u32, height: u32, pitch: u32, handle: u32, fb_id: u32 };

    fn deinit(self: *FakeDrm) void {
        self.events.deinit(self.allocator);
        self.calls.deinit(self.allocator);
        for (self.set_crtc_calls.items) |s| self.allocator.free(s.connector_ids);
        self.set_crtc_calls.deinit(self.allocator);
        self.flip_calls.deinit(self.allocator);
        self.prop_calls.deinit(self.allocator);
        self.add_fb_calls.deinit(self.allocator);
        self.probe_flags.deinit(self.allocator);
        if (self.opened_path) |p| self.allocator.free(p);
    }

    fn record(self: *FakeDrm, call: DrmCall) void {
        self.calls.append(self.allocator, call) catch @panic("fake: oom");
    }
    fn count(self: *const FakeDrm, call: DrmCall) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (c == call) n += 1;
        }
        return n;
    }
    fn cast(ctx: ?*anyopaque) *FakeDrm {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn queueFlipEvent(self: *FakeDrm, crtc_id: u32, user_data: u64) void {
        var ev: [32]u8 = std.mem.zeroes([32]u8);
        std.mem.writeInt(u32, ev[0..4], drmc.EVENT_FLIP_COMPLETE, .little);
        std.mem.writeInt(u32, ev[4..8], 32, .little);
        std.mem.writeInt(u64, ev[8..16], user_data, .little);
        std.mem.writeInt(u32, ev[28..32], crtc_id, .little);
        self.events.appendSlice(self.allocator, &ev) catch @panic("fake: oom event");
    }

    fn ops(self: *FakeDrm) DrmOps {
        return .{
            .ctx = self,
            .open = open,
            .close = close,
            .set_master = setMaster,
            .drop_master = dropMaster,
            .is_master = isMaster,
            .get_cap = getCap,
            .set_client_cap = setClientCap,
            .get_resources = getResources,
            .get_connector = getConnector,
            .get_encoder = getEncoder,
            .get_property = getProperty,
            .set_crtc = setCrtc,
            .create_dumb = createDumb,
            .map_dumb = mapDumb,
            .destroy_dumb = destroyDumb,
            .add_fb = addFb,
            .rm_fb = rmFb,
            .dirty_fb = dirtyFb,
            .page_flip = pageFlip,
            .connector_set_property = connectorSetProperty,
            .set_cursor2 = setCursor2,
            .move_cursor = moveCursor,
            .mmap = mmap,
            .munmap = munmap,
            .read = read,
            .poll = poll,
        };
    }

    fn open(ctx: ?*anyopaque, path: [*:0]const u8) !i32 {
        const self = cast(ctx);
        self.record(.open);
        if (self.opened_path) |p| self.allocator.free(p);
        self.opened_path = try self.allocator.dupe(u8, std.mem.span(path));
        const fd = self.next_fd;
        self.next_fd += 1;
        return fd;
    }
    fn close(ctx: ?*anyopaque, _: i32) void {
        cast(ctx).record(.close);
    }
    fn setMaster(ctx: ?*anyopaque, _: i32) !void {
        const self = cast(ctx);
        self.record(.set_master);
        if (self.fail_set_master) |e| return e;
        self.master = true;
    }
    fn dropMaster(ctx: ?*anyopaque, _: i32) !void {
        const self = cast(ctx);
        self.record(.drop_master);
        if (self.fail_drop_master) |e| return e;
        self.master = false;
    }
    fn isMaster(ctx: ?*anyopaque, _: i32) !bool {
        const self = cast(ctx);
        self.record(.is_master);
        return self.master;
    }
    fn getCap(ctx: ?*anyopaque, _: i32, _: u64, value: *u64) !void {
        cast(ctx).record(.get_cap);
        value.* = 1;
    }
    fn setClientCap(ctx: ?*anyopaque, _: i32, _: u64, _: u64) !void {
        cast(ctx).record(.set_client_cap);
    }
    fn getResources(ctx: ?*anyopaque, _: i32, allocator: Allocator) !Resources {
        const self = cast(ctx);
        self.record(.get_resources);
        const conn_ids = try allocator.alloc(u32, fake_connectors.len);
        errdefer allocator.free(conn_ids);
        for (fake_connectors, 0..) |cn, i| conn_ids[i] = cn.id;
        const enc_ids = try allocator.dupe(u32, &.{51});
        errdefer allocator.free(enc_ids);
        const crtcs = try allocator.dupe(u32, &.{ 41, 42 });
        return .{ .crtcs = crtcs, .connectors = conn_ids, .encoders = enc_ids, .min_width = 32, .max_width = 8192, .min_height = 32, .max_height = 8192 };
    }
    fn getConnector(ctx: ?*anyopaque, _: i32, allocator: Allocator, connector_id: u32, force_probe: bool) !Connector {
        const self = cast(ctx);
        self.record(.get_connector);
        try self.probe_flags.append(self.allocator, force_probe);
        const cn = for (fake_connectors) |c| {
            if (c.id == connector_id) break c;
        } else return error.NotFound;
        const modes = try allocator.dupe(ModeInfo, cn.modes);
        errdefer allocator.free(modes);
        const props = try allocator.alloc(PropValue, cn.props.len);
        errdefer allocator.free(props);
        for (cn.props, 0..) |p, i| props[i] = .{ .id = p.id, .value = p.value };
        const encoders = try allocator.dupe(u32, cn.encoders);
        return .{
            .connector_id = cn.id,
            .encoder_id = cn.encoder_id,
            .connector_type = cn.type,
            .connector_type_id = cn.type_id,
            .connection = if (cn.connected) .connected else .disconnected,
            .mm_width = cn.mm_width,
            .mm_height = cn.mm_height,
            .modes = modes,
            .props = props,
            .encoders = encoders,
        };
    }
    fn getEncoder(ctx: ?*anyopaque, _: i32, encoder_id: u32) !Encoder {
        cast(ctx).record(.get_encoder);
        for (fake_encoders) |e| {
            if (e.encoder_id == encoder_id) return e;
        }
        return error.NotFound;
    }
    fn getProperty(ctx: ?*anyopaque, _: i32, prop_id: u32) !Property {
        cast(ctx).record(.get_property);
        for (fake_connectors) |cn| {
            for (cn.props) |p| {
                if (p.id == prop_id) {
                    var prop: Property = .{ .prop_id = p.id, .flags = 0, .name = @splat(0) };
                    @memcpy(prop.name[0..p.name.len], p.name);
                    return prop;
                }
            }
        }
        return error.NotFound;
    }
    fn setCrtc(ctx: ?*anyopaque, _: i32, crtc_id: u32, fb_id: u32, _: u32, _: u32, connector_ids: []const u32, mode: ?*const ModeInfo) !void {
        const self = cast(ctx);
        self.record(.set_crtc);
        const ids = try self.allocator.dupe(u32, connector_ids);
        errdefer self.allocator.free(ids);
        try self.set_crtc_calls.append(self.allocator, .{ .crtc_id = crtc_id, .fb_id = fb_id, .connector_ids = ids, .mode = if (mode) |m| m.* else null });
    }
    fn addFb(ctx: ?*anyopaque, _: i32, width: u32, height: u32, _: u8, _: u8, pitch: u32, handle: u32) !u32 {
        const self = cast(ctx);
        self.record(.add_fb);
        const id = self.next_fb;
        self.next_fb += 1;
        try self.add_fb_calls.append(self.allocator, .{ .width = width, .height = height, .pitch = pitch, .handle = handle, .fb_id = id });
        return id;
    }
    fn rmFb(ctx: ?*anyopaque, _: i32, _: u32) !void {
        cast(ctx).record(.rm_fb);
    }
    fn pageFlip(ctx: ?*anyopaque, _: i32, crtc_id: u32, fb_id: u32, flags: u32, user_data: u64) !void {
        const self = cast(ctx);
        self.record(.page_flip);
        try self.flip_calls.append(self.allocator, .{ .crtc_id = crtc_id, .fb_id = fb_id, .flags = flags, .user_data = user_data });
        if (self.fail_page_flip) |e| return e;
        if (self.auto_flip_event) self.queueFlipEvent(crtc_id, user_data);
    }
    fn connectorSetProperty(ctx: ?*anyopaque, _: i32, connector_id: u32, prop_id: u32, value: u64) !void {
        const self = cast(ctx);
        self.record(.set_property);
        try self.prop_calls.append(self.allocator, .{ .connector_id = connector_id, .prop_id = prop_id, .value = value });
    }
    fn read(ctx: ?*anyopaque, _: i32, buf: []u8) !usize {
        const self = cast(ctx);
        self.record(.read);
        if (self.events.items.len == 0) return error.WouldBlock;
        const n = @min(buf.len, self.events.items.len);
        @memcpy(buf[0..n], self.events.items[0..n]);
        const remaining = self.events.items.len - n;
        std.mem.copyForwards(u8, self.events.items[0..remaining], self.events.items[n..]);
        self.events.shrinkRetainingCapacity(remaining);
        return n;
    }
    fn poll(ctx: ?*anyopaque, _: i32, _: i32) !void {
        cast(ctx).record(.poll);
    }

    // Unused by drm3d (no dumb buffers / legacy cursor): stubs.
    fn createDumb(_: ?*anyopaque, _: i32, _: u32, _: u32, _: u32) !drm2d.DumbBuffer {
        return error.Unsupported;
    }
    fn mapDumb(_: ?*anyopaque, _: i32, _: u32) !u64 {
        return error.Unsupported;
    }
    fn destroyDumb(_: ?*anyopaque, _: i32, _: u32) !void {
        return error.Unsupported;
    }
    fn dirtyFb(_: ?*anyopaque, _: i32, _: u32, _: []const Clip) !void {
        return error.Unsupported;
    }
    fn setCursor2(_: ?*anyopaque, _: i32, _: u32, _: u32, _: u32, _: u32, _: i32, _: i32) !void {
        return error.Unsupported;
    }
    fn moveCursor(_: ?*anyopaque, _: i32, _: u32, _: i32, _: i32) !void {
        return error.Unsupported;
    }
    fn mmap(_: ?*anyopaque, _: i32, _: usize, _: u64) ![]align(std.heap.page_size_min) u8 {
        return error.Unsupported;
    }
    fn munmap(_: ?*anyopaque, _: []align(std.heap.page_size_min) u8) void {}
};

// -- Fake GBM/EGL/GL GPU --

const FakeBo = struct {
    handle: u32,
    stride: u32,
    fd: i32,
    locked: bool = false,
    released_count: usize = 0,
};

const FakeSurface = struct {
    width: u32,
    height: u32,
    format: u32,
    flags: u32,
    bos: [3]FakeBo,
    front: usize = 0,
    /// Mesa-style buffer ages: 0 = never presented, else frames since the
    /// bo was last front (incremented for every presented bo on each swap).
    ages: [3]i32 = .{ 0, 0, 0 },
    destroyed: bool = false,
};

const TexUpload = struct {
    tex: u32,
    sub: bool,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    format: u32,
    /// First word of row 0 and row 1 of the uploaded pixels (4-byte formats
    /// only), so tests can verify sub-width row-copy uploads.
    sample: [2]u32 = .{ 0, 0 },
};

const ScissorBox = struct { x: i32, y: i32, w: i32, h: i32 };
const ClearRec = struct { mask: u32, scissor: ?ScissorBox };

const FakeGpu = struct {
    allocator: Allocator,
    // GBM
    device_created: bool = false,
    device_destroyed: bool = false,
    device_fd: i32 = -1,
    surface: ?FakeSurface = null,
    next_handle: u32 = 100,
    next_dmabuf: i32 = 300,
    // EGL
    egl_initialized: bool = false,
    egl_terminated: bool = false,
    api_bound: ?u32 = null,
    context_created: bool = false,
    context_destroyed: bool = false,
    window_created: bool = false,
    window_destroyed: bool = false,
    current: bool = false,
    swap_count: usize = 0,
    images_created: usize = 0,
    images_destroyed: usize = 0,
    last_image_attribs: std.ArrayList(i32) = .empty,
    // GL
    next_tex: u32 = 1,
    next_prog: u32 = 1,
    next_buf: u32 = 1,
    textures_alive: std.ArrayList(u32) = .empty,
    uploads: std.ArrayList(TexUpload) = .empty,
    draw_count: usize = 0,
    scissor_enabled: bool = false,
    /// GL_BLEND state (initGl enables it; the model starts enabled).
    blend_enabled: bool = true,
    /// Blend state active at each draw: false for the opaque staging copy.
    draw_blend: std.ArrayList(bool) = .empty,
    scissor_boxes: std.ArrayList(ScissorBox) = .empty,
    clears: std.ArrayList(ClearRec) = .empty,
    /// Scissor box active at each draw (null = scissor disabled).
    draw_boxes: std.ArrayList(?ScissorBox) = .empty,
    /// Every u_dst uniform value (quad destination rects), in order.
    dst_rects: std.ArrayList([4]f32) = .empty,
    image_target_count: usize = 0,
    program_linked: bool = false,
    fail_lock: bool = false,
    fail_create_image: bool = false,
    fail_buffer_age: bool = false,
    // ordering across all three seams
    calls: std.ArrayList(GpuCall) = .empty,

    const GpuCall = enum {
        gbm_create_device,
        gbm_surface_create,
        gbm_lock,
        gbm_release,
        gbm_surface_destroy,
        gbm_destroy_device,
        egl_create_context,
        egl_create_window,
        egl_make_current,
        egl_swap,
        egl_create_image,
        egl_destroy_image,
        egl_destroy_context,
        egl_terminate,
        gl_gen_texture,
        gl_delete_texture,
        gl_tex_image,
        gl_tex_sub_image,
        gl_draw,
        gl_scissor,
        gl_enable,
        gl_disable,
        gl_clear,
        gl_image_target,
        gl_delete_program,
    };

    fn deinit(self: *FakeGpu) void {
        self.last_image_attribs.deinit(self.allocator);
        self.textures_alive.deinit(self.allocator);
        self.uploads.deinit(self.allocator);
        self.scissor_boxes.deinit(self.allocator);
        self.clears.deinit(self.allocator);
        self.draw_boxes.deinit(self.allocator);
        self.draw_blend.deinit(self.allocator);
        self.dst_rects.deinit(self.allocator);
        self.calls.deinit(self.allocator);
    }
    fn record(self: *FakeGpu, call: GpuCall) void {
        self.calls.append(self.allocator, call) catch @panic("fake: oom");
    }
    fn count(self: *const FakeGpu, call: GpuCall) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (c == call) n += 1;
        }
        return n;
    }
    fn cast(ctx: ?*anyopaque) *FakeGpu {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn boPtr(self: *FakeGpu, idx: usize) GbmBo {
        return @ptrCast(&self.surface.?.bos[idx]);
    }
    fn boIndex(self: *FakeGpu, bo: GbmBo) usize {
        const base = @intFromPtr(&self.surface.?.bos[0]);
        const p = @intFromPtr(bo);
        return (p - base) / @sizeOf(FakeBo);
    }

    fn gbmOps(self: *FakeGpu) GbmOps {
        return .{
            .ctx = self,
            .create_device = createDevice,
            .destroy_device = destroyDevice,
            .surface_create = surfaceCreate,
            .surface_destroy = surfaceDestroy,
            .lock_front_buffer = lockFront,
            .release_buffer = releaseBuffer,
            .has_free_buffers = hasFreeBuffers,
            .bo_info = boInfo,
            .bo_get_fd = boGetFd,
            .close_fd = closeFd,
        };
    }
    fn eglOps(self: *FakeGpu) EglOps {
        return .{
            .ctx = self,
            .get_display = getDisplay,
            .initialize = initialize,
            .terminate = terminate,
            .bind_api = bindApi,
            .choose_config = chooseConfig,
            .create_context = createContext,
            .destroy_context = destroyContext,
            .create_window_surface = createWindowSurface,
            .destroy_surface = destroySurface,
            .make_current = makeCurrent,
            .swap_buffers = swapBuffers,
            .create_image = createImage,
            .destroy_image = destroyImage,
            .buffer_age = bufferAge,
        };
    }
    fn glOps(self: *FakeGpu) GlOps {
        return .{
            .ctx = self,
            .create_shader = createShader,
            .shader_source = shaderSource,
            .compile_shader = compileShader,
            .get_shaderiv = getShaderiv,
            .delete_shader = deleteShader,
            .create_program = createProgram,
            .attach_shader = attachShader,
            .link_program = linkProgram,
            .get_programiv = getProgramiv,
            .use_program = useProgram,
            .delete_program = deleteProgram,
            .get_attrib_location = getAttribLocation,
            .get_uniform_location = getUniformLocation,
            .enable_vertex_attrib_array = enableVertexAttribArray,
            .vertex_attrib_pointer = vertexAttribPointer,
            .gen_buffers = genBuffers,
            .delete_buffers = deleteBuffers,
            .bind_buffer = bindBuffer,
            .buffer_data = bufferData,
            .uniform1i = uniform1i,
            .uniform1f = uniform1f,
            .uniform2f = uniform2f,
            .uniform4f = uniform4f,
            .draw_arrays = drawArrays,
            .viewport = viewport,
            .clear_color = clearColor,
            .clear = clear,
            .scissor = scissor,
            .active_texture = activeTexture,
            .gen_textures = genTextures,
            .delete_textures = deleteTextures,
            .bind_texture = bindTexture,
            .tex_image_2d = texImage2D,
            .tex_sub_image_2d = texSubImage2D,
            .tex_parameteri = texParameteri,
            .pixel_storei = pixelStorei,
            .enable = enable,
            .disable = disable,
            .blend_func = blendFunc,
            .image_target_texture_2d = imageTargetTexture2D,
            .flush = flush,
        };
    }

    // GBM
    fn createDevice(ctx: ?*anyopaque, fd: i32) !GbmDevice {
        const self = cast(ctx);
        self.record(.gbm_create_device);
        self.device_created = true;
        self.device_fd = fd;
        return @ptrCast(self);
    }
    fn destroyDevice(ctx: ?*anyopaque, _: GbmDevice) void {
        const self = cast(ctx);
        self.record(.gbm_destroy_device);
        self.device_destroyed = true;
    }
    fn surfaceCreate(ctx: ?*anyopaque, _: GbmDevice, width: u32, height: u32, format: u32, flags: u32) !GbmSurface {
        const self = cast(ctx);
        self.record(.gbm_surface_create);
        var bos: [3]FakeBo = undefined;
        for (&bos, 0..) |*b, i| {
            b.* = .{ .handle = self.next_handle, .stride = width * 4, .fd = self.next_dmabuf };
            self.next_handle += 1;
            self.next_dmabuf += 1;
            _ = i;
        }
        self.surface = .{ .width = width, .height = height, .format = format, .flags = flags, .bos = bos };
        return @ptrCast(&self.surface.?);
    }
    fn surfaceDestroy(ctx: ?*anyopaque, _: GbmSurface) void {
        const self = cast(ctx);
        self.record(.gbm_surface_destroy);
        if (self.surface) |*s| s.destroyed = true;
    }
    fn lockFront(ctx: ?*anyopaque, _: GbmSurface) !GbmBo {
        const self = cast(ctx);
        self.record(.gbm_lock);
        if (self.fail_lock) return error.Busy;
        const idx = self.surface.?.front;
        self.surface.?.bos[idx].locked = true;
        return self.boPtr(idx);
    }
    fn releaseBuffer(ctx: ?*anyopaque, _: GbmSurface, bo: GbmBo) void {
        const self = cast(ctx);
        self.record(.gbm_release);
        const idx = self.boIndex(bo);
        self.surface.?.bos[idx].locked = false;
        self.surface.?.bos[idx].released_count += 1;
    }
    fn hasFreeBuffers(ctx: ?*anyopaque, _: GbmSurface) bool {
        const self = cast(ctx);
        for (self.surface.?.bos) |b| {
            if (!b.locked) return true;
        }
        return false;
    }
    fn boInfo(ctx: ?*anyopaque, bo: GbmBo) GbmBoInfo {
        const self = cast(ctx);
        const idx = self.boIndex(bo);
        const b = self.surface.?.bos[idx];
        return .{ .width = self.surface.?.width, .height = self.surface.?.height, .stride = b.stride, .format = self.surface.?.format, .handle = b.handle, .modifier = DRM_FORMAT_MOD_LINEAR };
    }
    fn boGetFd(ctx: ?*anyopaque, bo: GbmBo) !i32 {
        const self = cast(ctx);
        return self.surface.?.bos[self.boIndex(bo)].fd;
    }
    fn closeFd(_: ?*anyopaque, _: i32) void {}

    // EGL
    fn getDisplay(ctx: ?*anyopaque, _: GbmDevice) !EglDisplay {
        return @ptrCast(cast(ctx));
    }
    fn initialize(ctx: ?*anyopaque, _: EglDisplay) !void {
        cast(ctx).egl_initialized = true;
    }
    fn terminate(ctx: ?*anyopaque, _: EglDisplay) void {
        const self = cast(ctx);
        self.record(.egl_terminate);
        self.egl_terminated = true;
    }
    fn bindApi(ctx: ?*anyopaque, api: u32) !void {
        cast(ctx).api_bound = api;
    }
    fn chooseConfig(ctx: ?*anyopaque, _: EglDisplay, _: []const i32, configs: []EglConfig) !usize {
        configs[0] = @ptrCast(cast(ctx));
        return 1;
    }
    fn createContext(ctx: ?*anyopaque, _: EglDisplay, _: EglConfig, _: ?EglContext, _: []const i32) !EglContext {
        const self = cast(ctx);
        self.record(.egl_create_context);
        self.context_created = true;
        return @ptrCast(self);
    }
    fn destroyContext(ctx: ?*anyopaque, _: EglDisplay, _: EglContext) void {
        const self = cast(ctx);
        self.record(.egl_destroy_context);
        self.context_destroyed = true;
    }
    fn createWindowSurface(ctx: ?*anyopaque, _: EglDisplay, _: EglConfig, _: GbmSurface, _: []const i32) !EglSurface {
        const self = cast(ctx);
        self.record(.egl_create_window);
        self.window_created = true;
        return @ptrCast(self);
    }
    fn destroySurface(ctx: ?*anyopaque, _: EglDisplay, _: EglSurface) void {
        const self = cast(ctx);
        self.record(.egl_destroy_context); // reuse slot ordering marker
        self.window_destroyed = true;
    }
    fn makeCurrent(ctx: ?*anyopaque, _: EglDisplay, draw: ?EglSurface, _: ?EglSurface, _: ?EglContext) !void {
        const self = cast(ctx);
        self.record(.egl_make_current);
        self.current = draw != null;
    }
    fn swapBuffers(ctx: ?*anyopaque, _: EglDisplay, _: EglSurface) !void {
        const self = cast(ctx);
        self.record(.egl_swap);
        self.swap_count += 1;
        // Promote the next bo to front (models EGL/GBM back->front) and
        // track mesa-style ages: every presented bo ages one frame per
        // swap; the newly presented bo starts at age 1.
        const s = &self.surface.?;
        const idx = (s.front + 1) % s.bos.len;
        for (&s.ages) |*a| {
            if (a.* > 0) a.* += 1;
        }
        s.ages[idx] = 1;
        s.front = idx;
    }
    fn bufferAge(ctx: ?*anyopaque, _: EglDisplay, _: EglSurface) ?i32 {
        const self = cast(ctx);
        if (self.fail_buffer_age) return null;
        const s = &self.surface.?;
        // The back buffer is the bo the next swap will present.
        return s.ages[(s.front + 1) % s.bos.len];
    }
    fn createImage(ctx: ?*anyopaque, _: EglDisplay, _: ?EglContext, _: u32, _: ?*anyopaque, attribs: []const i32) !EglImage {
        const self = cast(ctx);
        self.record(.egl_create_image);
        if (self.fail_create_image) return error.Unsupported;
        self.images_created += 1;
        self.last_image_attribs.clearRetainingCapacity();
        self.last_image_attribs.appendSlice(self.allocator, attribs) catch @panic("fake: oom");
        return @ptrFromInt(0x1000 + self.images_created);
    }
    fn destroyImage(ctx: ?*anyopaque, _: EglDisplay, _: EglImage) void {
        const self = cast(ctx);
        self.record(.egl_destroy_image);
        self.images_destroyed += 1;
    }

    // GL
    fn createShader(_: ?*anyopaque, _: u32) !u32 {
        return 1;
    }
    fn shaderSource(_: ?*anyopaque, _: u32, _: [*:0]const u8) void {}
    fn compileShader(_: ?*anyopaque, _: u32) void {}
    fn getShaderiv(_: ?*anyopaque, _: u32, _: u32, out: *i32) void {
        out.* = 1;
    }
    fn deleteShader(_: ?*anyopaque, _: u32) void {}
    fn createProgram(ctx: ?*anyopaque) !u32 {
        const self = cast(ctx);
        const p = self.next_prog;
        self.next_prog += 1;
        return p;
    }
    fn attachShader(_: ?*anyopaque, _: u32, _: u32) void {}
    fn linkProgram(ctx: ?*anyopaque, _: u32) void {
        cast(ctx).program_linked = true;
    }
    fn getProgramiv(_: ?*anyopaque, _: u32, _: u32, out: *i32) void {
        out.* = 1;
    }
    fn useProgram(_: ?*anyopaque, _: u32) void {}
    fn deleteProgram(ctx: ?*anyopaque, _: u32) void {
        cast(ctx).record(.gl_delete_program);
    }
    fn getAttribLocation(_: ?*anyopaque, _: u32, _: [*:0]const u8) i32 {
        return 0;
    }
    fn getUniformLocation(_: ?*anyopaque, _: u32, name: [*:0]const u8) i32 {
        const s = std.mem.span(name);
        if (std.mem.eql(u8, s, "u_dst")) return 1;
        if (std.mem.eql(u8, s, "u_src")) return 2;
        return 0;
    }
    fn enableVertexAttribArray(_: ?*anyopaque, _: u32) void {}
    fn vertexAttribPointer(_: ?*anyopaque, _: u32, _: i32, _: u32, _: bool, _: i32, _: ?*const anyopaque) void {}
    fn genBuffers(ctx: ?*anyopaque, n: usize, ids: []u32) void {
        const self = cast(ctx);
        for (0..n) |i| {
            ids[i] = self.next_buf;
            self.next_buf += 1;
        }
    }
    fn deleteBuffers(_: ?*anyopaque, _: usize, _: []const u32) void {}
    fn bindBuffer(_: ?*anyopaque, _: u32, _: u32) void {}
    fn bufferData(_: ?*anyopaque, _: u32, _: usize, _: ?*const anyopaque, _: u32) void {}
    fn uniform1i(_: ?*anyopaque, _: i32, _: i32) void {}
    fn uniform1f(_: ?*anyopaque, _: i32, _: f32) void {}
    fn uniform2f(_: ?*anyopaque, _: i32, _: f32, _: f32) void {}
    fn uniform4f(ctx: ?*anyopaque, loc: i32, x: f32, y: f32, z: f32, w: f32) void {
        const self = cast(ctx);
        if (loc == 1) self.dst_rects.append(self.allocator, .{ x, y, z, w }) catch @panic("fake: oom");
    }
    fn drawArrays(ctx: ?*anyopaque, _: u32, _: i32, _: i32) void {
        const self = cast(ctx);
        self.record(.gl_draw);
        self.draw_count += 1;
        self.draw_boxes.append(self.allocator, self.currentScissor()) catch @panic("fake: oom");
        self.draw_blend.append(self.allocator, self.blend_enabled) catch @panic("fake: oom");
    }
    fn currentScissor(self: *const FakeGpu) ?ScissorBox {
        if (!self.scissor_enabled or self.scissor_boxes.items.len == 0) return null;
        return self.scissor_boxes.items[self.scissor_boxes.items.len - 1];
    }
    fn viewport(_: ?*anyopaque, _: i32, _: i32, _: i32, _: i32) void {}
    fn clearColor(_: ?*anyopaque, _: f32, _: f32, _: f32, _: f32) void {}
    fn clear(ctx: ?*anyopaque, mask: u32) void {
        const self = cast(ctx);
        self.record(.gl_clear);
        self.clears.append(self.allocator, .{ .mask = mask, .scissor = self.currentScissor() }) catch @panic("fake: oom");
    }
    fn activeTexture(_: ?*anyopaque, _: u32) void {}
    fn genTextures(ctx: ?*anyopaque, n: usize, ids: []u32) void {
        const self = cast(ctx);
        self.record(.gl_gen_texture);
        for (0..n) |i| {
            ids[i] = self.next_tex;
            self.next_tex += 1;
            self.textures_alive.append(self.allocator, ids[i]) catch @panic("fake: oom");
        }
    }
    fn deleteTextures(ctx: ?*anyopaque, n: usize, ids: []const u32) void {
        const self = cast(ctx);
        self.record(.gl_delete_texture);
        for (0..n) |i| {
            for (self.textures_alive.items, 0..) |t, j| {
                if (t == ids[i]) {
                    _ = self.textures_alive.swapRemove(j);
                    break;
                }
            }
        }
    }
    fn bindTexture(_: ?*anyopaque, _: u32, _: u32) void {}
    fn texImage2D(ctx: ?*anyopaque, _: u32, _: i32, _: i32, w: i32, h: i32, _: i32, format: u32, _: u32, pixels: ?*const anyopaque) void {
        const self = cast(ctx);
        self.record(.gl_tex_image);
        self.uploads.append(self.allocator, .{ .tex = 0, .sub = false, .x = 0, .y = 0, .w = w, .h = h, .format = format, .sample = uploadSample(pixels, w, h, format) }) catch @panic("fake: oom");
    }
    fn texSubImage2D(ctx: ?*anyopaque, _: u32, _: i32, x: i32, y: i32, w: i32, h: i32, format: u32, _: u32, pixels: ?*const anyopaque) void {
        const self = cast(ctx);
        self.record(.gl_tex_sub_image);
        self.uploads.append(self.allocator, .{ .tex = 0, .sub = true, .x = x, .y = y, .w = w, .h = h, .format = format, .sample = uploadSample(pixels, w, h, format) }) catch @panic("fake: oom");
    }
    /// First word of rows 0 and 1 of an upload (4-byte formats only).
    fn uploadSample(pixels: ?*const anyopaque, w: i32, h: i32, format: u32) [2]u32 {
        var sample: [2]u32 = .{ 0, 0 };
        const p = pixels orelse return sample;
        if (format != gl.BGRA and format != gl.RGBA) return sample;
        const base: [*]const u8 = @ptrCast(p);
        sample[0] = std.mem.readInt(u32, base[0..4], .little);
        if (h >= 2) {
            const off: usize = @intCast(w * 4);
            sample[1] = std.mem.readInt(u32, base[off..][0..4], .little);
        }
        return sample;
    }
    fn texParameteri(_: ?*anyopaque, _: u32, _: u32, _: i32) void {}
    fn pixelStorei(_: ?*anyopaque, _: u32, _: i32) void {}
    fn enable(ctx: ?*anyopaque, cap: u32) void {
        const self = cast(ctx);
        self.record(.gl_enable);
        if (cap == gl.SCISSOR_TEST) self.scissor_enabled = true;
        if (cap == gl.BLEND) self.blend_enabled = true;
    }
    fn disable(ctx: ?*anyopaque, cap: u32) void {
        const self = cast(ctx);
        self.record(.gl_disable);
        if (cap == gl.SCISSOR_TEST) self.scissor_enabled = false;
        if (cap == gl.BLEND) self.blend_enabled = false;
    }
    fn scissor(ctx: ?*anyopaque, x: i32, y: i32, w: i32, h: i32) void {
        const self = cast(ctx);
        self.record(.gl_scissor);
        self.scissor_boxes.append(self.allocator, .{ .x = x, .y = y, .w = w, .h = h }) catch @panic("fake: oom");
    }
    fn blendFunc(_: ?*anyopaque, _: u32, _: u32) void {}
    fn imageTargetTexture2D(ctx: ?*anyopaque, _: u32, _: EglImage) void {
        const self = cast(ctx);
        self.record(.gl_image_target);
        self.image_target_count += 1;
    }
    fn flush(_: ?*anyopaque) void {}
};

/// init + takeMaster + setMode on the fake (HDMI-A-1, preferred 1920x1080).
fn setupActive(a: Allocator, drm: *FakeDrm, gpu: *FakeGpu) !*Drm3d {
    const d = try Drm3d.init(a, "/dev/dri/card0", drm.ops(), gpu.gbmOps(), gpu.eglOps(), gpu.glOps());
    errdefer d.deinit();
    try d.takeMaster();
    try d.setMode(1, 1);
    return d;
}

test "init: creates GBM device + EGL context, defers master and surface" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();

    const d = try Drm3d.init(a, "/dev/dri/card0", drm.ops(), gpu.gbmOps(), gpu.eglOps(), gpu.glOps());
    defer d.deinit();

    try testing.expect(gpu.device_created);
    try testing.expect(gpu.egl_initialized);
    try testing.expect(gpu.context_created);
    try testing.expectEqual(egl.OPENGL_ES_API, gpu.api_bound.?);
    // No surface yet (mode-sized, created in setMode), no master.
    try testing.expect(gpu.surface == null);
    try testing.expect(!d.isMaster());
    try testing.expectEqual(@as(usize, 0), drm.count(.set_master));
    // Read-only probe before master (constraint #3).
    for (drm.probe_flags.items) |p| try testing.expect(!p);
    try testing.expectEqual(@as(?usize, 1), d.chosen);
}

test "setMode: GBM surface XRGB8888 + window surface, primes a bo, SetCrtc before flips" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    const s = gpu.surface.?;
    try testing.expectEqual(@as(u32, 1920), s.width);
    try testing.expectEqual(@as(u32, 1080), s.height);
    try testing.expectEqual(gbm.FORMAT_XRGB8888, s.format);
    try testing.expectEqual(gbm.BO_USE_SCANOUT | gbm.BO_USE_RENDERING, s.flags);
    try testing.expect(gpu.window_created);
    try testing.expect(gpu.program_linked);
    // Priming swapped + locked one bo and AddFB'd it; SetCrtc used that fb.
    try testing.expectEqual(@as(usize, 1), gpu.swap_count);
    try testing.expectEqual(@as(usize, 1), gpu.count(.gbm_lock));
    try testing.expectEqual(@as(usize, 1), drm.add_fb_calls.items.len);
    try testing.expectEqual(@as(usize, 1), drm.set_crtc_calls.items.len);
    try testing.expectEqual(drm.add_fb_calls.items[0].fb_id, drm.set_crtc_calls.items[0].fb_id);
    try testing.expectEqual(@as(u32, 41), drm.set_crtc_calls.items[0].crtc_id);
    try testing.expectEqualSlices(u32, &.{62}, drm.set_crtc_calls.items[0].connector_ids);
    // No page flip yet.
    try testing.expectEqual(@as(usize, 0), drm.count(.page_flip));
    try testing.expect(d.scanout != null);
    try testing.expect(d.needsFullRedraw());
}

test "frame loop: beginFrame/endFrame lock -> flip -> release sequence" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    // Frame 1: draw into staging, endFrame uploads + swaps + locks + flips.
    const f1 = try d.beginFrame();
    try testing.expectEqual(@as(u32, 1920), f1.width);
    f1.set(0, 0, 0x11223344);
    const locks_before = gpu.count(.gbm_lock);
    try d.endFrame(&.{});
    try testing.expect(d.flipPending());
    try testing.expectEqual(locks_before + 1, gpu.count(.gbm_lock));
    try testing.expectEqual(@as(usize, 1), drm.flip_calls.items.len);
    try testing.expectEqual(drmc.PAGE_FLIP_EVENT, drm.flip_calls.items[0].flags);
    // The CPU staging path uploaded a texture and drew a quad.
    try testing.expect(gpu.draw_count >= 1);
    // EGLImage imported + bound for the locked bo.
    try testing.expectEqual(@as(usize, 1), gpu.images_created);
    try testing.expectEqual(@as(usize, 1), gpu.image_target_count);

    // One outstanding flip: no second begin/end while pending.
    try testing.expectError(error.Busy, d.beginFrame());
    try testing.expectError(error.Busy, d.endFrame(&.{}));

    // Frame 1 completes: the bo primed by setMode (the old scanout) is released.
    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.readEvents();
    try testing.expect(!d.flipPending());
    try testing.expectEqual(@as(usize, 1), gpu.count(.gbm_release));

    // Frame 2: lock a new bo, flip.
    _ = try d.beginFrame();
    try d.endFrame(&.{});
    try testing.expectEqual(@as(usize, 2), drm.flip_calls.items.len);
    try testing.expectEqual(@as(usize, 2), gpu.images_created);
    // The previous image is destroyed when the new one is imported.
    try testing.expectEqual(@as(usize, 1), gpu.images_destroyed);

    // Frame 2 completes: the previous scanout bo is released back to GBM.
    const release_before = gpu.count(.gbm_release);
    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.readEvents();
    try testing.expect(!d.flipPending());
    try testing.expectEqual(release_before + 1, gpu.count(.gbm_release));
}

test "flip: EBUSY keeps pending set, only FLIP_COMPLETE clears it" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    _ = try d.beginFrame();
    try d.endFrame(&.{});
    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.readEvents();
    try testing.expect(!d.flipPending());

    drm.fail_page_flip = error.Busy;
    _ = try d.beginFrame();
    try testing.expectError(error.Busy, d.endFrame(&.{}));
    try testing.expect(d.flipPending());
    drm.fail_page_flip = null;

    // Wrong CRTC/cookie does not clear pending.
    drm.queueFlipEvent(999, 0xDEAD);
    try d.readEvents();
    try testing.expect(d.flipPending());
    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.readEvents();
    try testing.expect(!d.flipPending());
}

test "atlas: upload driven by generation + dirtyRects, skipped when unchanged" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    var atlas = try GlyphAtlas.init(a, 64, 64);
    defer atlas.deinit();

    // First upload: full pages (a8 GL_ALPHA + bgra8 GL_BGRA).
    const gen0 = atlas.generation;
    try d.uploadAtlas(&atlas);
    try testing.expectEqual(@as(usize, 2), gpu.count(.gl_tex_image));
    try testing.expectEqual(gl.ALPHA, gpu.uploads.items[gpu.uploads.items.len - 2].format);
    try testing.expectEqual(gl.BGRA, gpu.uploads.items[gpu.uploads.items.len - 1].format);

    // Unchanged generation: no upload at all.
    const uploads_before = gpu.uploads.items.len;
    try d.uploadAtlas(&atlas);
    try testing.expectEqual(uploads_before, gpu.uploads.items.len);
    try testing.expectEqual(gen0, atlas.generation);

    // Insert a glyph: generation bumps, dirty rect drives a sub-upload.
    const bitmap: [64]u8 = @splat(0xFF);
    _ = try atlas.insert(.{ .face_id = 0, .glyph_index = 1, .size_px = 16 }, .{}, .{ .format = .a8, .width = 8, .height = 8, .data = &bitmap });
    try testing.expect(atlas.generation != gen0);
    try testing.expectEqual(@as(usize, 1), atlas.dirtyRects().len);
    const sub_before = gpu.count(.gl_tex_sub_image);
    try d.uploadAtlas(&atlas);
    // One sub-upload per dirty rect per page (a8 + bgra8).
    try testing.expectEqual(sub_before + 2, gpu.count(.gl_tex_sub_image));
    const last = gpu.uploads.items[gpu.uploads.items.len - 1];
    try testing.expect(last.sub);
    try testing.expectEqual(@as(i32, 8), last.w);
    try testing.expectEqual(@as(i32, 8), last.h);
}

test "GL hooks: drawCells and drawImage mark the frame GL-drawn (no staging upload)" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    var atlas = try GlyphAtlas.init(a, 64, 64);
    defer atlas.deinit();
    try d.uploadAtlas(&atlas);

    _ = try d.beginFrame();
    const draws_before = gpu.draw_count;
    try d.drawCells(&.{.{ .x = 0, .y = 0, .w = 8, .h = 16, .sx = 0, .sy = 0, .sw = 8, .sh = 16, .page = 0, .fg = 0xFF0000 }});
    try testing.expectEqual(draws_before + 1, gpu.draw_count);
    try testing.expect(d.gl_frame);

    const pixels: [64]u8 = @splat(0xFF);
    try d.drawImage(.{ .width = 4, .height = 4, .pixels = &pixels }, .{ .x = 10, .y = 10, .w = 4, .h = 4 });
    try testing.expectEqual(draws_before + 2, gpu.draw_count);

    // endFrame must NOT present staging (GL already drew): the only tex_image
    // uploads are the atlas (2) + the image (1), not a staging upload.
    const tex_images_before = gpu.count(.gl_tex_image);
    try d.endFrame(&.{});
    try testing.expectEqual(tex_images_before, gpu.count(.gl_tex_image));
    try testing.expect(d.flipPending());
}

test "master handoff: drop waits flip, take re-modesets with the scanout fb" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    _ = try d.beginFrame();
    try d.endFrame(&.{});
    try testing.expect(d.flipPending());
    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.dropMaster();
    try testing.expect(!d.isMaster());
    try testing.expect(!d.flipPending());
    try testing.expectEqual(@as(usize, 1), drm.count(.drop_master));

    const modesets_before = drm.set_crtc_calls.items.len;
    try d.takeMaster();
    try testing.expect(d.isMaster());
    try testing.expectEqual(modesets_before + 1, drm.set_crtc_calls.items.len);
    try testing.expect(d.needsFullRedraw());

    drm.fail_drop_master = error.InvalidArgument;
    try d.dropMaster();
    try testing.expect(!d.isMaster());
}

test "dpms: property set, flips refused while off, wake re-modesets" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    try d.setDpms(.off);
    try testing.expectEqual(DpmsState.off, d.dpmsState());
    try testing.expectEqual(FakeDrm.PropCall{ .connector_id = 62, .prop_id = 7, .value = 3 }, drm.prop_calls.items[0]);
    try testing.expectError(error.DisplayOff, d.endFrame(&.{}));

    const modesets_before = drm.set_crtc_calls.items.len;
    try d.setDpms(.on);
    try testing.expectEqual(FakeDrm.PropCall{ .connector_id = 62, .prop_id = 7, .value = 0 }, drm.prop_calls.items[1]);
    try testing.expectEqual(modesets_before + 1, drm.set_crtc_calls.items.len);
    try testing.expect(d.needsFullRedraw());
    _ = try d.beginFrame();
    try d.endFrame(&.{});
    try testing.expect(d.flipPending());
}

test "cursor: unsupported fallback (GL composites a software cursor)" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    try testing.expect(!d.supportsHwCursor());
    var img = try Framebuffer.create(a, 8, 8, .argb8888, null);
    defer img.destroy(a);
    try testing.expectError(error.Unsupported, d.setCursor(&img, 0, 0));
    try testing.expectError(error.Unsupported, d.setCursor(null, 0, 0));
    // The Unsupported returns above are the fallback contract: the renderer
    // composites a software cursor; drm3d issues no legacy cursor ioctls.
}

test "teardown: release bos -> drop master -> GL/EGL -> RmFB -> GBM surface/device -> close" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    _ = try d.beginFrame();
    try d.endFrame(&.{});
    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.readEvents();

    const drm_before = drm.calls.items.len;
    const gpu_before = gpu.calls.items.len;
    d.deinit();

    // DRM tail: drop master, RmFB (cached), close last.
    const dtail = drm.calls.items[drm_before..];
    try testing.expectEqual(FakeDrm.DrmCall.drop_master, dtail[0]);
    try testing.expectEqual(FakeDrm.DrmCall.close, dtail[dtail.len - 1]);
    var saw_rm = false;
    for (dtail) |c| {
        if (c == .rm_fb) saw_rm = true;
    }
    try testing.expect(saw_rm);

    // GPU tail ordering: release before surface destroy before device destroy;
    // EGL terminate after context destroy; GL program deleted.
    const gtail = gpu.calls.items[gpu_before..];
    const pos = struct {
        fn f(items: []const FakeGpu.GpuCall, want: FakeGpu.GpuCall) !usize {
            for (items, 0..) |c, i| {
                if (c == want) return i;
            }
            return error.TestUnexpectedResult;
        }
    }.f;
    const rel = try pos(gtail, .gbm_release);
    const surf_destroy = try pos(gtail, .gbm_surface_destroy);
    const dev_destroy = try pos(gtail, .gbm_destroy_device);
    const term = try pos(gtail, .egl_terminate);
    const ctx_destroy = try pos(gtail, .egl_destroy_context);
    try testing.expect(rel < surf_destroy);
    try testing.expect(surf_destroy < dev_destroy);
    try testing.expect(ctx_destroy < term);
    try testing.expect(gpu.device_destroyed);
    try testing.expect(gpu.egl_terminated);
    try testing.expect(gpu.context_destroyed);
    // All GL textures freed.
    try testing.expectEqual(@as(usize, 0), gpu.textures_alive.items.len);
}

test "vtable: backend interface dispatches to the same state" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try Drm3d.init(a, "/dev/dri/card0", drm.ops(), gpu.gbmOps(), gpu.eglOps(), gpu.glOps());
    const b = d.backend();
    defer b.deinit();

    try d.takeMaster();
    const infos = try b.connectors();
    try testing.expectEqual(@as(usize, 2), infos.len);
    try b.setMode(1, 1);
    const frame = try b.beginFrame();
    try testing.expectEqual(@as(u32, 1920), frame.width);
    try b.endFrame(&.{});
    try testing.expect(b.flipPending());
    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.readEvents();
    try b.waitFlip();
    try testing.expect(!b.flipPending());
    try b.setDpms(.off);
    try testing.expectEqual(DpmsState.off, d.dpmsState());
    try testing.expect(!b.supportsHwCursor());
    try testing.expectError(error.Unsupported, b.setCursor(null, 0, 0));
}

test "mode: selectModeIndex honours mode= spec and preferred (M5.3 parity)" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try Drm3d.init(a, "/dev/dri/card0", drm.ops(), gpu.gbmOps(), gpu.eglOps(), gpu.glOps());
    defer d.deinit();
    // HDMI-A-1 (index 1): [1024x768@60, 1920x1080@60 (preferred)].
    try testing.expectEqual(@as(?usize, 1), try d.selectModeIndex(1, null, false));
    const spec = video.ModeSpec.parse("1024x768").?;
    try testing.expectEqual(@as(?usize, 0), try d.selectModeIndex(1, spec, false));
    // The fake seam has no get_crtc: current mode unknown, so
    // use-original-mode falls back to the preferred mode.
    try testing.expectEqual(@as(?usize, 1), try d.selectModeIndex(1, null, true));
}

// ---------------------------------------------------------------------------
// Damage-only presentation (M8.2). The fake models mesa's buffer ages with 3
// bos: after the prime + two frames the back buffer is 3 swaps old, so a
// partial present replays the current damage + the previous two frames'.
// ---------------------------------------------------------------------------

/// One begin/end/flip-complete cycle on the fake (HDMI-A-1, CRTC 41).
fn presentFrame(d: *Drm3d, drm: *FakeDrm, damage: []const Damage) !void {
    _ = try d.beginFrame();
    try d.endFrame(damage);
    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.readEvents();
}

test "damage: empty damage presents the full frame (M8.2 contract)" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    _ = try d.beginFrame();
    try d.endFrame(&.{});

    // Full staging upload, unscissored clear, full-screen quad.
    const up = gpu.uploads.items[gpu.uploads.items.len - 1];
    try testing.expect(!up.sub);
    try testing.expectEqual(@as(i32, 1920), up.w);
    try testing.expectEqual(@as(i32, 1080), up.h);
    try testing.expectEqual(gl.BGRA, up.format);
    try testing.expectEqual(@as(usize, 0), gpu.scissor_boxes.items.len);
    try testing.expect(!gpu.scissor_enabled);
    const clr = gpu.clears.items[gpu.clears.items.len - 1];
    try testing.expectEqual(gl.COLOR_BUFFER_BIT, clr.mask);
    try testing.expect(clr.scissor == null);
    try testing.expectEqual([4]f32{ 0, 0, 1920, 1080 }, gpu.dst_rects.items[gpu.dst_rects.items.len - 1]);
    try testing.expect(d.flipPending());
}

test "present: staging is drawn unblended (X byte is padding), GL hooks still blend" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    // initGl enables blending for the transparent GL hooks.
    try testing.expect(gpu.blend_enabled);

    // A CPU-rendered frame: staging pixels are 0x00RRGGBB, so BGRA alpha
    // reads 0. With SRC_ALPHA blending the whole terminal would vanish.
    _ = try d.beginFrame();
    try d.endFrame(&.{}); // full present
    try testing.expectEqual(false, gpu.draw_blend.items[gpu.draw_blend.items.len - 1]);
    try testing.expect(gpu.blend_enabled); // restored after the present

    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.readEvents();

    const r = Damage{ .x = 100, .y = 200, .w = 300, .h = 50 };
    _ = try d.beginFrame();
    try d.endFrame(&.{r}); // damage present: still unblended
    try testing.expectEqual(false, gpu.draw_blend.items[gpu.draw_blend.items.len - 1]);
    try testing.expect(gpu.blend_enabled);

    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.readEvents();

    // Transparent GL content keeps blending.
    _ = try d.beginFrame();
    const pixels: [64]u8 = @splat(0xFF);
    try d.drawImage(.{ .width = 4, .height = 4, .pixels = &pixels }, .{ .x = 10, .y = 10, .w = 4, .h = 4 });
    try testing.expectEqual(true, gpu.draw_blend.items[gpu.draw_blend.items.len - 1]);
}

test "damage: endFrame restricts upload, clear and draw to the damage rect" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    const r = Damage{ .x = 100, .y = 200, .w = 300, .h = 50 };
    try presentFrame(d, &drm, &.{}); // f1: full (empty damage)
    try presentFrame(d, &drm, &.{r}); // f2: age 0 -> full present, logical entry r
    try presentFrame(d, &drm, &.{r}); // f3: history holds full f1 -> full
    const tex_images = gpu.count(.gl_tex_image);
    const uploads = gpu.uploads.items.len;
    const clears = gpu.clears.items.len;
    const draws = gpu.draw_count;
    const flips = drm.flip_calls.items.len;

    _ = try d.beginFrame();
    try d.endFrame(&.{r}); // f4: age 3, history r+r -> damage only

    // Exactly one sub-upload of the rect; no full re-upload.
    try testing.expectEqual(tex_images, gpu.count(.gl_tex_image));
    try testing.expectEqual(uploads + 1, gpu.uploads.items.len);
    const up = gpu.uploads.items[gpu.uploads.items.len - 1];
    try testing.expect(up.sub);
    try testing.expectEqual(@as(i32, 100), up.x);
    try testing.expectEqual(@as(i32, 200), up.y);
    try testing.expectEqual(@as(i32, 300), up.w);
    try testing.expectEqual(@as(i32, 50), up.h);
    try testing.expectEqual(gl.BGRA, up.format);
    // Scissor box in GL bottom-left coords: y = 1080 - 200 - 50 = 830.
    const box = ScissorBox{ .x = 100, .y = 830, .w = 300, .h = 50 };
    try testing.expectEqual(box, gpu.scissor_boxes.items[gpu.scissor_boxes.items.len - 1]);
    try testing.expect(!gpu.scissor_enabled); // disabled after the present
    try testing.expectEqual(clears + 1, gpu.clears.items.len);
    try testing.expectEqual(@as(?ScissorBox, box), gpu.clears.items[gpu.clears.items.len - 1].scissor);
    try testing.expectEqual(draws + 1, gpu.draw_count);
    try testing.expectEqual(@as(?ScissorBox, box), gpu.draw_boxes.items[gpu.draw_boxes.items.len - 1]);
    try testing.expectEqual([4]f32{ 100, 200, 300, 50 }, gpu.dst_rects.items[gpu.dst_rects.items.len - 1]);
    // Still a real flip.
    try testing.expectEqual(flips + 1, drm.flip_calls.items.len);
}

test "damage: buffer age replays exactly the aged frames' damage" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    const ra = Damage{ .x = 10, .y = 10, .w = 20, .h = 20 };
    const rb = Damage{ .x = 100, .y = 200, .w = 300, .h = 50 };
    const rc = Damage{ .x = 500, .y = 400, .w = 60, .h = 70 };
    const rd = Damage{ .x = 700, .y = 600, .w = 40, .h = 40 };
    try presentFrame(d, &drm, &.{}); // f1: full
    try presentFrame(d, &drm, &.{ra}); // f2: age 0 -> full
    try presentFrame(d, &drm, &.{rb}); // f3: history holds full f1 -> full

    // f4: age 3 -> rc + rb + ra (the back buffer holds f1's content).
    var uploads = gpu.uploads.items.len;
    _ = try d.beginFrame();
    try d.endFrame(&.{rc});
    try testing.expectEqual(uploads + 3, gpu.uploads.items.len);
    try testing.expectEqual(@as(i32, 500), gpu.uploads.items[gpu.uploads.items.len - 3].x); // rc
    try testing.expectEqual(@as(i32, 100), gpu.uploads.items[gpu.uploads.items.len - 2].x); // rb
    try testing.expectEqual(@as(i32, 10), gpu.uploads.items[gpu.uploads.items.len - 1].x); // ra
    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.readEvents();

    // f5: age 3 -> rd + rc + rb; ra fell out of the age window.
    uploads = gpu.uploads.items.len;
    _ = try d.beginFrame();
    try d.endFrame(&.{rd});
    try testing.expectEqual(uploads + 3, gpu.uploads.items.len);
    for (gpu.uploads.items[uploads..]) |u| {
        try testing.expect(u.sub);
        try testing.expect(u.x != 10); // ra is NOT replayed
    }
    try testing.expectEqual(@as(i32, 700), gpu.uploads.items[gpu.uploads.items.len - 3].x); // rd
    try testing.expectEqual(@as(i32, 500), gpu.uploads.items[gpu.uploads.items.len - 2].x); // rc
    try testing.expectEqual(@as(i32, 100), gpu.uploads.items[gpu.uploads.items.len - 1].x); // rb
}

test "damage: rects are clipped to the mode and merged" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    const dmg = [_]Damage{
        .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .{ .x = 50, .y = 50, .w = 100, .h = 100 }, // overlaps -> {0,0,150,150}
        .{ .x = 1900, .y = 1000, .w = 200, .h = 200 }, // clips -> {1900,1000,20,80}
        .{ .x = 5000, .y = 5000, .w = 10, .h = 10 }, // fully outside -> dropped
    };
    try presentFrame(d, &drm, &.{});
    try presentFrame(d, &drm, &dmg);
    try presentFrame(d, &drm, &dmg);
    const uploads = gpu.uploads.items.len;
    _ = try d.beginFrame();
    try d.endFrame(&dmg);

    try testing.expectEqual(uploads + 2, gpu.uploads.items.len);
    const up_a = gpu.uploads.items[gpu.uploads.items.len - 2];
    const up_b = gpu.uploads.items[gpu.uploads.items.len - 1];
    try testing.expectEqual(@as(i32, 0), up_a.x);
    try testing.expectEqual(@as(i32, 0), up_a.y);
    try testing.expectEqual(@as(i32, 150), up_a.w);
    try testing.expectEqual(@as(i32, 150), up_a.h);
    try testing.expectEqual(@as(i32, 1900), up_b.x);
    try testing.expectEqual(@as(i32, 1000), up_b.y);
    try testing.expectEqual(@as(i32, 20), up_b.w);
    try testing.expectEqual(@as(i32, 80), up_b.h);
    // Scissor y flips: 1080-150=930 and 1080-1000-80=0.
    try testing.expectEqual(@as(usize, 2), gpu.scissor_boxes.items.len);
    try testing.expectEqual(ScissorBox{ .x = 0, .y = 930, .w = 150, .h = 150 }, gpu.scissor_boxes.items[0]);
    try testing.expectEqual(ScissorBox{ .x = 1900, .y = 0, .w = 20, .h = 80 }, gpu.scissor_boxes.items[1]);
}

test "damage: no visible change presents without drawing but still flips" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    const out = Damage{ .x = 5000, .y = 5000, .w = 10, .h = 10 };
    try presentFrame(d, &drm, &.{}); // f1: full
    try presentFrame(d, &drm, &.{out}); // f2: age 0 -> full, empty logical entry
    try presentFrame(d, &drm, &.{out}); // f3: history holds full f1 -> full
    const uploads = gpu.uploads.items.len;
    const clears = gpu.clears.items.len;
    const draws = gpu.draw_count;
    const flips = drm.flip_calls.items.len;

    _ = try d.beginFrame();
    try d.endFrame(&.{out}); // f4: aged damage all empty -> nothing to draw
    try testing.expectEqual(uploads, gpu.uploads.items.len);
    try testing.expectEqual(clears, gpu.clears.items.len);
    try testing.expectEqual(draws, gpu.draw_count);
    try testing.expectEqual(flips + 1, drm.flip_calls.items.len);
}

test "damage: full_redraw after modeset presents everything" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    try testing.expect(d.needsFullRedraw());
    _ = try d.beginFrame();
    try d.endFrame(&.{.{ .x = 10, .y = 10, .w = 20, .h = 20 }});
    const up = gpu.uploads.items[gpu.uploads.items.len - 1];
    try testing.expect(!up.sub);
    try testing.expectEqual(@as(i32, 1920), up.w);
    try testing.expectEqual(@as(usize, 0), gpu.scissor_boxes.items.len);
    try testing.expect(!d.needsFullRedraw());
}

test "damage: GL-drawn frames clear lazily and force the next frame full" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    var atlas = try GlyphAtlas.init(a, 64, 64);
    defer atlas.deinit();
    try d.uploadAtlas(&atlas);
    const r = Damage{ .x = 100, .y = 200, .w = 300, .h = 50 };
    try presentFrame(d, &drm, &.{}); // f1: staging full

    // f2: GL frame. The first draw clears the whole target; the second does not.
    _ = try d.beginFrame();
    const clears = gpu.clears.items.len;
    const cell = Cell{ .x = 0, .y = 0, .w = 8, .h = 16, .sx = 0, .sy = 0, .sw = 8, .sh = 16, .page = 0, .fg = 0xFF0000 };
    try d.drawCells(&.{cell});
    try testing.expectEqual(clears + 1, gpu.clears.items.len);
    try testing.expect(gpu.clears.items[gpu.clears.items.len - 1].scissor == null);
    try d.drawCells(&.{cell});
    try testing.expectEqual(clears + 1, gpu.clears.items.len);
    const tex_images = gpu.count(.gl_tex_image);
    try d.endFrame(&.{r}); // GL frame: no staging upload
    try testing.expectEqual(tex_images, gpu.count(.gl_tex_image));
    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.readEvents();

    // f3: staging frame; the GL frame's delta is unknown -> full present.
    _ = try d.beginFrame();
    try d.endFrame(&.{r});
    const up = gpu.uploads.items[gpu.uploads.items.len - 1];
    try testing.expect(!up.sub);
    try testing.expectEqual(@as(i32, 1920), up.w);
}

test "damage: sub-width rects upload tight rows, full-width rects in place" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    const r = Damage{ .x = 100, .y = 200, .w = 3, .h = 2 };
    try presentFrame(d, &drm, &.{});
    try presentFrame(d, &drm, &.{r});
    try presentFrame(d, &drm, &.{r});

    // f4: sub-width rect -> row-copied scratch upload.
    const f = try d.beginFrame();
    f.set(100, 200, 0xFF112233);
    f.set(102, 200, 0xFF445566);
    f.set(100, 201, 0xFF778899);
    f.set(102, 201, 0xFFAABBCC);
    try d.endFrame(&.{r});
    const up = gpu.uploads.items[gpu.uploads.items.len - 1];
    try testing.expect(up.sub);
    try testing.expectEqual(@as(u32, 0xFF112233), up.sample[0]);
    // Row 1 starts at (100,201), not at the next word of row 0.
    try testing.expectEqual(@as(u32, 0xFF778899), up.sample[1]);
    drm.queueFlipEvent(41, Drm3d.flip_cookie);
    try d.readEvents();

    // f5: full-width rect uploads in place; the aged sub-width rect replays.
    const r2 = Damage{ .x = 0, .y = 300, .w = 1920, .h = 2 };
    const f2 = try d.beginFrame();
    f2.set(0, 300, 0xFF010203);
    f2.set(0, 301, 0xFF040506);
    try d.endFrame(&.{r2});
    const ups = gpu.uploads.items[gpu.uploads.items.len - 2 ..];
    try testing.expectEqual(@as(i32, 0), ups[0].x); // r2 (current, full width)
    try testing.expectEqual(@as(u32, 0xFF010203), ups[0].sample[0]);
    try testing.expectEqual(@as(u32, 0xFF040506), ups[0].sample[1]);
    try testing.expectEqual(@as(i32, 100), ups[1].x); // r (replayed)
}

test "damage: unknown buffer age falls back to a full frame" {
    const a = testing.allocator;
    var drm: FakeDrm = .{ .allocator = a };
    defer drm.deinit();
    var gpu: FakeGpu = .{ .allocator = a };
    defer gpu.deinit();
    const d = try setupActive(a, &drm, &gpu);
    defer d.deinit();

    const r = Damage{ .x = 100, .y = 200, .w = 300, .h = 50 };
    try presentFrame(d, &drm, &.{});
    try presentFrame(d, &drm, &.{r});
    try presentFrame(d, &drm, &.{r});

    // f4 would be partial; a failing age query must present everything.
    gpu.fail_buffer_age = true;
    const tex_images = gpu.count(.gl_tex_image);
    _ = try d.beginFrame();
    try d.endFrame(&.{r});
    try testing.expectEqual(tex_images + 1, gpu.count(.gl_tex_image));
    try testing.expectEqual(@as(usize, 0), gpu.scissor_boxes.items.len);
}
