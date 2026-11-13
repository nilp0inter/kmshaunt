# M6 exit scenarios (ROADMAP §5, M6.7) as a T4 parity test: one scenario body,
# run against services.kmscon and services.kmshaunt on identical guests.
#
# Wired into checks by modules/flake/packages.nix:
#
#   nix build .#checks.<system>.kmshaunt-m6-seats.driver  # lint/type-check only
#   nix build .#checks.<system>.kmshaunt-m6-seats         # boots both VMs
#
# Covered here (both run on the real VT, exactly like m1-login):
#   S1  localectl set-x11-keymap de swaps y and z live (org.freedesktop.locale1
#       follow, no console restart), and the swap goes both ways.
#   S2  a compose sequence produces the expected character: on the de layout
#       dead_acute (physical '=' key) + a -> á.
#
# NOT covered here, and why (ROADMAP M6 exit items 3 and 4):
#
#   S3 session grabs (grab-terminal-new / -session-next/-prev/-close). These
#   are gated by session-control, and the two implementations cannot currently
#   run them on a common guest configuration:
#     * kmscon force-disables session-control on real VTs (src/seat.c:786) and
#       only honours it on a libseat *fake* VT. But uterm_vt_libseat_new opens
#       a real VT whenever a VT name is passed (src/uterm/vt_libseat.c:535),
#       and the NixOS module hardcodes --vt=%I, so services.kmscon.config.libseat
#       alone still yields a real VT ("session control cannot be configured on
#       real VT, disabling session control" in the boot log). A fake VT needs
#       the unit's --vt removed.
#     * kmshaunt with libseat=true used to segfault during startup (the
#       initial enable_seat was delivered from setCallbacks, before the video
#       backend existed -> NULL-vtable deref at flipPending, offset 0x28).
#       Fixed by delivering the queued enable from activate() instead; see
#       src/seat/libseat.zig and the m6-libseat-startup regression test.
#       kmshaunt's libseat backend still opens no kernel VT, so session-control
#       is not force-disabled there, but main.zig does not yet clear
#       cfg.session_control on the real-VT (!libseat) path the way kmscon does.
#   Until a fake-VT unit is available to BOTH implementations (and kmshaunt
#   gates session-control on real VTs), there is no configuration where the
#   session grabs pass on BOTH nodes, so they are deferred rather than asserted
#   against a moving target.
#
#   Q1 second seat gets its own console. The input-routing recipe is verified
#   on paper in docs/spikes/q1-multiseat-input.md, but kmshaunt's multi-seat
#   daemon does not yet serve seats without VTs (src/main.zig runDaemon:
#   "needs a fake VT worker (M6); skipping"), so this cannot pass today either.
#
# Observation strategy
# --------------------
# Everything the shell under test types is verified through files it writes
# (read back over the driver backdoor, which is keymap-independent), never
# through OCR: after `localectl set-x11-keymap de` the driver's US-layout
# send_chars can no longer type arbitrary shell commands, so the scenario
# defines a one-key capture function while the layout is still us, and only
# sends layout-invariant keys afterwards.
#
# Scenario variables injected by nix/tests/lib.nix:
#   machine  the guest node object
#   impl     "kmscon" | "kmshaunt"
#   term     expected $TERM
#   unit     console unit
#   tty      "tty1"
{
  pkgs,
  kmshauntModule ? import ../module.nix,
}:
(import ./lib.nix pkgs).mkParityTest {
  name = "kmshaunt-m6-seats";
  inherit kmshauntModule;

  scenario =
    _ctx: ''
      import datetime as dt
      import time

      SHORT = dt.timedelta(seconds=10)

      # Capture the character(s) produced by a sequence of physical keys.
      # k() is defined in the autologin shell while the layout is still us;
      # it reads one character from the tty and writes it to /tmp/k. The
      # invocation "k\n" is layout-invariant (us and de agree on k/Return),
      # so it keeps working after the keymap swap. truncate/cat run over the
      # driver backdoor and are unaffected by the console keymap.
      def capture(keys):
          machine.succeed("truncate -s 0 /tmp/k")
          machine.send_chars("k\n")
          for key in keys:
              machine.send_key(key)
          machine.wait_until_succeeds("test -s /tmp/k", timeout=SHORT)
          return machine.succeed("cat /tmp/k").strip()

      # Wait until the console followed a localectl change: the physical y
      # key must produce `want`. Polling absorbs the asynchronous locale1
      # signal and any initial shell timing; no console restart happens.
      def wait_keymap(want):
          for _ in range(30):
              if capture(["y"]) == want:
                  return
              time.sleep(0.5)
          raise AssertionError(
              f"[{impl}] physical y still produces {capture(['y'])!r}, "
              f"expected {want!r} after localectl (no live keymap follow?)"
          )

      with subtest("S1 localectl set-x11-keymap de swaps y/z live"):
          waitForLogin(machine)
          # us baseline: define the capture helper, then prove physical y -> y.
          machine.send_chars('k() { read -r -n1 c; printf %s "$c" >/tmp/k; }\n')
          time.sleep(0.3)
          wait_keymap("y")

          # --no-convert: only the X11 keymap is under test; do not touch the
          # vconsole keymap (its /etc file is a read-only store symlink here).
          machine.succeed("localectl set-x11-keymap --no-convert de")
          machine.wait_until_succeeds(
              "localectl status | grep -q 'X11 Layout: de'", timeout=SHORT
          )
          wait_keymap("z")
          # The swap goes both ways: physical z is now y.
          got = capture(["z"])
          assert got == "y", f"[{impl}] de: physical z gave {got!r}, expected 'y'"

      with subtest("S2 compose: dead_acute + a -> á"):
          # Still the de layout: dead_acute sits on the physical '=' key
          # (xkeyboard-config symbols/de, key <AE12>). The compose table is
          # the locale one (en_US.UTF-8 via XLOCALEDIR, shipped by libX11
          # through libxkbcommon); both implementations pick it from
          # LC_ALL/LC_CTYPE/LANG. The dead key is swallowed, 'a' completes
          # the sequence, and the shell receives the single character á.
          got = capture(["equal", "a"])
          assert got == "á", f"[{impl}] compose gave {got!r}, expected 'á'"

          screenshotCompare(machine, impl, "S2-de-compose")
    '';
}