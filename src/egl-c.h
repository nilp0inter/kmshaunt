/* Translate-c shim for the EGL API (ROADMAP M5.1, module name `egl-c`).
 *
 *     const egl_c = b.addTranslateC(.{ .root_source_file = b.path("src/egl-c.h"), ... });
 *     // include dirs from pkg-config "egl" (mesa.dev)
 *     exe.root_module.addImport("egl-c", egl_c.createModule());
 *     exe.root_module.linkSystemLibrary("EGL", .{});
 *
 * eglext.h supplies eglCreateImageKHR / eglDestroyImageKHR and the
 * EGL_LINUX_DMA_BUF_EXT / EGL_LINUX_DRM_FOURCC_EXT tokens used to import a
 * GBM bo as an EGLImage. EGL_EGLEXT_PROTOTYPES makes translate-c emit the
 * extern prototypes rather than only the PFN typedefs.
 *
 * Headers come from libglvnd (EGL) on nixpkgs; link libEGL from libglvnd.
 */
#define EGL_EGLEXT_PROTOTYPES 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
