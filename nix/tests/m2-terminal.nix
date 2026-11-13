# M2 exit scenarios (ROADMAP §5, M2.6) as a T4 parity test: one scenario body,
# run against services.kmscon and services.kmshaunt on identical guests.
#
# Wired into checks by modules/flake/packages.nix:
#
#   nix build .#checks.<system>.kmshaunt-m2-terminal.driver  # lint/type-check only
#   nix build .#checks.<system>.kmshaunt-m2-terminal         # boots both VMs
#
# Covered (the ROADMAP M2 exit examples):
#   S1  /etc/issue text is visible by OCR (rendered before login).
#   S2  printf '\e[c' (DA) reply is captured by the shell.
#   S3  mouse select then middle-click pastes the text.
#   S4  Shift+PgUp shows earlier output (scrollback).
#   S5  a palette preset changes a rendered color (optional exit item).
#
# NOT covered: asciicast playback. It is being wired by a separate change and
# gets its own scenario once it lands; testing it here would assert against a
# moving target.
#
# Observation strategy
# --------------------
# Like m6-seats, everything the shell under test produces is asserted through
# files read back over the driver backdoor (keymap-independent); OCR is used
# only for what a user must literally see on the VT (issue text, scrollback).
#
# S1 keeps the harness autologin and OCRs the issue marker after the shell is
# up. Both consoles write /etc/issue to the terminal BEFORE starting the login
# child (kmshaunt src/main.zig showIssue, kmscon terminal_open ->
# kmscon_issue_write), and nothing clears it afterwards, so the marker on
# screen can only come from that pre-login issue display.
#
# Why not watch the login prompt and log in manually: the first revision of
# this test did exactly that (autologin off, type alice/foobar). It passes on
# kmscon, but on kmshaunt the Password: prompt appears and then login never
# reaches PAM after the password is typed (no pam_unix auth/session messages
# on the serial log, `pgrep -u alice bash` times out). Interactive password
# login is therefore a parity gap (m1-login only ever exercised autologin);
# it is reported, not fixed here, and S1 uses the feasible autologin subset so
# one login bug cannot mask the five terminal-behavior scenarios.
#
# S3 injects the pointer with QMP input-send-event through an added usb-mouse:
#   * The default usb-tablet is an ABSOLUTE device. kmscon scales its raw
#     evdev range to pixels, but kmshaunt's libinput absolute transform is
#     still open (docs/parity.md, "absolute-pointer transform (tablets)",
#     M5.7 note), so absolute events cannot pass on both nodes today.
#   * Relative events are pixel deltas in both stacks (kmscon reads raw
#     evdev REL_*; kmshaunt accumulates libinput motion deltas), so the
#     scenario uses a relative usb-mouse instead. QEMU routes REL events to
#     the only REL handler (the mouse). BTN events go to the first unbound
#     BTN handler, which is the mouse once the guest has polled it
#     (hid_pointer_activate); even if a button went to the tablet, both
#     stacks apply buttons at the last pointer position, and the tablet
#     emits no motion because its absolute position never changes.
#   * The choreography is acceleration-invariant: kmshaunt leaves libinput's
#     adaptive acceleration on while kmscon has none. A tiny first move lands
#     in cell (0,0) under any profile (small deltas are never amplified), and
#     the selection drag is oversized so it clamps at the right edge of row 0
#     in both implementations. The pasted line is captured by a raw-mode
#     `cat`, so the assertion reads a file, not the screen. No key is sent
#     between copy and paste: both implementations clear the selection on
#     any key event.
#
# S5 sets palette=solarized on both nodes. The two services do not share an
# option surface: services.kmscon exists on both nodes (nixpkgs module) but
# services.kmshaunt only exists where kmshauntModule is imported. So the
# kmscon preset goes in extraConfig (inert on the kmshaunt node, where
# services.kmscon is disabled) and the kmshaunt preset rides in the wrapped
# kmshauntModule below, which only the kmshaunt node imports. The preset value
# is identical. The assertion scans the screenshot for the solarized
# background RGB (7,54,66): with the default (legacy) palette the background
# is pure black, so a screenful of (7,54,66) proves the preset reached the
# renderer.
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
  name = "kmshaunt-m2-terminal";
  # Only the kmshaunt node imports this, so services.kmshaunt is in scope
  # here. Wrap the caller's module (the flake supplies the package) and add
  # the S5 preset; see the header for why it cannot live in extraConfig.
  kmshauntModule = {
    imports = [ kmshauntModule ];
    services.kmshaunt.config.palette = "solarized";
  };

  extraConfig =
    { ... }:
    {
      # S1: a known issue string (OCR-friendly). Both consoles display it
      # before the login child starts; the harness autologin stays on.
      environment.etc."issue".text = ''
        M2PARITY issue marker
      '';

      # S3: a relative pointer for QMP injection (see the header). The
      # default usb-tablet stays; it receives no events in this test.
      virtualisation.qemu.options = [ "-device" "usb-mouse" ];

      # S5 on the reference implementation. services.kmscon exists on both
      # nodes but is only enabled on the kmscon node, so this is inert on the
      # kmshaunt node (its preset comes from the wrapped kmshauntModule).
      services.kmscon.config.palette = "solarized";
    };

  scenario =
    _ctx: ''
      import datetime as dt
      import re
      import time

      SHORT = dt.timedelta(seconds=30)
      OCR_TIMEOUT = dt.timedelta(seconds=60)

      # S5 pixel probe, run with the harness's Pillow Python. Solarized
      # background (libtsm color_palette_solarized, slot 17); the legacy
      # default background is (0,0,0), so a screen that is mostly (7,54,66)
      # proves the preset was applied.
      PALETTE_PIXEL_CHECK = """
      import sys
      from PIL import Image
      im = Image.open(sys.argv[1]).convert("RGB")
      data = im.tobytes()
      want = bytes((7, 54, 66))
      n = sum(1 for i in range(0, len(data), 3) if data[i:i + 3] == want)
      total = im.width * im.height
      print(f"solarized background: {n}/{total} pixels")
      assert n * 10 > total, f"palette=solarized not applied: only {n}/{total} pixels are (7,54,66)"
      """

      with subtest("S1 /etc/issue visible by OCR (rendered before login)"):
          waitForLogin(machine)
          machine.wait_for_text("M2PARITY", timeout=OCR_TIMEOUT)
          screenshotCompare(machine, impl, "S1-issue")

      with subtest("S2 DA reply captured by the shell"):
          # Read the terminal's reply one byte at a time until the final 'c'.
          # read -n1 puts the tty in non-canonical mode per call; -echo keeps
          # the reply off the screen. The reply is asserted from the file.
          machine.send_chars(r"""da() { local ch out=; stty -echo; printf '\e[c'; while IFS= read -r -n1 -t 5 ch; do out+="$ch"; [ "$ch" = c ] && break; done; stty echo; printf %s "$out" > /tmp/da; }""" + "\n")
          machine.send_chars("da\n")
          machine.wait_until_succeeds("test -f /tmp/da", timeout=SHORT)
          reply = machine.succeed("cat /tmp/da")
          # A valid primary DA reply is CSI ? <params> c. kmscon answers
          # ?60;1;6;9;15, kmshaunt ?62;22;52; both are conforming, so the
          # assertion checks the shape, not one implementation's parameters.
          assert re.fullmatch(r"\x1b\[\?[0-9;]+c", reply), \
              f"[{impl}] DA reply {reply!r} is not CSI ? params c"

      with subtest("S3 mouse select then middle-click paste"):
          marker = "pastemark"
          machine.send_chars(f"clear; echo {marker}\n")
          machine.wait_for_text(marker, timeout=OCR_TIMEOUT)
          # Raw mode: the pasted bytes go straight into the file, with no
          # line editing or echo in the way.
          machine.send_chars("stty raw -echo; timeout 30 cat > /tmp/pasted\n")
          machine.wait_until_succeeds("pgrep -x cat", timeout=SHORT)

          def qmp_mouse(events):
              machine.qmp_client.send("input-send-event", {"events": events})
              time.sleep(0.2)

          def move(dx, dy):
              qmp_mouse([
                  {"type": "rel", "data": {"axis": "x", "value": dx}},
                  {"type": "rel", "data": {"axis": "y", "value": dy}},
              ])

          def button(name, down):
              qmp_mouse([{"type": "btn", "data": {"button": name, "down": down}}])

          # Both pointers start at (0,0); the marker is on row 0 after clear.
          # Tiny move: cell (0,0) under any acceleration profile.
          move(2, 3)
          button("left", True)
          # Oversized drag: clamps at the right edge of row 0 in both stacks.
          move(4000, 0)
          button("left", False)   # release copies the selection
          button("middle", True)  # middle press pastes it into cat
          button("middle", False)

          machine.wait_until_succeeds("test -s /tmp/pasted", timeout=SHORT)
          pasted = machine.succeed("cat /tmp/pasted")
          assert marker in pasted, f"[{impl}] pasted {pasted!r} lacks {marker!r}"
          machine.succeed("pkill -x cat || true")
          machine.send_chars("stty sane\n")
          screenshotCompare(machine, impl, "S3-paste")

      with subtest("S4 Shift+PgUp shows earlier output"):
          machine.send_chars("for i in $(seq -w 1 120); do echo scrollmark-$i; done\n")
          machine.wait_for_text("scrollmark-120", timeout=OCR_TIMEOUT)
          # 120 lines do not fit one screen. A page is one screen height in
          # both stacks (tsm_screen_sb_page_up / vt.pageUp), so five pages
          # reach the first line from any row count the pinned font produces.
          for _ in range(5):
              machine.send_key("shift-pgup")
          machine.wait_for_text("scrollmark-001", timeout=OCR_TIMEOUT)
          screenshotCompare(machine, impl, "S4-scrollback")
          for _ in range(5):
              machine.send_key("shift-pgdn")

      with subtest("S5 palette preset changes a rendered color"):
          screenshotCompare(machine, impl, "S5-palette")
          subprocess.run(
              [PILLOW_PYTHON, "-c", PALETTE_PIXEL_CHECK,
               f"{machine.out_dir}/{NAME}-{impl}-S5-palette.png"],
              check=True,
          )
    '';
}
