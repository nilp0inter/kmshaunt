# Sandbox-safe unit suite: the kmshaunt package built with `zig build test`
# running in the *default* Nix sandbox.
#
# The suite spawns real shell children, and the stock sandbox cannot serve
# them: /bin/sh there is the daemon's minimal busybox, whose `read -t 0.3`
# (fractional timeout, OSC52 test) returns 1 and whose `read -r -N`
# (mouse/SGR/paste tests) is unsupported; `stty` (pty resize tests) is on no
# FHS path inside the sandbox; and the only `ps` reachable there is busybox's,
# which cannot run `-o tty= -p $$` (pty controlling-tty test) and exits 1.
# This derivation therefore
#   - exports KMSHAUNT_TEST_SH, which src/misc/test_env.zig uses in place of
#     the hardcoded /bin/sh for every spawned test child, and
#   - adds bash, coreutils and procps to nativeBuildInputs: with strictDeps
#     they land on the build PATH, which the children inherit, and
#     test_env.zig searches that PATH first for the shell's tools (stty, ps).
#
# The font/xkb fixture environment (XKB_CONFIG_ROOT, XLOCALEDIR,
# KMSHAUNT_TEST_*_FONT, FONTCONFIG_FILE) is deliberately NOT re-declared here:
# nix/package.nix supplies it whenever doCheck is true, so this derivation and
# the package's own check switch compose in either merge order.
#
# Run with: nix build .#checks.x86_64-linux.kmshaunt-unit
#
# This is a second full build of the package — the lean `checks.package` runs
# no tests — which is the accepted cost of keeping the default package closure
# free of the test fixtures.
{
  lib,
  kmshaunt,
  bash,
  coreutils,
  procps,
}:
kmshaunt.overrideAttrs (old: {
  doCheck = true;
  nativeBuildInputs = old.nativeBuildInputs ++ [
    bash
    coreutils
    procps
  ];
  KMSHAUNT_TEST_SH = "${bash}/bin/bash";
})