{ ... }:
{
  perSystem = { pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      packages = [
        pkgs.zig_0_17
        pkgs.zon2nix
        pkgs.just
        # build.zig resolves the C shim include paths and the system-library
        # links through pkg-config (PKG_CONFIG_PATH is populated from the dev
        # outputs below by the pkg-config setup hook).
        pkgs.pkg-config
        # C libraries: dev outputs carry the headers + .pc files, the lib
        # outputs carry the shared objects zig links and rpaths. harfbuzz is
        # the overlaid withRaster build (nix/overlay.nix): hb-raster.h +
        # libharfbuzz-raster.
        pkgs.libdrm.dev
        pkgs.libdrm
        pkgs.libxkbcommon.dev
        pkgs.libxkbcommon
        pkgs.libinput.dev
        pkgs.libinput.out
        pkgs.systemd.dev # libudev + libsystemd
        pkgs.systemd
        pkgs.fontconfig.dev
        pkgs.fontconfig.lib
        pkgs.freetype.dev
        pkgs.freetype
        pkgs.harfbuzz.dev
        pkgs.harfbuzz
        pkgs.libspng.dev
        pkgs.libspng
        pkgs.seatd.dev # libseat
        pkgs.seatd.out
        # Test data for `zig build test` (see the shellHook exports).
        pkgs.xkeyboard_config
        pkgs.libx11
        pkgs.dejavu_fonts
        pkgs.noto-fonts-color-emoji
      ];

      shellHook =
        let
          # Color-font fixtures for src/font/color.zig (googlefonts/color-fonts,
          # the commit pinned in that file's header); same fetches as
          # nix/package.nix.
          colrFont = pkgs.fetchurl {
            url = "https://raw.githubusercontent.com/googlefonts/color-fonts/e830e042b0e93fd5b0197a7fe9f0398f6d87f467/fonts/noto-glyf_colr_1.ttf";
            hash = "sha256-/Bw7WB0B/K7TKDuaEqBPeE2woicQ4cGW37OlJpYGP9w=";
          };
          sbixFont = pkgs.fetchurl {
            url = "https://raw.githubusercontent.com/googlefonts/color-fonts/e830e042b0e93fd5b0197a7fe9f0398f6d87f467/fonts/noto-sbix.ttf";
            hash = "sha256-/WjsX3XiRNuHmx86r0U2J+12RFM0Oi26qLF9qGQddbU=";
          };
        in
        ''
          export XKB_CONFIG_ROOT=${pkgs.xkeyboard_config}/etc/X11/xkb
          export XLOCALEDIR=${pkgs.libx11}/share/X11/locale
          export KMSHAUNT_TEST_CBDT_FONT=${pkgs.noto-fonts-color-emoji}/share/fonts/noto/NotoColorEmoji.ttf
          export KMSHAUNT_TEST_COLR_FONT=${colrFont}
          export KMSHAUNT_TEST_SBIX_FONT=${sbixFont}
          export KMSHAUNT_TEST_TEXT_FONT=${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf
        '';
    };
  };
}
