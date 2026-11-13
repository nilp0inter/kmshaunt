# "ttytoys" for the interactive test VM: the Rust crate terminal-toys by
# Seebass22, a collection of terminal screensavers (pipes3d, balls, life,
# sand, ...). Neither nixpkgs nor GitHub has a package/repo named "ttytoys";
# this crate is its stand-in (see modules/flake/test-vm.nix).
{
  lib,
  rustPlatform,
  fetchFromGitHub,
}:
rustPlatform.buildRustPackage rec {
  pname = "terminal-toys";
  version = "0.9.0";

  src = fetchFromGitHub {
    owner = "Seebass22";
    repo = "terminal-toys";
    rev = "v${version}";
    hash = "sha256-XFsgFjo6Bga32gR2FVXODJFw3zMdrqcq8AIijiQu+tE=";
  };

  cargoHash = "sha256-fIYGTduA1hE17bKhiS8IztFIuktmQSEAQ/o4wQKcuZY=";

  meta = {
    description = "Screensavers for your terminal (pipes3d, balls, life, sand, ...)";
    homepage = "https://github.com/Seebass22/terminal-toys";
    license = lib.licenses.mit;
    mainProgram = "terminal-toys";
  };
}
