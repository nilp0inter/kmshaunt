{ ... }:
{
  # Follows are intentionally NOT declared here — `allfollow` is wired up
  # via `flake-file.flakeModules.allfollow` in dendritic.nix and runs as a
  # write-flake post-processor to dedup the lock graph. The two-pass
  # `just write-flake` recipe captures the collapsed follows into
  # modules/flake/auto-follows.nix so evaluation stays stable.
  flake-file.inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:denful/import-tree";
  };
}