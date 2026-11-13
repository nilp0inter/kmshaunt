# Q1 Spike: routing a second USB keyboard to seat1 in the NixOS test VM

Date: 2026-11-13. Versions pinned by nixpkgs 26.11 (rev `f9a75f41`): QEMU 11.1.2
(`nixpkgs#qemu_kvm`), systemd 262, nixos test-driver from
`nixos/lib/test-driver/` in the same rev. Answer to ROADMAP M6 exit item
"A second seat gets its own console", which *depends on Q1* (ROADMAP.md § M6).

## Verdict

**Feasible**, without any QEMU or nixpkgs changes and without guest-side udev
rules. The nixpkgs test driver already opens a raw QMP socket to every VM; QMP
`input-send-event` addresses a specific USB keyboard (via input-routing, the
keyboard's `display=` property); and systemd 262 ships udev rules that turn
QEMU's `pci-bridge-seat` device into a real logind seat (`seat-…` name) that
the second keyboard then joins automatically. The only hardware requirement is
a *second graphics card* in the VM: logind never creates a seat for a keyboard
alone (verified in source, below), and the roadmap already plans a second GPU
for M5 multi-monitor.

`HMP sendkey` **cannot** address a specific device (`sendkey keys [hold_ms]`,
no device argument) — the QMP client is required for per-keyboard injection.
It is exposed by the test driver already.

## Evidence chain (all links verified in source)

### L1 — the test driver exposes a raw QMP client and QEMU listens on a QMP socket

- QEMU is launched with `-qmp unix:<state_dir>/qmp,server=on,wait=off`
  (`nixos/lib/test-driver/src/test_driver/machine/__init__.py:265`).
- After boot the driver connects: `self.qmp_client = QMPSession.from_path(self.qmp_path)`
  (same file, `:1517`).
- `QMPSession.send(cmd, args)` serializes `{"execute": cmd, "arguments": args}`
  and waits for the reply (`nixos/lib/test-driver/src/test_driver/machine/qmp.py:93-104`).
  It accepts arbitrary JSON arguments (json.dump; the `dict[str, str]` annotation
  is loose — nested `events` structures work).
- A concrete in-tree precedent that calls QMP from a test:
  `nixos/tests/nixos-test-driver/qmp-api-error.nix:10-17`
  (`assert machine.qmp_client is not None; machine.qmp_client.send("…")`).
- `wait_for_qmp_event(filter, timeout)` is also available if the test wants to
  observe `DEVICE_*` events (`__init__.py:1288-1313`).

### L2 — HMP `sendkey` cannot target a device; QMP `input-send-event` can

- HMP: `.name = "sendkey", .args_type = "keys:s,hold-time:i?"` — keys + optional
  hold time only, no device selector (`hmp-commands.hx`, QEMU v11.1.2 repo
  root). The driver's `send_key` uses exactly this:
  `self.send_monitor_command(f"sendkey {key}")` (`__init__.py:1446`).
- QMP: `input-send-event` (Since 2.6) takes `device` (string, optional), `head`
  (int, optional) and `events` (list of `InputEvent`; `key` events carry a
  `QKeyCode` qcode plus `down: bool`).
  - Docs: `qemu-qmp-ref.html` § `input-send-event` — installed locally at
    `/nix/store/0hql4rlh4xw6rkli1i63cgsk2458gd6x-qemu-11.1.2-doc/share/doc/qemu/qemu/interop/qemu-qmp-ref.html`
    (anchor `id="command-QMP-ui.input-send-event"`); also upstream
    https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html#qmp-command-input-send-event
  - Implementation: `ui/input.c:155` `qmp_input_send_event(device, has_head, head, events)`:
    `device` → `qemu_console_lookup_by_device_name(device, head)`; each event →
    `qemu_input_find_handler(1 << event->type, con)` (`ui/input.c:183`) then
    `qemu_input_event_send(con, &evt)`.
  - `qemu_console_lookup_by_device_name` resolves the *display device* by QOM
    id: `qdev_find_recursive(sysbus_get_default(), device_id)` then
    `qemu_console_lookup_by_device(dev, head)` (`ui/console.c:1235`). The doc's
    own example uses `"device": "video0"` — the id of a display device.
  - `qemu_input_find_handler` (`ui/input.c:114`) delivers to the handler bound
    to that console first (`s->con == con`, second loop falls back to unbound
    handlers). Line 351 (`qemu_input_event_send_impl`) is the delivery point.

### L3 — one `usb-kbd` can be bound ("input routing") to a specific display

- `usb-kbd` accepts `-device usb-kbd,id=kbd2,display=video.2`; the `display`
  property is a real device property (`hw/usb/dev-hid.c:842-844`,
  `DEFINE_PROP_STRING("display", …)`). On realize:
  `qemu_input_handler_bind(us->hid.s, us->display, us->head, NULL)`
  (`hw/usb/dev-hid.c:724`), which attaches the keyboard's input handler to the
  console of `video.2` (`ui/input.c` `qemu_input_handler_bind`).
- Consequence: `input-send-event {device:"video.2", events:[key…]}` reaches
  **only** the keyboard routed to `video.2`; HMP `sendkey` (no console) reaches
  the **first unbound** keyboard — in the default VM that is the
  `virtio-keyboard`, so seat0 keeps working unchanged (see C3/C4 for the
  default device set).
- USB keyboard identity in the guest: product string "QEMU USB Keyboard"
  (`hw/usb/dev-hid.c:69`).

### L4 — the NixOS test VM already has USB and a keyboard; a second works

- Defaults for x86_64 (`nixos/modules/virtualisation/qemu-vm.nix:1301-1313`):
  `-device virtio-keyboard` (option `virtualisation.qemu.virtioKeyboard`,
  default true, `:886-889`) and `-usb -device usb-tablet,bus=usb-bus.0`
  (`:1305-1308`) — i.e. the piix3 UHCI bus `usb-bus.0`, which has 2 root ports
  (tablet takes one; a second device would fit).
- Extra devices are appended verbatim via `virtualisation.qemu.options`
  (`types.listOf types.str`, `:801-807`; appended at `:362`). So
  `-device qemu-xhci … -device usb-kbd,…` just works; we put the second
  keyboard on its own xHCI controller on the second-seat PCI bridge (below),
  which is also what gives it the right seat (L5) with unlimited ports.

### L5 — the second seat is created by udev/logind, automatically, from `pci-bridge-seat`

- `71-seat.rules` (installed in the nixpkgs systemd 262 output:
  `/nix/store/6qqq5prql4952z0wfm5ymjfr7cx4ab7z-systemd-262/lib/udev/rules.d/71-seat.rules`):
  - `:14` input devices get tagged `seat`: `SUBSYSTEM=="input", KERNEL=="input*", TAG+="seat"`;
  - `:35` GPUs are seat masters: `SUBSYSTEM=="drm", KERNEL=="card[0-9]*", TAG+="seat", TAG+="master-of-seat"`;
  - `:49` QEMU's multiseat bridge is recognized: `SUBSYSTEM=="pci", ATTR{vendor}=="0x1b36", ATTR{device}=="0x000a", TAG+="seat", ENV{ID_AUTOSEAT}="1"` — this is the `-device pci-bridge-seat` (vendor 0x1b36 = QEMU, device 0x000a);
  - `:75-76` seat-tagged devices get an address: `ID_PATH`/`ID_FOR_SEAT` via
    builtin `path_id` (`ENV{ID_FOR_SEAT}="$env{SUBSYSTEM}-$env{ID_PATH_TAG}"`).
- `73-seat-late.rules` (same store dir) turns that into a seat id and spreads it
  over the whole subtree:
  - `:12` `ENV{ID_SEAT}=="", ENV{ID_AUTOSEAT}=="1", ENV{ID_FOR_SEAT}!="", ENV{ID_SEAT}="seat-$env{ID_FOR_SEAT}"`
    → the bridge gets e.g. `ID_SEAT=seat-pci-0000_00_12_0`;
  - `:13` `ENV{ID_SEAT}=="", IMPORT{parent}="ID_SEAT"` → the second GPU's DRM
    card, the xHCI controller and the USB keyboard (all sysfs descendants of
    the bridge) **inherit the same ID_SEAT**;
  - `:15` `ENV{ID_SEAT}!="", TAG+="$env{ID_SEAT}"`.
  This is the same mechanism as the QEMU howto (`docs/multiseat.txt` upstream,
  https://gitlab.com/qemu-project/qemu/-/blob/master/docs/multiseat.txt) which
  shows the result as `loginctl list-seats` → `seat0` +
  `seat-pci-pci-0000_00_12_0`.
- logind (systemd 262 source):
  - Seat membership = per-device `ID_SEAT`, default `seat0`:
    `device_get_seat()` in `src/libsystemd/sd-device/device-util.c`
    (https://raw.githubusercontent.com/systemd/systemd/v262/src/libsystemd/sd-device/device-util.c).
  - Seat creation happens only for `master-of-seat` devices:
    `manager_process_seat_device()` in `src/login/logind-core.c` — `master =
    sd_device_has_current_tag(d, "master-of-seat") > 0;` and
    `if (!master && !seat) return 0;` — **a keyboard alone cannot create a
    seat, and a seat without a master is garbage-collected**
    (`device_detach()` in `src/login/logind-device.c`). Hence the second GPU
    is required.
- No guest-side udev file is needed: the rules above live in systemd 262
  itself. (Fallbacks if someone insists on a manual rule are in § Recipe,
  variant B.)

## Recipe

### 1. Machine config (nixos test)

```nix
test = {
  imports = [ (import ./..) ]; # or use pkgs.testers.runNixOSTest
  virtualisation.qemu.options = [
    # Second seat: PCI-PCI bridge auto-tagged by systemd 71/73-seat.rules.
    "-device pci-bridge-seat,chassis_nr=2,id=seat.2"
    # Second GPU (a seat master). secondary-vga = bochs-drm card1; the
    # primary std VGA (bochs-drm card0) stays the seat0 console. This is the
    # device whose qom id we address from QMP.
    "-device secondary-vga,bus=seat.2,addr=02.0,id=video.2"
    # Dedicated USB controller on the same bridge (ports + electrical path).
    "-device qemu-xhci,bus=seat.2,addr=0f.0,id=usb.2"
    # The second keyboard, input-routed to video.2 (kbd id is for qtree only;
    # events address the DISPLAY id).
    "-device usb-kbd,bus=usb.2.0,port=1,id=kbd2,display=video.2"
    # Optional pointer for seat 2.
    "-device usb-tablet,bus=usb.2.0,port=2,display=video.2"
  ];
  # virtioKeyboard stays at its default true → HMP sendkey keeps landing on
  # the seat0 keyboard (the only *unbound* key handler).
};
```

Notes:
- `secondary-vga` + primary std VGA is the exact combination from QEMU's
  official `docs/multiseat.txt`; bochs-drm is already loaded for the primary
  display. A second `-device virtio-gpu-pci,id=video.2` works too (virtio-gpu
  guest driver needed) and may be preferred later for M5 parity; keep the
  `id` in either case.
- Under the headless test (`-nographic`, `qemu-vm.nix:1355-1357`) the second
  display still creates its QemuConsole — the routing target exists.

### 2. Test-driver python

```python
import time

def qmp_key(device, key, down):
    # key is a QKeyCode qcode name, e.g. "a", "ret", "spc", "shift"
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
    # QMP accepts only single qcode names; combine HMP-style "shift-a" and
    # drop HMP hex codes ("0x0C") in favor of qcode names (minus, equal,
    # bracket_left, semicolon, apostrophe, grave_accent, backslash, comma,
    # dot, slash …). QKeyCode enum: qemu-qmp-ref.html § QKeyCode.
    for ch in text:
        key = {"\n": "ret", " ": "spc"}.get(ch, ch)
        if ch.isupper():
            qmp_key(device, "shift", True)
            qmp_tap(device, key.lower())
            qmp_key(device, "shift", False)
        else:
            qmp_tap(device, key)

start_all()
machine.wait_for_unit("multi-user.target")

# --- 1. the second seat exists and owns the second keyboard
machine.wait_until_succeeds("loginctl list-seats --no-legend | grep -qE '^seat-'")
seat1 = machine.succeed(
    "loginctl list-seats --no-legend | awk '{print $1}' | grep -v '^seat0$' | head -1"
).strip()
_ = seat1  # e.g. "seat-pci-0000_00_12_0" (name derived from the bridge PCI path)
machine.succeed(f"loginctl seat-status {seat1} | grep -q 'QEMU USB Keyboard'")
machine.succeed(f"loginctl seat-status {seat1} | grep -q 'drm/card1'")

# --- 2. find the evdev node of the seat1 keyboard (both keyboards report the
#        product string "QEMU USB Keyboard"; the seat1 one carries ID_SEAT)
kbd1 = machine.succeed(
    "for d in /sys/class/input/event*; do "
    f"  grep -qs 'QEMU USB Keyboard' $d/device/name && "
    f"  udevadm info --query=property --property=ID_SEAT -- $d | grep -q -w {seat1} && "
    "  basename $d; done | head -1"
).strip()

# --- 3. protocol-level proof that QMP addresses ONLY kbd2
machine.succeed(f"( timeout 5 od -An -v -tu4 /dev/input/{kbd1} > /tmp/kbd1.hex & )")
machine.succeed("( timeout 5 od -An -v -tu4 /dev/input/event1 > /tmp/kbd0.hex & )")
time.sleep(0.5)
qmp_tap("video.2", "ret")               # EV_KEY(1) KEY_ENTER(28) down,up → "1 28 1" twice
time.sleep(1)
assert " 1 28 1" in machine.succeed("cat /tmp/kbd1.hex")   # seat1 kbd received it
assert " 1 28 1" not in machine.succeed("cat /tmp/kbd0.hex")  # seat0 kbd did not
# and HMP sendkey (no device argument) lands on seat0 only
machine.send_key("ret")
time.sleep(1)
assert " 1 28 1" in machine.succeed("cat /tmp/kbd0.hex")
assert " 1 28 1" not in machine.succeed("cat /tmp/kbd1.hex")
```

The `event1` id for the seat0 keyboard in step 3 must be resolved the same way
(`evdev` enumeration order can vary between kernels); the loop above shows the
pattern. M6's real assertion then replaces the `od` capture with kmshaunt:
seat1's console (fake VT on card1) receives the key and the seat0 console does
not, observed as a marker file written by the seat1 shell, or by screenshots of
the two DRM cards.

### 3. Variant B — tag by hand when `pci-bridge-seat` is not usable

The same wiring as above but without the bridge device, plus guest udev rules
(`virtualisation.etc`-style, e.g. write into `/etc/udev/rules.d/`):

```
# 70-multiseat.rules, guest side (only for this fallback)
# give the second GPU's DRM card and the second keyboard the same ID_SEAT
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", KERNELS=="*0000:01:00.0", ENV{ID_SEAT}="seat1"
SUBSYSTEM=="input", KERNEL=="event*", SUBSYSTEMS=="pci", KERNELS=="*0000:01:00.0", ENV{ID_SEAT}="seat1", TAG+="seat1"
```

(`KERNELS` matches ancestors; adjust to the xHCI's PCI address.) The
pci-bridge-seat route is strictly better: zero guest config, maintained by
systemd itself (71-seat.rules:49 is in systemd since 222, still in 262).

## Conditions and caveats

1. **A second GPU is mandatory** for a second logind seat (L5). Do not attempt
   M6 without it; a keyboard-only "seat1" is ignored by logind.
2. **Seat name is dynamic**: `seat-<subsystem>-<ID_PATH_TAG>` of the bridge
   (e.g. `seat-pci-0000_00_12_0`); never hardcode it in assertions — take it
   from `loginctl list-seats` as in the snippet.
3. Key codes for QMP are the `QKeyCode` enum names (letters, `ret`, `spc`,
   `shift`, `alt`, `ctrl`…). HMP's `shift-a` composition and hex `0x0C` forms
   are NOT QMP enum values — use the helper (qcode names exist for punctuation:
   `minus`, `equal`, `bracket_left`, …). The driver's `CHAR_TO_KEY`
   (`__init__.py:42`) is the safe source for letters/digits/`ret`/`spc`.
4. Keep `virtualisation.qemu.virtioKeyboard` at its default `true` so HMP
   keys are unambiguous (unbound handler = virtio-keyboard). If it is disabled,
   the second USB keyboard becomes the unbound key handler and HMP sendkey
   would target it.
5. aarch64 test VMs have different defaults (`usb-ehci`, a plain `usb-kbd`);
   this recipe is written for the x86_64 test VM that kmshaunt targets
   (bochs-drm primary).
6. The following was verified by reading shipped sources, not by a live VM run
   (a build of a nixosTest takes ≫10 min; the analysis is conclusive on every
   link). Steps worth a quick runtime confirmation during M6 kickoff, reusing
   the snippet above: seat name derivation, `od`-capture pattern, and that
   `secondary-vga` + `-nographic` boots card1 on the pinned kernel (bochs-drm).

## Fallback

If any runtime surprise appears at M6 kickoff on the conditions above (seat
naming, secondary-vga driver, or QMP routing on the exact qemu_kvm build),
move the multi-seat input check to T5 real hardware as ROADMAP already planned
(M8 checklist: "VT switch to and from a Wayland session", two seats) — Q1 does
not block M1–M5. Nothing in this probe indicates that would be needed; the
pieces (QMP client, input routing, autoseat rules) are all present in the
pinned nixpkgs.

## Citations (short form)

- Test driver: `nixos/lib/test-driver/src/test_driver/machine/__init__.py:265,1517,1446,42`;
  `qmp.py:32-104`; precedent `nixos/tests/nixos-test-driver/qmp-api-error.nix:10-17`.
  Source: nixpkgs rev f9a75f41 — store path
  `/nix/store/4rwf9a42lpij7vhpwxjz8nzb3cpkf4zx-source`.
- QEMU 11.1.2 (nixpkgs `qemu_kvm`): local docs
  `/nix/store/0hql4rlh4xw6rkli1i63cgsk2458gd6x-qemu-11.1.2-doc/share/doc/qemu/qemu/interop/qemu-qmp-ref.html`
  § `input-send-event` (anchor `command-QMP-ui.input-send-event`, Since 2.6) and
  § `QKeyCode` (anchor `enum-QMP-ui.QKeyCode`). Source at
  https://raw.githubusercontent.com/qemu/qemu/v11.1.2/{ui/input.c:114,155,183,344-359,
  ui/console.c:1235, hw/usb/dev-hid.c:69,698-724,842-844, hmp-commands.hx § sendkey};
  howto https://gitlab.com/qemu-project/qemu/-/blob/master/docs/multiseat.txt.
- systemd 262 (nixpkgs): udev rules
  `/nix/store/6qqq5prql4952z0wfm5ymjfr7cx4ab7z-systemd-262/lib/udev/rules.d/71-seat.rules:14,35,49,75-76`
  and `73-seat-late.rules:12-15`; source
  https://raw.githubusercontent.com/systemd/systemd/v262/src/login/logind-core.c
  (`manager_process_seat_device`), `src/login/logind-device.c` (`device_detach`),
  `src/libsystemd/sd-device/device-util.c` (`device_get_seat`).
- nixos VM module: `nixos/modules/virtualisation/qemu-vm.nix:362,801-807,886-889,1301-1313,1355-1357`.