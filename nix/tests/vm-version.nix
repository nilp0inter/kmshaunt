# First VM test (ROADMAP M0.4): boot a minimal NixOS machine with kmshaunt
# installed and check that the binary runs and reports its version.
# Style follows nixos/tests/kmscon.nix.
{
  testers,
  kmshaunt,
}:
testers.runNixOSTest {
  name = "kmshaunt-version";

  nodes.machine =
    { pkgs, ... }:
    {
      environment.systemPackages = [ kmshaunt ];
    };

  testScript = ''
    machine.wait_for_unit("default.target")

    with subtest("kmshaunt reports its version"):
        version = machine.succeed("kmshaunt --version").strip()
        assert version == "kmshaunt 0.0.1", f"Unexpected version: {version!r}"
  '';
}