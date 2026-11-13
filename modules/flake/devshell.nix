{ ... }:
{
  perSystem = { pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      packages = [
        pkgs.zig_0_17
        pkgs.zon2nix
        pkgs.just
      ];
    };
  };
}