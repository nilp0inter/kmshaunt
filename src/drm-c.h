/* translate-c shim for src/video/drm2d.zig (module "drm-c").
 * libdrm.pc supplies both include directories: include/ (xf86drm.h,
 * xf86drmMode.h) and include/libdrm/ (drm.h, drm_mode.h, drm_fourcc.h). */
#include <xf86drm.h>
#include <xf86drmMode.h>
