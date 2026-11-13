# M6 exit scenarios (ROADMAP §5, M6.7) as a T4 parity test: one scenario body,
# run against services.kmscon and services.kmshaunt on identical guests.
#
# Wired into checks by modules/flake/packages.nix:
#
#   nix build .#checks.<system>.kmshaunt-m6-seats.driver  # lint/type-check only
#   nix build .#checks.<system>.kmshaunt-m6-seats         # boots both VMs
#
# Seat configuration: BOTH nodes run on the libseat / fake-VT path, not the
# real VT. That is the only configuration where session-control is honoured
# by both implementations:
#   * kmscon force-disables session-control on real VTs (src/seat.c:780,
#     uterm_vt_get_num > 0). With libseat=true AND no --vt, uterm_vt_allocate
#     builds vt_libseat without a tty name (src/uterm/vt.c:81-82,
#     vt_libseat.c:439-456): no kernel VT, get_num == 0, session-control
#     stays on. The nixpkgs module hardcodes --vt=%I, so extraConfig below
#     rebuilds the unit's ExecStart without it (same configdir/login recipe).
#   * kmshaunt with libseat=true opens no kernel VT either; setupSeat only
#     clears session_control on the real-VT (!libseat) path, mirroring
#     kmscon. The unit keeps --vt=%I (it selects runConsole, not the daemon).
# The real-VT path stays covered by m1-login / m2-terminal.
#
# Covered here:
#   S1  localectl set-x11-keymap de swaps y and z live (org.freedesktop.locale1
#       follow, no console restart), and the swap goes both ways.
#   S2  a compose sequence produces the expected character: on the de layout
#       dead_acute (physical '=' key) + a -> á.
#   S3  session grabs (grab-terminal-new / -session-next / -prev / -close,
#       default bindings Ctrl+Logo+Return/Right/Left/BackSpace, kmscon
#       config.c:928-938): create, cycle with wraparound, close, and the
#       last-session-never-closes rule. Observed through the shells: each
#       session tags itself (S=A / S=B) and only the active one receives
#       input, so `echo $S` identifies the focused session; process counts
#       prove creation/close.
#   S4  a second seat gets its own console (ROADMAP M6 exit item, Q1 spike
#       docs/spikes/q1-multiseat-input.md). The Q1 hardware (pci-bridge-seat
#       + secondary-vga + qemu-xhci + usb-kbd display=video.2) is present on
#       both nodes; systemd 71/73-seat.rules turn it into a second logind
#       seat. The seat-plumbing assertions run on both nodes. The console
#       assertions are kmshaunt-only: kmshaunt.service supervises the seats
#       and spawns a fake-VT worker (src/seat/vt_fake.zig) for the seat
#       without a kernel VT; kmscon has no supervising daemon (its model is
#       one instance per seat, started by a logind session ON that seat,
#       which a headless VM does not have), so the reference node asserts
#       the seat plumbing only.
#
# Observation strategy
# --------------------
# Everything the shell under test types is verified through files it writes
# (read back over the driver backdoor, which is keymap-independent), never
# through OCR: after `localectl set-x11-keymap de` the driver's US-layout
# send_chars can no longer type arbitrary shell commands, so the scenario
# defines a one-key capture function while the layout is still us, and only
# sends layout-invariant keys afterwards. S4's second display is observed
# with a QMP screendump of video.2 + OCR (the driver's screenshot only
# captures the primary display) and through marker files written by the
# seat1 shell in response to QMP input-send-event.
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

  extraConfig =
    {
      config,
      lib,
      options,
      pkgs,
      ...
    }:
    {
      config = {
      # Q1 second-seat hardware (docs/spikes/q1-multiseat-input.md §Recipe).
      # The bridge is auto-tagged by systemd 71/73-seat.rules; secondary-vga
      # (bochs-drm card1) is the seat master logind requires; the usb-kbd is
      # input-routed to video.2 so QMP input-send-event can address it.
      # Harmless on the kmscon node (nothing serves the second seat there).
      virtualisation.qemu.options = [
        "-device pci-bridge-seat,chassis_nr=2,id=seat.2"
        "-device secondary-vga,bus=seat.2,addr=02.0,id=video.2"
        "-device qemu-xhci,bus=seat.2,addr=0f.0,id=usb.2"
        "-device usb-kbd,bus=usb.2.0,port=1,id=kbd2,display=video.2"
      ];

      # session-control + libseat on the reference node. gpus=primary keeps
      # both consoles on card0 while the second GPU exists (S4 serves card1
      # separately); without it the default gpus=all would modeset card1 too.
      services.kmscon.config = {
        libseat = true;
        session-control = true;
        gpus = "primary";
      };

      # kmscon fake VT: the nixpkgs module hardcodes --vt=%I, which makes
      # uterm_vt_libseat_new open a real VT (vt_libseat.c:439) and kmscon
      # then force-disables session-control (seat.c:780). Rebuild ExecStart
      # with the module's own configdir/login recipe minus --vt=%I.
      systemd.services."kmsconvt@" = lib.mkIf config.services.kmscon.enable {
        serviceConfig.ExecStart =
          let
            mkKeyValue =
              k: v: if lib.isBool v then (lib.optionalString (!v) "no-") + k else "${k}=${toString v}";
            configDir = pkgs.writeTextFile {
              name = "kmscon-config-fakevt";
              destination = "/kmscon.conf";
              text = lib.generators.toKeyValue { inherit mkKeyValue; } (
                lib.filterAttrs (_: v: v != null) config.services.kmscon.config
              );
            };
            gettyCfg = config.services.getty;
            loginCmd =
              enableAutologin:
              "${gettyCfg.loginProgram} -p${lib.optionalString enableAutologin " -f -- ${gettyCfg.autologinUser}"}";
            loginScript = pkgs.writers.writeBash "kmscon-login-fakevt" (
              lib.optionalString (gettyCfg.autologinUser != null && gettyCfg.autologinOnce) ''
                kms_tty=
                active_tty_file=/sys/class/tty/tty0/active
                if [ -f "$active_tty_file" ]; then
                  read -r kms_tty < "$active_tty_file"
                fi
                autologged="/run/kmscon.autologged"
                if [ "$kms_tty" = tty1 ] && [ ! -f "$autologged" ]; then
                  touch "$autologged"
                  exec ${loginCmd true}
                fi
              ''
              + "exec ${loginCmd (gettyCfg.autologinUser != null && !gettyCfg.autologinOnce)}"
            );
          in
          lib.mkForce [
            ""
            "${lib.getExe config.services.kmscon.package} --configdir ${configDir} --no-switchvt --login -- ${loginScript}"
          ];
      };
    }
    // lib.optionalAttrs (options.services ? kmshaunt) {
      # Same seat configuration on the kmshaunt node. The unit keeps
      # --vt=%I: cfg.vt != null selects runConsole with the libseat backend
      # (no kernel VT), where session-control stays enabled.
      services.kmshaunt.config = {
        libseat = true;
        session-control = true;
        gpus = "primary";
      };
      };
    };

  scenario =
    _ctx: ''
      import datetime as dt
      import time
      import shlex
      from pathlib import Path

      SHORT = dt.timedelta(seconds=30)
      LONG = dt.timedelta(seconds=120)

      # The capture helper, defined once and reused: typed into the us-layout
      # shell for S1, and installed into ~/.bash_profile for the de-layout
      # shell that S2's console restart produces (send_chars is US-mapped, so
      # it cannot type the definition once the layout is de).
      KFUNC = 'k() { read -r -n1 c; printf %s "$c" >/tmp/k; }'

      # Capture the character(s) produced by a sequence of physical keys.
      # KFUNC reads one character from the tty and writes it to /tmp/k. The
      # invocation "k\n" is layout-invariant (us and de agree on k/Return),
      # so it keeps working after the keymap swap. rm/cat run over the driver
      # backdoor and are unaffected by the console keymap.
      def capture(keys):
          # Remove, don't truncate: the backdoor runs as root, so creating or
          # truncating /tmp/k here would leave it root-owned and the alice
          # shell's `> /tmp/k` would fail with EACCES. Removing it lets the
          # shell recreate it as alice on every capture.
          machine.succeed("rm -f /tmp/k")
          machine.send_chars("k\n")
          # Let `read -r -n1` switch the tty to non-canonical mode before the
          # first key lands, so the key is not left buffered in canonical mode
          # waiting for an Enter that never comes.
          time.sleep(0.5)
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
          machine.send_chars(KFUNC + "\n")
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
          # dead_acute sits on the physical '=' key of the de layout
          # (xkeyboard-config symbols/de, key <AE12>); dead_acute + a composes
          # to á via the locale compose table (en_US.UTF-8, picked from
          # LC_ALL/LC_CTYPE/LANG). The dead key is swallowed and the shell
          # receives the single character á.
          #
          # Genuine parity difference in HOW compose survives the S1 keymap
          # change:
          #   * kmshaunt keeps the compose table attached across the live
          #     reload (xkb.State.reload), so it composes directly on the de
          #     layout S1 left behind.
          #   * kmscon DROPS compose on a live keymap reload:
          #     kmscon_seat_update_xkb_layout -> input_update_keymap destroys
          #     the compose table and re-creates the keyboard devices BEFORE
          #     input_set_compose restores the table, leaving the devices with
          #     a NULL compose_state (kmscon src/input/input.c + input_uxkb.c).
          #     It composes again only after the console re-initializes and
          #     reads the de layout back from locale1 at startup.
          # Each node is asserted via the mechanism it supports; the divergence
          # is a kmscon reference bug, not a kmshaunt regression. (A uniform
          # restart is not possible: kmshaunt does not apply locale1's current
          # layout at startup, so it would come back up on us.)
          if impl == "kmshaunt":
              got = capture(["equal", "a"])
              assert got == "á", f"[{impl}] compose gave {got!r}, expected 'á'"
          else:
              # kmscon: restart so the de keymap (still set in locale1) comes
              # up WITH compose. The new shell is already on de, so install
              # KFUNC through ~/.bash_profile (sourced by the autologin login
              # shell) instead of typing it, which send_chars cannot do on de.
              machine.succeed(
                  "printf '%s\\n' " + shlex.quote(KFUNC)
                  + " >> /home/alice/.bash_profile && chown alice /home/alice/.bash_profile"
              )
              machine.succeed(f"systemctl restart {unit}")
              waitForLogin(machine)
              got = capture(["equal", "a"])
              assert got == "á", f"[{impl}] compose gave {got!r}, expected 'á'"

          screenshotCompare(machine, impl, "S2-de-compose")

      with subtest("S3 session grabs: create, cycle, close (session-control)"):
          # Both nodes run session-control on the libseat/fake-VT path (see
          # the file header). Default bindings, identical in both
          # implementations (kmscon config.c:928-938, kmshaunt
          # config/grab.zig defaults):
          #   terminal-new  Ctrl+Logo+Return
          #   session-next  Ctrl+Logo+Right
          #   session-prev  Ctrl+Logo+Left
          #   session-close Ctrl+Logo+BackSpace
          # HMP sendkey spells the Logo key "meta_l".
          # S1/S2 left the de layout behind. The driver's send_chars is
          # US-mapped, so restore us before typing shell commands again
          # (the console follows locale1 live; no restart). wait_keymap
          # proves the follow completed and the capture helper still works.
          machine.succeed("localectl set-x11-keymap --no-convert us")
          machine.wait_until_succeeds(
              "localectl status | grep -q 'X11 Layout: us'", timeout=SHORT
          )
          wait_keymap("y")
          waitForLogin(machine)
          # Tag the initial session's shell so sessions can be told apart.
          machine.send_chars("S=A\n")
          time.sleep(0.3)

          def active_tag():
              # Only the focused session receives input, so `echo $S`
              # reports which session is active. Remove, don't truncate
              # (root-owned file would block alice's redirect, as in S1).
              machine.succeed("rm -f /tmp/active")
              machine.send_chars("echo $S > /tmp/active\n")
              machine.wait_until_succeeds("test -s /tmp/active", timeout=SHORT)
              return machine.succeed("cat /tmp/active").strip()

          def bash_count():
              return int(machine.succeed("pgrep -u alice bash | wc -l").strip())

          def grab(key):
              machine.send_key(key)
              # Let the console process the grab (switch focus) before the
              # next input is routed to the newly-active session.
              time.sleep(0.3)

          got = active_tag()
          assert got == "A", f"[{impl}] initial session not active: {got!r}"

          # grab-terminal-new: a second session is created and becomes
          # active (kmscon seat.c:1113-1117: insert next to current, switch).
          grab("ctrl-meta_l-ret")
          machine.wait_until_succeeds(
              "test $(pgrep -u alice bash | wc -l) -ge 2", timeout=LONG
          )
          machine.send_chars("S=B\n")
          time.sleep(0.3)
          got = active_tag()
          assert got == "B", f"[{impl}] new session not active: {got!r}"

          # grab-session-prev / -next cycle with wraparound; cycling never
          # stops a session (both shells stay alive).
          grab("ctrl-meta_l-left")
          got = active_tag()
          assert got == "A", f"[{impl}] session-prev gave {got!r}, expected 'A'"
          grab("ctrl-meta_l-right")
          got = active_tag()
          assert got == "B", f"[{impl}] session-next gave {got!r}, expected 'B'"
          grab("ctrl-meta_l-right")  # wrap around
          got = active_tag()
          assert got == "A", f"[{impl}] session-next wrap gave {got!r}, expected 'A'"
          assert bash_count() == 2, f"[{impl}] cycling changed the session count"

          # grab-session-close: the active session is stopped and destroyed,
          # focus moves to the next neighbor (kmscon seat.c:1125-1146).
          grab("ctrl-meta_l-right")  # back to B
          grab("ctrl-meta_l-backspace")
          machine.wait_until_succeeds(
              "test $(pgrep -u alice bash | wc -l) -eq 1", timeout=SHORT
          )
          got = active_tag()
          assert got == "A", f"[{impl}] after close gave {got!r}, expected 'A'"

          # The LAST session is never closed through the grab (kmscon
          # seat.c:552-556 requires session_count >= 2).
          grab("ctrl-meta_l-backspace")
          time.sleep(1.0)
          assert bash_count() == 1, f"[{impl}] close grab killed the last session"
          got = active_tag()
          assert got == "A", f"[{impl}] last session lost focus: {got!r}"

      with subtest("S4 second seat gets its own console (Q1 recipe)"):
          # Implementation-independent seat plumbing: the pci-bridge-seat
          # subtree becomes a second logind seat owning the second GPU and
          # the second keyboard (systemd 71/73-seat.rules; Q1 spike L5).
          machine.wait_until_succeeds(
              "loginctl list-seats --no-legend | grep -qE '^seat-'", timeout=LONG
          )
          seat1 = machine.succeed(
              "loginctl list-seats --no-legend | awk '{print $1}' "
              "| grep -v '^seat0$' | head -1"
          ).strip()
          machine.succeed(f"loginctl seat-status {seat1} | grep -q 'QEMU USB Keyboard'")
          machine.succeed(f"loginctl seat-status {seat1} | grep -q 'drm/card1'")

          if impl == "kmshaunt":
              # seat0 keeps its pinned-VT console (kmshaunt-vt@tty1), which
              # already holds DRM master of card0. The daemon adds a console
              # for the SECOND seat: a fake-VT worker (src/seat/vt_fake.zig)
              # because that seat has no kernel VT. The worker opens all
              # cards; card0's master is held by the tty1 console, so openCard
              # skips it and card1 comes up. Keeping tty1 up makes card0
              # contention deterministic (no seat0/seat1 startup race). The
              # workers need the main.zig wiring from
              # local://m6-second-seat-wiring.md (KMSHAUNT_SEAT dispatch,
              # FakeVt setupSeat, per-seat config, seat-filtered input,
              # runDaemon spawn + initial enumeration).
              from test_driver.machine.ocr import perform_ocr_on_screenshot

              def unit_line(unit_name, prefix):
                  text = machine.succeed(f"systemctl cat {unit_name}")
                  lines = [l for l in text.splitlines() if l.startswith(prefix)]
                  assert lines, f"no {prefix} in {unit_name}"
                  return lines[-1][len(prefix):].strip()

              vt_cmd = unit_line("kmshaunt-vt@tty1.service", "ExecStart=")
              login_script = vt_cmd.split(" -- ")[-1].strip()
              xkb_env = unit_line("kmshaunt-vt@tty1.service", "Environment=")
              kmshaunt_bin = unit_line("kmshaunt.service", "ExecStart=").split()[0]
              # Sane PATH for the daemon (workers inherit it). The spawn
              # itself uses worker_exe=/proc/self/exe, so it needs no PATH.
              kmshaunt_dir = kmshaunt_bin.rsplit("/", 1)[0]

              # Runtime configdir shared by the daemon and its workers.
              # seat0 keeps the tty1 console (card0 master already held);
              # seat0.seat.conf also pins the daemon's seat0 worker to the
              # primary GPU. The seat1 fake worker opens all cards, finds
              # card0 busy, and takes card1.
              machine.succeed("mkdir -p /run/kmshaunt-daemon")
              machine.succeed(f"""cat > /run/kmshaunt-daemon/kmshaunt.conf <<'EOF'
      libseat
      no-blink
      font-name=JetBrains Mono
      login={login_script}
      EOF""")
              machine.succeed(
                  "printf 'gpus=primary\\n' > /run/kmshaunt-daemon/seat0.seat.conf"
              )
              machine.succeed("mkdir -p /run/systemd/system/kmshaunt.service.d")
              machine.succeed(f"""cat > /run/systemd/system/kmshaunt.service.d/override.conf <<'EOF'
      [Service]
      ExecStart=
      ExecStart={kmshaunt_bin} --configdir /run/kmshaunt-daemon --verbose
      Environment={xkb_env} PATH={kmshaunt_dir}:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin
      EOF""")
              machine.succeed("systemctl daemon-reload")
              machine.succeed("systemctl start kmshaunt.service")
              machine.wait_until_succeeds(
                  "systemctl is-active kmshaunt.service", timeout=SHORT
              )

              # The daemon saw the second seat and spawned its fake-VT
              # worker (the M6.7 skip is gone).
              machine.wait_until_succeeds(
                  "journalctl -u kmshaunt.service --no-pager "
                  f"| grep -q 'spawned fake-VT worker for {seat1}'",
                  timeout=LONG,
              )

              # Worker identity: KMSHAUNT_SEAT=<seat1> in its environment
              # (the daemon -> worker contract, src/seat/multiseat.zig).
              def worker_pid(seat):
                  # The worker is exec'd via /proc/self/exe, so its comm is
                  # not "kmshaunt" (pgrep -x misses it); find it by the
                  # KMSHAUNT_SEAT entry in its environment instead.
                  out = machine.succeed(
                      "for p in /proc/[0-9]*/environ; do "
                      f"if tr '\\0' '\\n' < \"$p\" 2>/dev/null | grep -Fxq 'KMSHAUNT_SEAT={seat}'; "
                      "then echo \"$p\" | cut -d/ -f3; break; fi; done"
                  ).strip()
                  return out or None

              pid = None
              for _ in range(60):
                  pid = worker_pid(seat1)
                  if pid is not None:
                      break
                  time.sleep(1)
              if pid is None:
                  print("=== kmshaunt daemon journal (worker startup) ===")
                  print(machine.succeed("journalctl -u kmshaunt.service --no-pager | tail -80"))
                  print("=== kmshaunt processes ===")
                  print(machine.succeed("ps aux | grep kmshaunt | grep -v grep || true"))
              assert pid is not None, f"[{impl}] no fake-VT worker process for {seat1}"

              # The worker owns the second GPU and modeset it.
              machine.wait_until_succeeds(
                  f"ls -l /proc/{pid}/fd 2>/dev/null | grep -q '/dev/dri/card1'",
                  timeout=LONG,
              )
              machine.wait_until_succeeds(
                  "cat /sys/class/drm/card1-*/enabled | grep -qx enabled",
                  timeout=LONG,
              )
              # Both seats' shells are up (tty1 console + seat1 fake worker).
              machine.wait_until_succeeds(
                  "test $(pgrep -u alice bash | wc -l) -ge 2", timeout=LONG
              )

              # The second display actually draws: QMP screendump of video.2
              # (the driver's screenshot only captures the primary display)
              # + OCR for the autologin prompt.
              def seat2_screen_text():
                  dump = f"{machine.out_dir}/m6-seat2.ppm"
                  machine.qmp_client.send(
                      "screendump", {"filename": dump, "device": "video.2"}
                  )
                  return perform_ocr_on_screenshot(Path(dump))

              text = ""
              for _ in range(60):
                  text = seat2_screen_text()
                  if "alice@" in text:
                      break
                  time.sleep(1)
              assert "alice@" in text, (
                  f"[{impl}] seat2 console never drew a shell prompt: {text!r}"
              )

              # Input routing (Q1 spike §2): QMP input-send-event addressed
              # to video.2 reaches ONLY the seat1 keyboard. Marker files
              # written by the shells prove the isolation both ways.
              def qmp_key(device, key, down):
                  machine.qmp_client.send("input-send-event", {
                      "device": device,
                      "events": [{
                          "type": "key",
                          "data": {"down": down, "key": {"type": "qcode", "data": key}},
                      }],
                  })

              def qmp_tap(device, key, delay=0.05):
                  qmp_key(device, key, True)
                  time.sleep(delay)
                  qmp_key(device, key, False)

              def qmp_type(device, text):
                  for ch in text:
                      # QMP wants QKeyCode names, not raw punctuation
                      # (Q1 spike §Recipe): '/' -> slash, '-' -> minus, ...
                      key = {
                          "\n": "ret", " ": "spc", "/": "slash", "-": "minus",
                          ".": "dot", ",": "comma", ";": "semicolon", "=": "equal",
                          "'": "apostrophe", "\\": "backslash",
                      }.get(ch, ch)
                      if ch.isupper():
                          qmp_key(device, "shift", True)
                          qmp_tap(device, key.lower())
                          qmp_key(device, "shift", False)
                      else:
                          qmp_tap(device, key)

              machine.succeed("rm -f /tmp/seat0-marker /tmp/seat2-marker")
              # HMP sendkey has no device argument: it lands on the unbound
              # virtio keyboard (seat0), never on the routed seat1 keyboard.
              machine.send_chars("touch /tmp/seat0-marker\n")
              machine.wait_until_succeeds("test -e /tmp/seat0-marker", timeout=SHORT)
              time.sleep(1.0)
              machine.fail("test -e /tmp/seat2-marker")
              # QMP keys addressed to video.2 reach the seat1 shell only.
              qmp_type("video.2", "touch /tmp/seat2-marker\n")
              machine.wait_until_succeeds("test -e /tmp/seat2-marker", timeout=SHORT)
          # kmscon node: the seat-plumbing assertions above are the whole
          # subtest. kmscon has no supervising daemon; serving seat1 needs a
          # logind session on that seat (its seat name comes from libseat,
          # reference G20), which the headless VM does not provide. The
          # second-seat console is asserted on the kmshaunt daemon.
    '';
}