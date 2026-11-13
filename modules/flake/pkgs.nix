{ inputs, ... }:
{
  perSystem = { system, ... }: {
    # Apply the project overlay (harfbuzz with the raster library enabled,
    # see nix/overlay.nix) to the nixpkgs every perSystem module sees.
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      overlays = [ (import ../../nix/overlay.nix) ];
      config = { };
    };
  };
}