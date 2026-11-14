{ inputs, ... }:
{
  perSystem = { config, pkgs, system, ... }: {
    packages = {
      kmshaunt = pkgs.callPackage ../../nix/package.nix { };
      default = config.packages.kmshaunt;

      # Re-export the allfollow CLI so `just write-flake` can invoke it
      # without re-fetching from github on every run.
      allfollow = inputs.allfollow.packages.${system}.default;

      # Headless T2 golden renderer (tools/render_golden.zig). The derivation
      # also runs the golden comparison in its check phase; building the
      # package alone gives `just update-goldens` its tool.
      render-golden = pkgs.callPackage ../../nix/tests/render-golden.nix { };
    };

    checks = {
      # Builds the console without the unit-test gate: nix/package.nix ships
      # doCheck = false so this passes in the default sandbox. The unit suite
      # is opt-in via `overrideAttrs { doCheck = true; }`.
      package = config.packages.kmshaunt;

      # M3.10/M4.6 exit gate (ROADMAP §4 T2, R6): every fixtures/t2 fixture
      # renders byte-exact against its committed golden with the flake-pinned
      # fonts and libraries. Fails on any pixel diff; re-bless with
      # `just update-goldens` after reviewing the image diff on a lock bump.
      t2-render-goldens = config.packages.render-golden;

      # M3.10/M4.6 exit gate (ROADMAP §4 T3): cat the same fixtures on the
      # real VT and compare QMP screendumps against the committed goldens.
      # kmshaunt-only (kitty graphics are its R2 extension, no kmscon
      # equivalent). Boots a VM, so it is slower than the T2 check.
      kmshaunt-render-golden-vm = pkgs.callPackage ../../nix/tests/render-golden-vm.nix {
        kmshauntModule = {
          imports = [ ../../nix/module.nix ];
          services.kmshaunt.package = config.packages.kmshaunt;
        };
      };

      vm-version = pkgs.callPackage ../../nix/tests/vm-version.nix {
        kmshaunt = config.packages.kmshaunt;
      };

      # M1.8 exit gate (ROADMAP M1, T3 exit + T4 parity): the first-login
      # scenarios run against both services.kmscon and services.kmshaunt.
      # The module needs the flake's own package: pkgs.kmshaunt is not in
      # nixpkgs.
      kmshaunt-m1-login = pkgs.callPackage ../../nix/tests/m1-login.nix {
        kmshauntModule = {
          imports = [ ../../nix/module.nix ];
          services.kmshaunt.package = config.packages.kmshaunt;
        };
      };

      # M6.7 exit gate (ROADMAP M6, T3 exit + T4 parity): live locale1 keymap
      # follow (localectl de swaps y/z) and compose (dead_acute+a -> á) run
      # against both services.kmscon and services.kmshaunt on the real VT.
      # Session grabs and the second seat are deferred; nix/tests/m6-seats.nix
      # documents the blockers.
      kmshaunt-m6-seats = pkgs.callPackage ../../nix/tests/m6-seats.nix {
        kmshauntModule = {
          imports = [ ../../nix/module.nix ];
          services.kmshaunt.package = config.packages.kmshaunt;
        };
      };

      # M6.7 libseat startup regression: services.kmshaunt with libseat=true
      # must start cleanly (setupSeat delivered the initial enable_seat from
      # setCallbacks, before the video backend existed -> NULL-vtable segfault
      # at flipPending, vtable offset 0x28). See nix/tests/m6-libseat-startup.nix.
      kmshaunt-m6-libseat-startup = pkgs.callPackage ../../nix/tests/m6-libseat-startup.nix {
        kmshauntModule = {
          imports = [ ../../nix/module.nix ];
          services.kmshaunt.package = config.packages.kmshaunt;
        };
      };

      # M2.6 exit gate (ROADMAP M2, T3+T4): terminal-behavior scenarios
      # (issue OCR, DA reply, mouse select+paste, scrollback, palette) on
      # both services.kmscon and services.kmshaunt.
      kmshaunt-m2-terminal = pkgs.callPackage ../../nix/tests/m2-terminal.nix {
        kmshauntModule = {
          imports = [ ../../nix/module.nix ];
          services.kmshaunt.package = config.packages.kmshaunt;
        };
      };

      # M5.8 exit gate (ROADMAP M5, T3+T4): backend boot (drm2d/drm3d/fbdev),
      # rotation, DPMS sysfs, two-card clone/scaled, on both implementations.
      kmshaunt-m5-video = pkgs.callPackage ../../nix/tests/m5-video.nix {
        kmshauntModule = {
          imports = [ ../../nix/module.nix ];
          services.kmshaunt.package = config.packages.kmshaunt;
        };
      };

      # M8.1/M8.3 (ROADMAP M8): vtebench throughput + peak RSS @10k scrollback,
      # one VM hosting both consoles. Benchmark, not a pass/fail parity gate.
      kmshaunt-m8-perf = pkgs.callPackage ../../nix/tests/m8-perf.nix {
        kmshauntModule = {
          imports = [ ../../nix/module.nix ];
          services.kmshaunt.package = config.packages.kmshaunt;
        };
      };

      # The overlay must produce the hb-raster library (ROADMAP D7, R1).
      harfbuzz-raster =
        pkgs.runCommand "harfbuzz-raster-check"
          {
            buildInputs = [ pkgs.harfbuzz ];
          }
          ''
            if ! ls ${pkgs.harfbuzz}/lib/libharfbuzz-raster* >/dev/null 2>&1; then
              echo "libharfbuzz-raster missing from ${pkgs.harfbuzz}/lib" >&2
              exit 1
            fi
            touch "$out"
          '';
    };
  };
}