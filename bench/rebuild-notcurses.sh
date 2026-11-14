#!/usr/bin/env bash
# Rebuild patched notcurses 3.0.17 for the autoresearch benchmark.
#
# Bug: notcurses-demo src/demo/demo.c main() freed `results` before
# summary_json() read it (use-after-free) -> SIGSEGV at cleanup and a corrupt
# -J JSON. notcurses-demo-uaf.patch moves free(results) after summary_json().
#
# Run on tensor. Prints the patched notcurses store path; the demo binary is
# at <path>/bin/notcurses-demo and its data at <path>/share/notcurses. Point
# autoresearch-notcurses.sh's NC/DATA at that path after rebuilding.
#
# nixpkgs (flake registry) rev used: 02c087f3fe673c9e317f206a627cb6b910336dbe
set -euo pipefail
PATCH="$(cd "$(dirname "$0")" && pwd)/notcurses-demo-uaf.patch"
nix build --impure --no-link --print-out-paths --expr "
  let
    pkgs = (builtins.getFlake \"nixpkgs\").legacyPackages.x86_64-linux;
  in
    pkgs.notcurses.overrideAttrs (old: {
      patches = (old.patches or []) ++ [ $PATCH ];
    })
"