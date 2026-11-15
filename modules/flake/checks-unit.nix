# `zig build test` in the default sandbox. The stock package check cannot run
# there (busybox /bin/sh, no coreutils on PATH); nix/tests/unit.nix supplies
# bash + coreutils and points KMSHAUNT_TEST_SH at bash. Kept separate from
# `checks.package` so the default package closure stays free of test fixtures.
{ ... }:
{
  perSystem = { config, pkgs, ... }: {
    checks.kmshaunt-unit = pkgs.callPackage ../../nix/tests/unit.nix {
      kmshaunt = config.packages.kmshaunt;
    };
  };
}