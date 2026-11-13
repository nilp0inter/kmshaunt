# Exposes the kmshaunt NixOS module through `nixosModules` (ROADMAP M7.3).
#
# `nix/module.nix` is standalone — the T4 harness imports the file directly and
# supplies the package itself. Through the flake the package default is filled
# in here: `pkgs.kmshaunt` does not exist in nixpkgs, so the module's own
# default is only a pointer for the error message. The flake's build is used
# because it is the one built against the pinned libghostty-vt and the
# harfbuzz overlay (libharfbuzz-raster, ROADMAP D7/R1).
#
#   imports = [ inputs.kmshaunt.nixosModules.kmshaunt ];
#   services.kmshaunt.enable = true;
#
# mkDefault keeps `services.kmshaunt.package` overridable, e.g. to a build from
# the guest's own nixpkgs.
{ self, lib, ... }:
{
  flake.nixosModules.kmshaunt =
    { pkgs, ... }:
    {
      imports = [ ../../nix/module.nix ];

      services.kmshaunt.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.kmshaunt;
    };

  flake.nixosModules.default = self.nixosModules.kmshaunt;
}