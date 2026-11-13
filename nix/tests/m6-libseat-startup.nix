# M6.7 libseat startup regression (ROADMAP M6): services.kmshaunt with
# libseat=true must start cleanly.
#
# Before the fix, LibseatSeat.setCallbacks delivered the enable_seat that
# init's dispatch(0) drain had already observed, while main.zig was still in
# setupSeat (step 4, before setupVideo/setupSessions). The activated callback
# ran against Console.backend == undefined: on the ReleaseFast package's
# zero-filled arena pages that is a NULL vtable, and flipPending sits at
# vtable offset 0x28 -> "segfault at 28", kmshaunt-vt@tty1.service
# "Failed with result 'core-dump'" (docs/parity.md, nix/tests/m6-seats.nix).
# The fix delivers the queued initial enable from activate() (step 12), the
# same ordering VtReal provides; src/test_libseat_real.zig covers the C path
# hermetically, this scenario covers the whole service end to end.
#
# Run:
#   nix build .#checks.<system>.kmshaunt-m6-libseat-startup
#
# Single node, not a T4 parity test: kmscon's libseat mode is a different
# configuration (it still opens a real VT when --vt is passed, seat.c:780),
# and the regression under test is kmshaunt-specific.
{
  pkgs,
  kmshauntModule ? import ../module.nix,
}:
let
  inherit (import ./lib.nix pkgs) deterministicVm;
in
pkgs.testers.runNixOSTest {
  name = "kmshaunt-m6-libseat-startup";

  # machine.wait_for_text (OCR) proves the console actually draws.
  enableOCR = true;

  nodes.machine =
    { ... }:
    {
      imports = [
        deterministicVm
        kmshauntModule
      ];

      services.kmshaunt = {
        enable = true;
        config = {
          font-name = "JetBrains Mono";
          term = "xterm-ghostty";
          blink = false;
          # The regression configuration: seat via libseat (logind greeter
          # session through PAMName=kmshaunt), not the real-VT backend.
          libseat = true;
        };
      };
    };

  testScript = ''
    import datetime as dt

    LONG = dt.timedelta(seconds=120)

    machine.wait_for_unit("default.target")

    with subtest("console unit starts and stays up with libseat=true"):
        machine.wait_for_unit("kmshaunt-vt@tty1.service")
        machine.succeed("systemctl is-active kmshaunt-vt@tty1.service")
        # The M6.7 failure mode: segfault in setupSeat, unit core-dumps and
        # OnFailure hands the VT to getty@.
        machine.fail(
            "journalctl -u kmshaunt-vt@tty1.service --no-pager | grep -i segfault"
        )
        machine.fail(
            "journalctl -u kmshaunt-vt@tty1.service --no-pager | grep -i core-dump"
        )

    with subtest("the seat came from libseat/logind"):
        # PAMName=kmshaunt registers a greeter session; libseat's logind
        # backend opens the seat through it. Had open_seat failed, init
        # would have returned OpenSeatFailed and the unit would be down.
        machine.succeed("loginctl list-sessions --no-legend | grep -w greeter")

    with subtest("autologin shell runs on the libseat console"):
        machine.wait_until_succeeds("pgrep -u alice bash", timeout=LONG)
        machine.wait_for_text("alice@", timeout=LONG)
        machine.screenshot("libseat-startup")
  '';
}
