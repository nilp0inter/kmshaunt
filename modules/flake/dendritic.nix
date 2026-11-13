{ inputs, lib, ... }:
{
  imports = [
    (inputs.flake-file.flakeModules.dendritic or { })
    (inputs.flake-file.flakeModules.allfollow or { })
  ];

  flake-file.inputs.flake-file.url = lib.mkDefault "github:denful/flake-file";
  # Use the fork — upstream spikespaz/allfollow stack-overflows on large
  # lock graphs and only substitutes 1 level deep; the fork fixes both.
  flake-file.inputs.allfollow.url = "github:nilp0inter/allfollow";

  flake-file.prune-lock.program =
    pkgs:
    pkgs.writeShellApplication {
      name = "allfollow";
      runtimeInputs = [ inputs.allfollow.packages.${pkgs.stdenv.hostPlatform.system}.default ];
      text = ''
        allfollow prune --pretty "$1" -o "$2"
      '';
    };
}