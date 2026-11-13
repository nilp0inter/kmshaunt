# Interactive test VM (nix/test-vm.nix) and the ttytoys package it installs.
#
#   nix build .#ttytoys
#   nix build .#nixosConfigurations.test-vm.config.system.build.vm
#   QEMU_OPTS="-display none -vnc :1" ./result/bin/run-kmshaunt-test-vm
#
# The guest's nixpkgs carries the same harfbuzz overlay as the perSystem pkgs
# (nix/overlay.nix, ROADMAP D7/R1): kmshaunt links libharfbuzz-raster at
# runtime. qemu-vm.nix is imported explicitly because a flake
# nixosConfiguration does not get it automatically (nixos-rebuild build-vm
# does).
{ self, inputs, ... }:
let
  system = "x86_64-linux";

  # Same nixpkgs instantiation as modules/flake/pkgs.nix.
  pkgs = import inputs.nixpkgs {
    inherit system;
    overlays = [ (import ../../nix/overlay.nix) ];
    config = { };
  };

  ttytoys = pkgs.callPackage ../../nix/ttytoys.nix { };
in
{
  perSystem.packages.ttytoys = ttytoys;

  flake.nixosConfigurations.test-vm = inputs.nixpkgs.lib.nixosSystem {
    inherit pkgs;
    specialArgs = { inherit ttytoys; };
    modules = [
      "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
      ../../nix/test-vm.nix
      { services.kmshaunt.package = self.packages.${system}.kmshaunt; }
    ];
  };
}
