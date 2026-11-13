{ inputs, ... }:
{
  perSystem = { config, pkgs, system, ... }: {
    packages = {
      kmshaunt = pkgs.callPackage ../../nix/package.nix { };
      default = config.packages.kmshaunt;

      # Re-export the allfollow CLI so `just write-flake` can invoke it
      # without re-fetching from github on every run.
      allfollow = inputs.allfollow.packages.${system}.default;
    };

    checks = {
      package = config.packages.kmshaunt;

      vm-version = pkgs.callPackage ../../nix/tests/vm-version.nix {
        kmshaunt = config.packages.kmshaunt;
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