# T2 headless render goldens (ROADMAP §4 T2, M3.10/M4.6, R6) as a nix check.
#
# Builds tools/render_golden.zig standalone -- the "Standalone build/test"
# recipe in that file's header, with build.zig's module wiring expressed as
# translate-c + build-exe CLI flags -- and runs `render_golden --check` for
# every fixtures/t2/*.bin against fixtures/t2/goldens/<stem>.png (byte-exact;
# exit 1 on any pixel diff). The kitty animation fixture is checked twice:
# root frame and --animation-ms 40 (frame 2).
#
#   nix build .#checks.<system>.t2-render-goldens   # runs the comparison
#   nix build .#render-golden                       # just the tool (for
#                                                   # `just update-goldens`)
#
# Why standalone and not `zig build`: build.zig does not install the golden
# tool (it is a test tool, never shipped), so this derivation reuses the
# normal `zig build` only to produce libghostty-vt-static.a (+ the bundled
# highway/simdutf archives) and then links the tool against it. The C shims
# are translated with the same headers and pkg-config include paths build.zig
# uses; the hyphen-spelled module aliases (freetype-c, harfbuzz-c) get byte
# copies of the underscore modules because the CLI, unlike addImport, needs
# one root file per module name.
#
# Determinism (R6): the pinned font directory is assembled from the flake's
# font packages (same bytes as fixtures/t2/fonts' symlinks) plus the two
# googlefonts/color-fonts fetches nix/package.nix already pins. Fonts,
# FreeType, HarfBuzz and fontconfig versions come from flake.lock; a bump
# that changes pixels fails this check, and `just update-goldens` re-blesses
# after reviewing the image diff.
#
# Unlike nix/package.nix's check phase this derivation is sandbox-safe: it
# runs no hermetic child processes, only the renderer (which writes its
# private fontconfig cache under /tmp).
{
  lib,
  stdenv,
  callPackage,
  zig_0_17,
  pkg-config,
  libdrm,
  libxkbcommon,
  libinput,
  systemd,
  fontconfig,
  freetype,
  harfbuzz,
  libspng,
  seatd,
  jetbrains-mono,
  noto-fonts-color-emoji,
  noto-fonts-cjk-sans,
  fetchurl,
}:
let
  # Same fetches (URL + hash) as nix/package.nix and modules/flake/devshell.nix.
  colrFont = fetchurl {
    url = "https://raw.githubusercontent.com/googlefonts/color-fonts/e830e042b0e93fd5b0197a7fe9f0398f6d87f467/fonts/noto-glyf_colr_1.ttf";
    hash = "sha256-/Bw7WB0B/K7TKDuaEqBPeE2woicQ4cGW37OlJpYGP9w=";
  };
  sbixFont = fetchurl {
    url = "https://raw.githubusercontent.com/googlefonts/color-fonts/e830e042b0e93fd5b0197a7fe9f0398f6d87f467/fonts/noto-sbix.ttf";
    hash = "sha256-/WjsX3XiRNuHmx86r0U2J+12RFM0Oi26qLF9qGQddbU=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "kmshaunt-render-golden";
  version = "0.0.1";

  src = lib.fileset.toSource {
    root = ../../.;
    fileset = lib.fileset.unions [
      ../../build.zig
      ../../build.zig.zon
      ../../src
      ../../tools
      ../../test_spng.zig
      # Fixtures + committed goldens; the fonts/ symlink dir is rebuilt from
      # the flake's packages below (its /tmp targets do not exist in the
      # sandbox). maybeMissing: the symlinks may be absent from the git tree.
      (lib.fileset.difference ../../fixtures (lib.fileset.maybeMissing ../../fixtures/t2/fonts))
    ];
  };

  deps = callPackage ../../deps.nix { };

  strictDeps = true;

  nativeBuildInputs = [
    zig_0_17
    pkg-config
  ];

  # Full set: `zig build` links the kmshaunt executable, which needs every
  # C library nix/package.nix lists.
  buildInputs = [
    libdrm
    libxkbcommon
    libinput
    systemd # libudev
    fontconfig
    freetype
    harfbuzz # overlaid withRaster
    libspng
    seatd
  ];

  postConfigure = ''
    mkdir -p zig-pkg
    cp -r ${finalAttrs.deps}/. zig-pkg/
    chmod -R u+w zig-pkg
  '';

  dontSetZigDefaultFlags = true;

  buildPhase = ''
    runHook preBuild

    # Normal build: produces libghostty-vt-static.a and the bundled
    # highway/simdutf archives the static library references.
    TERM=dumb zig build -j"$NIX_BUILD_CORES" -Dcpu=baseline -Doptimize=ReleaseFast

    # One archive per name in a fresh cache; refuse to guess if that changes.
    for lib in libghostty-vt-static.a libhighway.a libsimdutf.a; do
      count=$(find .zig-cache/o -name "$lib" | wc -l)
      if [ "$count" -ne 1 ]; then
        echo "expected exactly one $lib in .zig-cache/o, found $count" >&2
        exit 1
      fi
    done
    ghostty_dir=$(dirname "$(find .zig-cache/o -name libghostty-vt-static.a)")
    highway_dir=$(dirname "$(find .zig-cache/o -name libhighway.a)")
    simdutf_dir=$(dirname "$(find .zig-cache/o -name libsimdutf.a)")

    # C shims, same headers + pkg-config include paths as build.zig.
    mkdir -p gen
    ghostty_include=$(echo zig-pkg/ghostty-*/include)
    zig translate-c src/vt-c.h -I"$ghostty_include" -lc > gen/vt_c.zig
    zig translate-c src/fontconfig-c.h $(pkg-config --cflags-only-I fontconfig) -lc > gen/fontconfig_c.zig
    zig translate-c src/freetype-c.h $(pkg-config --cflags-only-I freetype2) -lc > gen/freetype_c.zig
    zig translate-c src/hb-c.h $(pkg-config --cflags-only-I harfbuzz freetype2) -lc > gen/hb_c.zig
    # CLI modules need distinct root files; build.zig shares one module under
    # both spellings, the copies are byte-identical.
    cp gen/freetype_c.zig gen/freetype_dash_c.zig
    cp gen/hb_c.zig gen/harfbuzz_dash_c.zig

    zig build-exe \
      --dep kmshaunt --dep png -Mroot=tools/render_golden.zig \
      --dep vt-c --dep fontconfig_c --dep freetype_c \
      --dep hb-c --dep freetype-c --dep harfbuzz-c \
      -Mkmshaunt=src/render_golden_exports.zig \
      -Mvt-c=gen/vt_c.zig \
      -Mfontconfig_c=gen/fontconfig_c.zig \
      -Mfreetype_c=gen/freetype_c.zig \
      -Mhb-c=gen/hb_c.zig \
      -Mfreetype-c=gen/freetype_dash_c.zig \
      -Mharfbuzz-c=gen/harfbuzz_dash_c.zig \
      -Mpng=tools/png.zig \
      -lc -lghostty-vt-static -lhighway -lsimdutf \
      -lfontconfig -lfreetype -lharfbuzz -lharfbuzz-raster \
      -L"$ghostty_dir" -L"$highway_dir" -L"$simdutf_dir" \
      $(pkg-config --libs-only-L fontconfig freetype2 harfbuzz harfbuzz-raster) \
      -Dcpu=baseline -Doptimize=ReleaseFast \
      -femit-bin=render_golden

    # Pinned font directory: the exact face set of fixtures/t2/fonts (four
    # static JetBrains Mono weights, one CBDT emoji face, one CJK face, the
    # COLRv1 and sbix color-font fixtures).
    mkdir -p fonts
    for weight in Regular Bold Italic BoldItalic; do
      ln -s ${jetbrains-mono}/share/fonts/truetype/JetBrainsMono-$weight.ttf fonts/
    done
    ln -s ${noto-fonts-color-emoji}/share/fonts/noto/NotoColorEmoji.ttf fonts/
    ln -s ${noto-fonts-cjk-sans}/share/fonts/opentype/noto-cjk/NotoSansCJK-VF.otf.ttc fonts/
    ln -s ${colrFont} fonts/noto-glyf_colr_1.ttf
    ln -s ${sbixFont} fonts/noto-sbix.ttf

    runHook postBuild
  '';

  doCheck = true;

  checkPhase = ''
    runHook preCheck

    for fixture in fixtures/t2/*.bin; do
      stem=$(basename "$fixture" .bin)
      ./render_golden --fixture "$fixture" --font-dir fonts \
        --check "fixtures/t2/goldens/$stem.png"
    done
    # Second golden from the animation fixture: frame 2, due at 40 ms.
    ./render_golden --fixture fixtures/t2/kitty-animation.bin --animation-ms 40 \
      --font-dir fonts --check fixtures/t2/goldens/kitty-animation-frame2.png

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 render_golden "$out/bin/render_golden"
    runHook postInstall
  '';

  meta = {
    description = "Headless T2 render-golden tool for kmshaunt (test tool, not the console)";
    homepage = "https://github.com/nilp0inter/kmshaunt";
    mainProgram = "render_golden";
    platforms = lib.platforms.linux;
  };
})
