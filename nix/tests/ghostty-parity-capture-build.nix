# Build wrapper for ghostty-parity-capture.nix: supplies pkgs (with the kmshaunt
# harfbuzz overlay), the user's comic-code font, the parity frames, and the
# kmshaunt NixOS module + package. Kept out of the auto-generated flake.nix;
# build/eval it directly:
#
#   nix eval  --impure -f nix/tests/ghostty-parity-capture-build.nix drvPath   # eval check
#   nix build --impure --accept-flake-config -f nix/tests/ghostty-parity-capture-build.nix
#
# comic-code is extracted from the user's nixos-config flake-parts package module
# (sibling checkout) and rebuilt against THIS nixpkgs, so both VMs share one font.
let
  repoRoot = ../..;
  flake = builtins.getFlake (toString repoRoot);
  system = builtins.currentSystem;
  pkgs = import flake.inputs.nixpkgs {
    inherit system;
    overlays = [ (import (repoRoot + "/nix/overlay.nix")) ];
  };
  nixosConfig = repoRoot + "/../nixos-config";
  comicCode =
    ((import (nixosConfig + "/modules/packages/comic-code/default.nix") { }).perSystem {
      inherit pkgs;
    }).packages.comic-code;
  framesDir = repoRoot + "/fixtures/ghostty-parity/frames";
in
import ./ghostty-parity-capture.nix {
  inherit pkgs comicCode framesDir;
  kmshauntModule = {
    imports = [ (repoRoot + "/nix/module.nix") ];
    services.kmshaunt.package = flake.packages.${system}.kmshaunt.overrideAttrs {
      doCheck = false;
    };
  };
}