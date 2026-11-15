# Visual verification of the autohiding mouse pointer. Boots kmshaunt on tty1
# (bochs-drm -> software compositing path), injects absolute mouse motion via QMP,
# captures screenshots at: initial (hidden), after motion (visible), and after
# the idle timeout (autohidden). The screenshots are saved to the test output
# for visual inspection; the assertions keep the console responsive.
{
  pkgs,
  kmshauntModule ? import ../module.nix,
}:
let
  tlib = import ./lib.nix pkgs;
in
pkgs.testers.runNixOSTest {
  name = "kmshaunt-pointer-visual";
  enableOCR = true;
  # QMP input-send-event uses nested event structures that the driver's
  # `dict[str, str]` send() annotation and Optional qmp_client do not model.
  skipTypeCheck = true;
  skipLint = true;
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

    machine.wait_for_unit("default.target")
    machine.wait_until_succeeds("pgrep -u alice bash")
    machine.wait_for_text("alice@")
    # Give the console a prompt so the background is not empty.
    machine.send_chars("echo POINTERTEST\n")
    machine.wait_for_text("POINTERTEST")
    time.sleep(1.0)

    # The guest's relative PS/2 mouse is a VMware VMMouse, which QEMU drives in
    # absolute mode and which drops relative QMP events (no motion ever reached
    # libinput). Inject ABSOLUTE motion instead: it routes to the absolute
    # pointer (QEMU USB Tablet / VMMouse), libinput reports POINTER_MOTION_ABSOLUTE,
    # and kmshaunt transforms it to canvas pixels. QMP abs coords span 0..0x7fff;
    # (fx, fy) are fractions of the screen.
    def move_mouse(fx, fy):
        machine.qmp_client.send("input-send-event", {
            "events": [
                {"type": "abs", "data": {"axis": "x", "value": int(fx * 0x7fff)}},
                {"type": "abs", "data": {"axis": "y", "value": int(fy * 0x7fff)}},
            ]
        })

    with subtest("pointer hidden initially"):
        machine.screenshot("pointer-1-initial")

    with subtest("pointer visible after motion"):
        # Move well into the canvas so the arrow is clearly on screen.
        move_mouse(0.40, 0.35)
        time.sleep(0.2)
        move_mouse(0.42, 0.36)
        time.sleep(0.5)
        machine.screenshot("pointer-2-visible")

    with subtest("pointer autohides after idle"):
        # Default idle timeout is 4 s; wait past it with no input.
        time.sleep(6.0)
        machine.screenshot("pointer-3-autohidden")

    with subtest("pointer reappears on motion and console stays responsive"):
        move_mouse(0.30, 0.30)
        time.sleep(0.2)
        move_mouse(0.32, 0.31)
        time.sleep(0.1)
        time.sleep(0.5)
        machine.screenshot("pointer-4-reappeared")
        machine.send_chars("touch /tmp/pointerok\n")
        machine.wait_until_succeeds("test -e /tmp/pointerok", timeout=60)
  '';
}
