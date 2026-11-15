# Regression: keyboard input must not be captured while kmshaunt's VT is
# inactive, AND input must still work after switching back. Reproduces the
# user report (kmshaunt + a compositor on another VT): switch away, type
# there, and the typed text must NOT appear in kmshaunt; switch back and
# typing must reach the shell again.
#
# Single-node, single-kmshaunt test. The module aliases autovt@ to
# kmshaunt-vt@, so switching to an *unused* VT would spawn a SECOND kmshaunt
# that contends for seat0/DRM master — not the user's scenario. To keep exactly
# one kmshaunt, tty2 is given a plain getty before switching: logind only
# spawns autovt@ttyN when that VT is not already busy (vt_is_busy), so the
# running getty suppresses the second instance. The leak and the
# input-after-return checks then exercise kmshaunt's own seat lifecycle.
#
# The input-after-return subtest is a marker-file check (independent of the
# render/DRM-master path). It regresses the resume path: suspend_ drops the
# VT-switch chord's modifier releases (Ctrl/Alt/Fn are released after the seat
# goes away), so without the resume_ xkb-modifier reset every key typed after
# the switch would carry stale Ctrl+Alt and never reach the shell.
#
# Run:
#   nix build --impure --expr \
#     'let f = builtins.getFlake (toString ./.); \
#          pkgs = import f.inputs.nixpkgs { system = builtins.currentSystem; }; \
#      in import ./nix/tests/vt-input-leak.nix { inherit pkgs; }'
#
# Observation is OCR on the tty1 screen: a distinctive marker typed on tty2 must
# be absent from tty1 after returning, while tty1's own content survives and
# input still works afterwards (so a dead console cannot pass by accident).
{
  pkgs,
  kmshauntModule ? import ../module.nix,
}:
let
  tlib = import ./lib.nix pkgs;
in
pkgs.testers.runNixOSTest {
  name = "kmshaunt-vt-input-leak";
  enableOCR = true;
  nodes.machine =
    { ... }:
    {
      imports = [
        tlib.deterministicVm
        kmshauntModule
      ];
      services.kmshaunt = {
        enable = true;
        config = tlib.consoleDefaults // {
          term = "xterm-ghostty";
          "dpms-timeout" = 0;
        };
      };
    };
  testScript = ''
    import time
    from pathlib import Path
    from test_driver.machine.ocr import perform_ocr_on_screenshot

    machine.wait_for_unit("default.target")
    machine.wait_until_succeeds("pgrep -u alice bash")
    machine.wait_for_text("alice@")

    with subtest("tty1 input works before switching"):
        machine.send_chars("echo TTY1BASE\n")
        machine.wait_for_text("TTY1BASE")

    with subtest("input typed on tty2 does not leak into tty1"):
        # Give tty2 a plain getty so logind does not spawn a second kmshaunt
        # (autovt@ is aliased to kmshaunt-vt@). A busy VT suppresses autovt,
        # keeping this the single-kmshaunt scenario the user actually runs.
        machine.succeed("systemctl start getty@tty2")
        machine.wait_until_succeeds("pgrep -f 'agetty.*tty2'")
        # Let agetty open /dev/tty2 so the VT is busy before we switch to it.
        time.sleep(0.5)
        machine.send_key("ctrl-alt-f2")
        machine.wait_until_succeeds("test $(cat /sys/class/tty/tty0/active) = tty2")
        # Let the seat deactivate / input suspend settle.
        time.sleep(1.0)
        # Exactly one kmshaunt: the getty on tty2 suppressed autovt@tty2.
        machine.succeed("test $(pgrep -c kmshaunt) -eq 1")
        # Distinctive, OCR-friendly marker typed while kmshaunt is inactive.
        machine.send_chars("LEAKZZQ\n")
        # Give any (buggy) delivery time to land in kmshaunt's pty.
        time.sleep(1.5)
        machine.send_key("ctrl-alt-f1")
        machine.wait_until_succeeds("test $(cat /sys/class/tty/tty0/active) = tty1")
        time.sleep(1.0)
        machine.screenshot("vt-leak-tty1")
        text = perform_ocr_on_screenshot(Path(machine.out_dir) / "vt-leak-tty1.png")
        assert "TTY1BASE" in text, f"tty1 lost its content: {text!r}"
        assert "LEAKZZQ" not in text, f"input leaked from tty2 into tty1: {text!r}"

    with subtest("input still works after returning"):
        # Test input DELIVERY directly via a marker file, independent of the
        # render/DRM-master path. Regresses the resume_ xkb-modifier reset:
        # without it the dropped Ctrl/Alt releases leave every key stuck with
        # stale modifiers, so this command never reaches the shell.
        machine.send_chars("touch /tmp/afterok\n")
        machine.wait_until_succeeds("test -e /tmp/afterok", timeout=60)
  '';
}
