/* Translate-c shim for the GBM API (ROADMAP M5.1, module name `gbm-c`).
 *
 *     const gbm_c = b.addTranslateC(.{ .root_source_file = b.path("src/gbm-c.h"), ... });
 *     // include dirs from pkg-config "gbm" (mesa.dev)
 *     exe.root_module.addImport("gbm-c", gbm_c.createModule());
 *     exe.root_module.linkSystemLibrary("gbm", .{});
 *
 * Only the surface/bo entry points drm3d.zig uses are needed; gbm.h pulls in
 * the rest. The GBM device is created on the SAME primary DRM fd the backend
 * modesets on, so a locked bo's GEM handle feeds drmModeAddFB directly (no
 * PRIME import). See drm3d.zig header for the render-node/PRIME alternative.
 */
#include <gbm.h>
