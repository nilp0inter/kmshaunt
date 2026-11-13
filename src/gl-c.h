/* Translate-c shim for the GLES2 API (ROADMAP M5.1, module name `gl-c`).
 *
 *     const gl_c = b.addTranslateC(.{ .root_source_file = b.path("src/gl-c.h"), ... });
 *     // include dirs from pkg-config "glesv2" (mesa.dev)
 *     exe.root_module.addImport("gl-c", gl_c.createModule());
 *     exe.root_module.linkSystemLibrary("GLESv2", .{});
 *
 * gl2ext.h declares the PFNGLEGLIMAGETARGETTEXTURE2DOESPROC typedef for
 * glEGLImageTargetTexture2DOES (GL_OES_EGL_image), which binds an imported
 * EGLImage to a GL texture. libglvnd does not export that symbol directly, so
 * drm3d resolves it at runtime via eglGetProcAddress. GL_GLEXT_PROTOTYPES also
 * emits the extern prototype (unused; kept for completeness).
 *
 * Headers come from libglvnd (EGL/GLES2) on nixpkgs; gbm.h from libgbm.
 */
#define GL_GLEXT_PROTOTYPES 1
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
