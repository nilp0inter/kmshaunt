# Overlay applied to the flake's nixpkgs.
#
# harfbuzz: nixpkgs builds harfbuzz without the experimental libraries, so
# libharfbuzz-raster is missing. kmshaunt needs hb-raster (stable since
# HarfBuzz 13.0) to rasterize outlines and COLR paint graphs to BGRA for
# color emoji rendering (ROADMAP D7, R1). The nixpkgs expression already
# exposes a withRaster flag wired to meson's `raster` option; enabling it
# builds and installs libharfbuzz-raster alongside the core library.
final: prev: {
  harfbuzz = prev.harfbuzz.override { withRaster = true; };
}
