# kmshaunt, built offline against the pinned libghostty-vt 1.0.1.
#
# libghostty-vt is linked STATICALLY (build.zig links the dependency's
# "ghostty-vt-static" artifact, which bundles compiler-rt and the vendored
# simdutf/highway archives). $out/bin/kmshaunt is therefore standalone:
# no libghostty-vt.so.1 is needed at runtime and the package ships bin/
# only.
#
# This nixpkgs has no `zig.buildPackage`; the zig derivation provides a
# setup hook instead (zigConfigurePhase/zigBuildPhase/zigCheckPhase/
# zigInstallPhase), which is what nixpkgs' own zig packages use.
#
# Zig 0.17 keeps fetched packages in the project-local `zig-pkg/`
# directory. We pre-populate it from ../deps.nix (the libghostty-vt
# release dependency tarball plus libghostty-vt itself) so the sandbox
# build never needs the network. Real copies, not symlinks: Zig runs
# dependency build steps from inside the package directories and walks
# back out through `..`, which breaks on symlinked packages.
#
# The C libraries (libdrm, xkbcommon, libinput, libudev, fontconfig,
# freetype, harfbuzz, spng, seat, libgbm, libglvnd) are found through
# pkg-config: build.zig queries it for the translate-c include paths and
# linkSystemLibrary uses it for linking. harfbuzz comes from the flake pkgs
# with nix/overlay.nix applied (withRaster), so libharfbuzz-raster and
# hb-raster.h are present. libgbm (mesa) provides gbm.h/libgbm and libglvnd
# the EGL/GLES2 headers + libEGL/libGLESv2 for the drm3d backend.
{
  lib,
  stdenv,
  callPackage,
  zig_0_17,
  pkg-config,
  libdrm,
  libgbm,
  libglvnd,
  libxkbcommon,
  libinput,
  systemd,
  fontconfig,
  freetype,
  harfbuzz,
  libspng,
  seatd,
  xkeyboard_config,
  libx11,
  dejavu_fonts,
  noto-fonts-color-emoji,
  fetchurl,
  writeText,
}:
let
  # Color-font test fixtures for src/font/color.zig (googlefonts/color-fonts,
  # the commit pinned in that file's header). Not in nixpkgs; the CBDT and
  # text fixtures come from nixpkgs font packages below.
  colrFont = fetchurl {
    url = "https://raw.githubusercontent.com/googlefonts/color-fonts/e830e042b0e93fd5b0197a7fe9f0398f6d87f467/fonts/noto-glyf_colr_1.ttf";
    hash = "sha256-/Bw7WB0B/K7TKDuaEqBPeE2woicQ4cGW37OlJpYGP9w=";
  };
  sbixFont = fetchurl {
    url = "https://raw.githubusercontent.com/googlefonts/color-fonts/e830e042b0e93fd5b0197a7fe9f0398f6d87f467/fonts/noto-sbix.ttf";
    hash = "sha256-/WjsX3XiRNuHmx86r0U2J+12RFM0Oi26qLF9qGQddbU=";
  };
  # The sandbox has no /etc/fonts, so fontconfig cannot load its default
  # config there ("Cannot load default config file"). Point it at the
  # fontconfig package's own config (generic monospace aliases, LCD rules)
  # plus the test font directories; the writable cache comes from
  # XDG_CACHE_HOME set in preCheck.
  fontsConf = writeText "kmshaunt-fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <include ignore_missing="yes">${fontconfig.out}/etc/fonts/fonts.conf</include>
      <dir>${dejavu_fonts}/share/fonts</dir>
      <dir>${noto-fonts-color-emoji}/share/fonts</dir>
      <cachedir prefix="xdg">fontconfig</cachedir>
    </fontconfig>
  '';

  # Test-data environment for `zig build test` (zigCheckPhase). The xkb
  # defaults are also baked into nixpkgs' libxkbcommon, and fontconfig has
  # DejaVu as its built-in default font dir; these make the fixtures
  # explicit and pin the color-font paths the tests would otherwise look
  # for on the author's machine.
  #
  # Kept out of the derivation proper: every store path interpolated into
  # any attribute of a derivation becomes a build input, so these would
  # drag the color-font fixtures (nototools -> afdko -> tqdm -> dask ->
  # pyarrow -> arrow-cpp, plus imagemagick/librsvg/nodejs) into the runtime
  # closure of a build that never runs the tests.
  testEnv = {
    XKB_CONFIG_ROOT = "${xkeyboard_config}/etc/X11/xkb";
    XLOCALEDIR = "${libx11}/share/X11/locale";
    KMSHAUNT_TEST_CBDT_FONT = "${noto-fonts-color-emoji}/share/fonts/noto/NotoColorEmoji.ttf";
    KMSHAUNT_TEST_COLR_FONT = colrFont;
    KMSHAUNT_TEST_SBIX_FONT = sbixFont;
    KMSHAUNT_TEST_TEXT_FONT = "${dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf";
    FONTCONFIG_FILE = fontsConf;
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "kmshaunt";
  version = "0.0.1";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
      # Repository-root spng test harness (second artifact of `zig build
      # test`); it imports tools/png.zig, which cannot live under src/.
      ../test_spng.zig
      ../tools
    ];
  };

  deps = callPackage ../deps.nix { };

  strictDeps = true;

  nativeBuildInputs = [
    zig_0_17
    pkg-config
  ];

  buildInputs = [
    libdrm
    libgbm # gbm.h + libgbm (mesa), drm3d scanout buffers
    libglvnd # EGL/GLES2 headers + libEGL/libGLESv2, drm3d rendering
    libxkbcommon
    libinput
    systemd # libudev
    fontconfig
    freetype
    harfbuzz # overlaid withRaster: libharfbuzz-raster + hb-raster.h
    libspng
    seatd # libseat
  ];

  postConfigure = ''
    mkdir -p zig-pkg
    cp -r ${finalAttrs.deps}/. zig-pkg/
    chmod -R u+w zig-pkg
  '';

  dontSetZigDefaultFlags = true;
  zigBuildFlags = [
    "-Dcpu=baseline"
    "-Doptimize=ReleaseFast"
  ];

  # The default build runs no unit tests: it is what `nix flake check` and
  # downstream users build, so it must succeed in the standard sandbox.
  # The unit suite is opt-in with `overrideAttrs { doCheck = true; }`,
  # which also brings the fixture environment defined in `testEnv` above:
  # the same switch controls both. That env is merged value-wise with
  # `lib.mapAttrs`, never name-wise: mkDerivation evaluates the attribute
  # names before finalAttrs exists, so `lib.optionalAttrs finalAttrs.doCheck`
  # there is an infinite recursion. With doCheck = false the seven
  # attributes are present but empty, which carries no store context and so
  # adds no inputs to the closure.
  #
  # The suite itself still needs a host-like shell: `zig build test` spawns
  # hermetic children (src/misc/pty.zig, src/session/terminal.zig) that use
  # the bash builtins `read -t 0.3` and `read -r -N`, and `stty` from
  # coreutils. The default sandbox provides neither: /bin/sh is the minimal
  # busybox from the daemon's `sandbox-paths` setting, which rejects
  # fractional timeouts, and no coreutils is on PATH. Nix (2.34) has no
  # per-derivation override for the sandbox shell or /bin contents, so
  # until the sandbox-safe unit derivation lands the opt-in build needs the
  # override above plus one of:
  #   nix build --option sandbox false .#kmshaunt
  # or, keeping the sandbox, mount a full bash and stty (stty must be the
  # coreutils multicall binary: the bin/stty symlink loses its target when
  # bind-mounted):
  #   nix build --option sandbox-paths \
  #     "/bin/sh=$(nix eval --raw nixpkgs#bash.outPath)/bin/bash /bin/stty=$(nix eval --raw nixpkgs#coreutils.outPath)/bin/coreutils" \
  #     .#kmshaunt
  doCheck = false;

  preCheck = ''
    export XDG_CACHE_HOME="$TMPDIR/fontconfig-cache"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/kmshaunt" --version | grep -F 'kmshaunt 0.0.1'
    runHook postInstallCheck
  '';

  meta = {
    description = "Linux KMS/DRM console on top of libghostty-vt";
    homepage = "https://github.com/nilp0inter/kmshaunt";
    mainProgram = "kmshaunt";
    platforms = lib.platforms.linux;
  };
} // lib.mapAttrs (_: v: if finalAttrs.doCheck then v else "") testEnv)
