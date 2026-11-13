# kmscon private OSC: `setBackground` / `setForeground`

The two escape sequences kmscon uses to hand its DRM device to a GUI program
and take it back afterwards. Companion documents: `kmscon-options.md` (all
options, defaults and palettes) and `ghostty-vt-api.md` (§8.5 is the
unknown-sequence effect these OSCs must be routed through). ROADMAP M2.1
item 1 and the `Private OSC` appendix row.

Provenance — everything below was read out of these trees, not out of kmscon
documentation (the sequences are undocumented; `NEWS.md` only mentions the
launcher script, `README.md:133-140` only shows how to call it):

- kmscon **10.1.0** (`meson.build:5-8`), obtained with
  `nix build nixpkgs#kmscon.src --print-out-paths --no-link` →
  `/nix/store/87j2xajxjphwhla24iw4n9jpiy33av63-source`. All `src/…`,
  `scripts/…`, `include/…` and `meson.build` citations are relative to that
  tree.
- libtsm **v4.8.0** (`subprojects/libtsm.wrap`), the VT parser that decodes
  the OSC and hands it to kmscon →
  `/nix/store/ipf5pp9p67m4vix8ywic18fdyb4n5i23-source` (`nix build
  nixpkgs#libtsm.src`). `src/tsm/tsm-vte.c` citations are from that tag.
- libghostty-vt **1.0.1** for the receiving side; same release tarball as
  `ghostty-vt-api.md`. Citations are relative to `include/ghostty/vt/` and
  `src/` inside the tarball.

---

## 1. Wire format

### 1.1 Bytes on the pty

The payload is a bare ASCII identifier. There is **no numeric OSC selector and
no `;`** — the whole string between `ESC ]` and the terminator is the command.

```
setBackground  1B 5D 73 65 74 42 61 63 6B 67 72 6F 75 6E 64 07
               ESC ]  s  e  t  B  a  c  k  g  r  o  u  n  d  BEL

setForeground  1B 5D 73 65 74 46 6F 72 65 67 72 6F 75 6E 64 07
               ESC ]  s  e  t  F  o  r  e  g  r  o  u  n  d  BEL
```

Each is exactly **16 bytes**. In C string form the sender uses
`printf '\033]setBackground\a'` / `printf '\033]setForeground\a'`
(`scripts/kmscon-launch-gui.sh:17,41`).

### 1.2 Both terminators are accepted; kmscon's sender uses BEL

kmscon's own script ends the sequence with `BEL` (`\a`). The parser also
accepts `ST` (`ESC \`), because both end the OSC state in libtsm and reach the
callback:

| terminator | bytes | libtsm path |
|---|---|---|
| `BEL` | `07` | `tsm-vte.c:2725-2728` → `STATE_GROUND`, `ACTION_NONE`, then the OSC exit action fires (`tsm-vte.c:2381-2383`) |
| `ST` | `1B 5C` | `0x1b` is caught by the any-state switch (`tsm-vte.c:2422-2424`) → `STATE_ESC`, firing `ACTION_OSC_END` with `0x1b`; the `\` is then consumed by the `STATE_ESC` dispatcher (`tsm-vte.c:2476-2479`) |

`do_osc_end` (`tsm-vte.c:2302-2314`) receives the terminating byte, computes a
reply terminator with `osc_end_seq` (`tsm-vte.c:2294-2300`; `0x07` → `BEL`,
anything else → `ST`) and only uses it for the library's own OSC 4/10/11
replies — for a kmscon-private string the reply terminator is computed and
discarded.

Two extra terminators exist that a *sender* should never use but that still
dispatch the callback in libtsm: `CAN` (`0x18`) and `SUB` (`0x1a`) are handled
by the any-state switch (`tsm-vte.c:2413-2420`) as `ACTION_EXECUTE`, which
also runs the OSC exit action, so `ESC ] setBackground CAN` invokes
`setBackground`. libghostty-vt drops CAN/SUB-aborted OSCs instead (§6.4).

### 1.3 The tmux wrapper (sender-side only)

The shipped script wraps both OSCs in a DCS passthrough when it runs under
tmux (`scripts/kmscon-launch-gui.sh:15-18,39-42`):

```
tmux form  1B 50 74 6D 75 78 3B  1B 1B 5D <payload> 07  1B 5C
           ESC P  t  m  u  x  ;  ESC ESC ]         BEL ESC \
```

That is `\033Ptmux;\033\033]setBackground\a\033\\`. This wrapper is a property
of the *sender*: tmux strips the DCS layer and forwards the inner OSC to
whatever terminal is behind it. kmshaunt never has to parse the DCS form; it
only has to handle the inner 16-byte sequence, which is what tmux delivers.

### 1.4 What does not match

kmscon compares the collected payload with `strcmp` against the two literals
(`src/terminal.c:494,497`), so the match is **exact and case-sensitive**:

| input | result |
|---|---|
| `ESC ] setBackground BEL` | match |
| `ESC ] setBackground ESC \` | match (§1.2) |
| `ESC ] setBackground; BEL` | no match (the `;` is part of the payload) |
| `ESC ] 8;setBackground BEL` | no match (payload starts with `8;`) |
| `ESC ] setbackground BEL` | no match |
| `ESC ] setBackground BEL` with trailing space | no match |
| `ESC ] setBackgroundX…` (any extra bytes) | no match — `strcmp` needs exact equality, and libtsm keeps at most 127 payload bytes (`OSC_MAX_LEN 128`, `tsm-vte.c:118`) while `do_osc_collect` silently drops the rest (`tsm-vte.c:2212-2215`) |

The `8-bit C1` form `0x9D` for `ESC ]` is **not** usable with kmscon: `0x9d`
is only recognised as an OSC introducer in `TSM_VTE_FLAG_8BIT_MODE`
(`tsm-vte.c:2433-2435`), and kmscon creates its `tsm_vte` with no flags
(`tsm_vte_new(..., NULL)` — `src/terminal.c:1460`), i.e. UTF-8 mode, where a
lone `0x9d` byte is rejected by the UTF-8 decoder before the parser sees it.

The collected payload is NUL-terminated by `do_osc_end`
(`vte->osc_arg[vte->osc_len] = 0;`, `tsm-vte.c:2304`), which is what lets
kmscon use `strcmp`. The buffer is cleared on every OSC start
(`do_clear`, `tsm-vte.c:1007-1018`, invoked by `ACTION_OSC_START`).

---

## 2. Sender and trigger

There is exactly one sender in the kmscon tree: `kmscon-launch-gui`, installed
to `bindir` from `scripts/kmscon-launch-gui.sh` (`meson.build:245-250`).

```
kmscon-launch-gui <cmd…>                      scripts/kmscon-launch-gui.sh:1-42
  kms_tty = $(cat /sys/class/tty/tty0/active)                          :9-13
  printf '\033]setBackground\a'                                       :15-18
  sleep 0.2 || sleep 1     # "give time for kmscon to release drm master"  :20-21
  "$@"                                                                :23
  wait until /sys/class/tty/tty0/active is back to kms_tty
      (inotifywait -qqe modify on that file, else sleep 1 poll)        :25-37
  printf '\033]setForeground\a'                                       :39-42
```

How a user reaches it: when the video backend is DRM, kmscon exports
`KMS_START_SCRIPT=kmscon-launch-gui` and `TERM_SESSION_TYPE=kms` into every
session's environment (`src/misc/pty.c:239-241`; fbdev gets only
`TERM_SESSION_TYPE=fb`, `:243`). Nothing in the tree consumes the variable —
it exists so shell configuration can define e.g.
`kms-start() { "$KMS_START_SCRIPT" "$@"; }`. `README.md:133-140` documents the
resulting workflow (`kmscon-launch-gui kmscube -c 100`,
`kmscon-launch-gui cage -- mpv test.mp4`).

Because the OSC arrives on the pty as ordinary terminal output, **any**
program in the session can send it; there is no authentication and no
capability check. The effect is bounded by the kmscon session guards in §3.4.

---

## 3. Behavioral contract

### 3.1 Dispatch

```
src/terminal.c:490-501   osc_event(tsm_vte, osc_string, osc_len, data)
                            strcmp "setBackground" → kmscon_session_set_background(term->session)
                            strcmp "setForeground" → kmscon_session_set_foreground(term->session)
src/terminal.c:1466      tsm_vte_set_osc_cb(term->vte, osc_event, term)   registration
src/terminal.c:1393-1401 pty_input() → tsm_vte_input(); the OSC is thus handled
                         synchronously on the pty-read path, before the read
                         handler returns
```

Each match logs `log_info("Got OSC setBackground")` / `"Got OSC setForeground"`
(`src/terminal.c:495,498`). That log line is the only externally visible trace
of the sequence — see §3.5.

Note the dispatch happens for *every* OSC payload except the three libtsm
implements internally (`4;…`, `10;?`, `11;?` — `do_osc_internal`,
`tsm-vte.c:2267-2291`); everything else reaches `osc_event` and is ignored
unless it equals one of the two literals.

### 3.2 `setBackground` — step order

`kmscon_session_set_background` (`src/seat.c:1180-1205`):

1. Guard: `!sess` → `-EINVAL`; `!sess->foreground` → `0` (no-op, idempotent)
   (`:1185-1188`).
2. Only if this session is the seat's current one and the seat is in the
   foreground (`:1191`):
   1. `terminal_deactivate(term)` (`:1193`, body `src/terminal.c:1360-1369`):
      `awake = false`; hide the hardware cursor; disable the blink and
      cursor-blink timers; `kmscon_asciinema_pause()`.
   2. `seat_go_background(seat)` (`:1195`, body `src/seat.c:199-214`): for
      every video device `video_sleep()`.
      `video_sleep` (`src/video/video.c:558-567`) clears `VIDEO_AWAKE`
      *before* calling the backend, which makes the backend's `show_displays()`
      call a no-op (`drm2d_video.c:250-251`, `drm3d_video.c:448-449` both
      test `video_is_awake`). Consequence: **kmscon does not blank or repaint
      the screen on the way out** — it goes on showing the last frame while it
      still owns the device, and the incoming GUI modesets over it. The black
      clear happens on wake, not on sleep.
      The actual release, `drm_video_sleep` (`src/video/drm_shared.c:1572-1596`):
      - if this device is DRM master and not `legacy`, wait for the pending
        page flip of every display (`drm_display_wait_pflip`), then build one
        atomic request that clears the cursor and overlay planes
        (`modeset_clear_cursor_and_overlays`, `drm_shared.c:297-340`) and
        commit it with `drmModeAtomicCommit(…, 0, NULL)` — flagged only with a
        warning on failure (`:1585-1590`);
      - `drop_drm_master(vdrm)` → `drmDropMaster(fd)`, `master = false`
        (`:1242-1246`);
      - disarm the VT-timeout retry timer: `ev_timer_drain` + `ev_timer_update(NULL)`
        (`:1593-1595`).
   3. `seat_go_asleep(seat)` (`:1198`, body `src/seat.c:217-225`): `awake = false`,
      then `input_sleep()` (`src/input/input.c:722-739`), which stops key
      repeat, removes the evdev fds from the eloop and **closes every input
      device** (`input_sleep_dev`, `src/input/input.c:193-203`) so the GUI can
      take the seat's keyboards and pointers.
3. Unconditionally `sess->foreground = false` (`:1203`) — including when step 2
   was skipped, see §3.4.

Errors from steps 2.2/2.3 are returned to `osc_event`, which ignores the
return value (`src/terminal.c:496`); nothing is logged beyond each layer's own
`log_*`.

### 3.3 `setForeground` — step order

`kmscon_session_set_foreground` (`src/seat.c:1148-1178`):

1. Guard: `!sess` → `-EINVAL`; `sess->foreground` already true → `0` (no-op)
   (`:1153-1156`).
2. Only if this session is the seat's current one and the seat is in the
   background (`:1159`):
   1. `uterm_vt_restore(seat->vt)` (`:1160`, body `src/uterm/vt.c:169-182`).
      Real-VT backend (`real_restore`, `src/uterm/vt_real.c:224-259`):
      `KDSETMODE KD_GRAPHICS`, `VT_SETMODE` with `VT_PROCESS` /
      `acqsig = SIGUSR1` / `relsig = SIGUSR2`, `KDSKBMODE K_RAW`, then
      `KDSKBMODE K_OFF` (failure only warns). This re-establishes exactly the
      console state that `real_open` set up at start
      (`src/uterm/vt_real.c:286-300`) — the interposed GUI may have changed
      it. With the seatd/libseat backend there is no `.restore` op in
      `vt_libseat_ops` (`src/uterm/vt_libseat.c:338-347`), so
      `uterm_vt_restore` returns `0` and this step is a no-op.
   2. `seat_go_awake(seat)` (`:1164`, body `src/seat.c:228-240`): fail with
      `-EBUSY` if the seat is exiting; else `awake = true` and
      `input_wake_up()` (`src/input/input.c:741-770`), which re-initialises
      devices that were never probed and re-opens the rest — devices that
      cannot be reopened are freed.
   3. `seat_go_foreground(seat)` (`:1168`, body `src/seat.c:158-197`):
      - `foreground = true` set *first* (`:170`), so a failure below leaves
        the seat marked foreground;
      - retry `seat_video_init` for any video whose `vid->video` is still
        `NULL` (device was unplugged/re-plugged, `:172-185`);
      - `video_wake_up` for every sleeping video (`:187-189`). For DRM,
        `drm_video_wake_up` (`src/video/drm_shared.c:1555-1570`):
        `set_drm_master` → `drmSetMaster(fd)` (`:1227-1240`, logs
        `"Cannot set drm master …"` on failure and returns the error), then
        `flags |= VIDEO_AWAKE | VIDEO_HOTPLUG` and
        `drm_video_hotplug(video, read_dpms=true, modeset=true)`, which
        re-modesets and calls `display_ready` per display; if hotplug fails
        the master is dropped again (`:1566-1567`) and the backend arms the
        50 ms VT retry timer (`drm2d_video.c:316-320`,
        `drm3d_video.c:681-685`);
      - `activate_display` for every display (`src/seat.c:191-194`): DPMS on,
        reset the DPMS idle timer, re-`terminal_add_display` for all sessions,
        then `terminal_activate` of the current session.
   4. `terminal_activate(term)` (`:1173`, body `src/terminal.c:1345-1357`):
      `awake = true`; re-enable blink timers; if the pty was closed
      `terminal_open()` restarts the child, else `kmscon_asciinema_resume()`;
      then `terminal_refresh_displays()` (`src/terminal.c:1331-1343`) →
      re-show the hardware cursor, `display_set_need_redraw` on every screen
      and a full `redraw_all()`.
3. Unconditionally `sess->foreground = true` (`:1176`).

The 50 ms retry (`vt_timeout`, `drm_shared.c:1189-1210`, timer armed by
`drm_video_arm_vt_timer`, `:1213-1224`): each expiry calls
`drm_video_wake_up` again and, on success, disarms itself and refreshes every
display; after `MAX_VT_TIMEOUT_RETRIES` = 20 (`drm_shared.c:51`, i.e. ~1 s) it
gives up and only logs `"vt_timeout: failed to wake up after 20 retries"`.
`drmSetMaster` can fail with `EBUSY` while the GUI still holds the device, so
this timer is the real "wait for the GUI to let go" mechanism — `setForeground`
itself returns immediately even if the retake is still pending.

### 3.4 Guards and state quirks

- Both functions are **idempotent in the normal case**: a second
  `setBackground` while already background returns 0 without touching the
  hardware (`seat.c:1187-1188`), likewise `setForeground`
  (`seat.c:1155-1156`).
- Both only act on the seat when `seat->current_sess == sess`. A *non-current*
  session (kmscon supports several sessions per seat, switched by the
  `grab-session-*`/`next`/`prev` machinery) that sends `setBackground` still
  has its `sess->foreground` set to `false` (`seat.c:1203`) without the seat
  being touched, because the whole hardware block is skipped. The mirror case
  is the same: a non-current session's `setForeground` sets its flag to `true`
  (`seat.c:1176`) while the seat stays as it was.
- `seat_switch` (`src/seat.c:242-263`) consults `sess->foreground` when
  choosing whether to go foreground/background on a session switch, so the
  flag above is not cosmetic.
- The same primitives run on plain VT switches: `seat_vt_deactivate`
  (`src/seat.c:389-404`) is `terminal_deactivate` + `seat_go_background` +
  `seat_go_asleep`, and `seat_vt_activate` (`src/seat.c:375-386`) is
  `seat_go_awake` + `seat_go_foreground` + `terminal_activate` — i.e. the OSCs
  are the *manual* form of `ctrl-alt-fN` away/back. The only difference is
  that the kernel-driven re-entry already re-established the console, so
  `setForeground` additionally calls `uterm_vt_restore` (§3.3 step 2.1).

### 3.5 Acknowledgement: there is none

- `tsm_vte_osc_cb` returns `void` (`libtsm.h:455-458`); a reply is written only
  when `do_osc_internal` claims the sequence (OSC 4/10/11 queries, via
  `vte_write_xcolor`), and the callback path writes nothing
  (`tsm-vte.c:2306-2313`).
- `osc_event` never calls `tsm_vte_input`/`vte_write` and never writes to the
  pty (`src/terminal.c:490-501`).
- Therefore kmscon emits **zero bytes** in response to either sequence. The
  only feedback is the `log_info` line on kmscon's log target (stderr /
  journal).
- Consequence for parity work: do **not** answer. `ghostty-vt-api.md` §8.5
  says a reply is optional and must reuse the terminator; kmscon's behaviour
  is "no reply", and a reply would be a behavioural difference (it would also
  be pasted into whatever program next reads the tty if the sender isn't in
  raw mode).

### 3.6 Note on `KD_TEXT` — it does not appear in this path

`setBackground` never issues `KDSETMODE KD_TEXT`, never calls `VT_ACTIVATE`
and never closes the VT: the console stays owned by kmscon in `KD_GRAPHICS`
with `VT_PROCESS` control. The device is released at the DRM level
(`drmDropMaster`) and the input fds are closed, which is what frees the
hardware for the GUI. `KD_TEXT` is written only when the VT is closed or fails
to open (`src/uterm/vt_real.c:349-351,385-387`), when the libseat backend's
seat is disabled (`tty_deactivate`, `src/uterm/vt_libseat.c:122-130`, via
`vt_libseat_disable`, `:142-151`), and on VT-switch handling inside the
kernel — the incoming/outgoing console owns its own mode, never kmscon's.
`setForeground` re-asserts `KD_GRAPHICS` explicitly (§3.3 step 2.1) precisely
because a program may have changed the tty's mode in between.

Shadowing this with a synthetic `KD_TEXT` bounce would be an observable
difference (it flashes a text console, and it would let a getty on the same tty
paint). kmshaunt must not do it.

---

## 4. `--drm` / `--hwaccel` / libseat interaction

Backend selection is per video device, `seat_video_init`
(`src/seat.c:899-947`):

| config | backend | sleep/wake behaviour |
|---|---|---|
| `--drm` (default on, `config.c:1051`) and `--hwaccel` (`config.c:1052`, default off) | `drm3d` (`seat.c:906-907`) | `drm3d_video_sleep` (`drm3d_video.c:671-675`) = `show_displays` (GL clear — inert on sleep, §3.2) + `drm_video_sleep`; wake (`:677-691`) = `drm_video_wake_up` + `show_displays` (GL clear of every online display, `drm3d_video.c:443-462`) |
| `--drm`, no `--hwaccel` | `drm2d` (`seat.c:908-909`) | `drm2d_video_sleep` (`drm2d_video.c:306-310`) + `drm_video_sleep`; wake (`:312-326`) = `drm_video_wake_up` + `show_displays` (memset the current scanout buffer to 0 and wait for pending flips, `drm2d_video.c:244-271`) |
| `drm3d` init fails | falls back to `drm2d` (`seat.c:923-929`, logs `"cannot create drm3d device …; trying drm2d mode"`) | as above |
| `--drm off`, or no DRM build support (`aftercheck_drm` forces `drm = false`, `config.c:889-905`) | `fbdev` (`seat.c:910-911`) | `fb_video_sleep` (`fbdev_video.c:505-516`) only `display_deactivate_force`s the online displays; `fb_video_wake_up` (`:518-546`) re-activates them and restores DPMS. **No DRM master exists, so `setBackground` frees nothing** — a GUI still cannot take the GPU. This is why `KMS_START_SCRIPT` is only exported on the DRM path (`src/misc/pty.c:239-243`) |

Both DRM backends share `drm_video_sleep`/`drm_video_wake_up`; the only
difference in this path is how their `show_displays()` blanks (GL vs. memset)
and that drm3d re-creates its EGL/GBM surfaces through `drm_video_hotplug`'s
modeset on wake.

`--hwaccel` therefore changes nothing about the OSC protocol; it only changes
which backend does the blanking/redraw. `--gpus` and `--mode` affect which
devices are woken, not the sequence semantics.

**libseat:** with `LIBSEAT`-based VT handling the seat is held by the seat
manager, the `.restore` step is a no-op (§3.3), and `README.md:34` states
outright that `kmscon-launch-gui` does not work then ("the seat is already in
use"). The OSC still runs (master dropped, input closed) but no other
libseat client can pick the seat up. I.e. the DRM-master drop is necessary but
not sufficient; the seat must come from a VT backend that kmscon owns.

---

## 5. Timing contract

The protocol has no synchronisation primitive, so the sender's script encodes
the timing assumptions:

- After `setBackground` the script sleeps **0.2 s** (falling back to 1 s if
  `sleep 0.2` is rejected — `kmscon-launch-gui.sh:20-21`) before `exec`ing the
  GUI. The drop therefore has to complete well inside 200 ms of the pty write
  being read. kmscon does it synchronously in the read handler
  (`src/terminal.c:1393-1401`), so the whole budget is
  `terminal_deactivate` + `drm_video_sleep` (one pageflip wait + one atomic
  commit) + input close.
- The GUI holds the device while it runs. kmscon is fully asleep: no video
  fds in the eloop, no input fds, no page flips.
- After the GUI exits the script does **not** immediately send
  `setForeground`; it first waits for `/sys/class/tty/tty0/active` to read
  back the kmscon VT it started on (`:25-37`), i.e. the user must switch back.
  Only then is `setForeground` written.
- On retake, kmscon re-modesets and repaints; if `drmSetMaster` is still
  `EBUSY` (GUI not fully gone) the 50 ms retry loop (§3.3) covers up to
  ~1 s, and the redraw is deferred to whichever retry succeeds.

For kmshaunt: perform the drop synchronously in the loop iteration that read
the pty bytes (not deferred to the next idle tick), and treat the retake as
possibly-deferred.

---

## 6. Implementation notes for the ghostty-vt unknown-sequence effect

### 6.1 Terminal options

Both must be set before the first `ghostty_terminal_vt_write` — and
`UNKNOWN_SEQUENCE` alone does nothing, because the byte limit is what gates
the capture (`unknownOrInvalid` returns early with `MAX_BYTES == 0`,
`src/terminal/osc.zig:748-754`).

```c
GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE   = 36   /* terminal.h:2459 */
GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES  = 37   /* terminal.h:2480 */
```

`UNKNOWN_SEQUENCE` installs the callback; `UNKNOWN_MAX_BYTES` must be **> 0**
or nothing is ever reported (`ghostty-vt-api.md` §8.5, and the parser test
`src/terminal/osc/parsers/unknown.zig:43-57` "disabled by default"). Any value
≥ 14 works for these two sequences; the reference recommends 2048 — the value
of `Parser.MAX_BUF` (`src/terminal/osc.zig:361`), which keeps the
terminal-owned fixed buffer and is allocation-free.

```c
/* terminal.h:722-725 */
typedef void (*GhosttyTerminalUnknownSequenceFn)(
    GhosttyTerminal terminal, void* userdata,
    const GhosttyTerminalUnknownSequence* sequence);

/* terminal.h:593-600, 611-617, 637-658, 680, 687-690 */
typedef enum { GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_APC = 0,
               GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_OSC = 1 } GhosttyTerminalUnknownSequenceTag;
typedef struct { bool truncated; GhosttyString content; } GhosttyTerminalUnknownStringSequence;
typedef struct { bool truncated; GhosttyString content;          /* not NUL-terminated */
                 GhosttyOscTerminator terminator; } GhosttyTerminalUnknownOscSequence;
typedef union  { GhosttyTerminalUnknownStringSequence apc;
                 GhosttyTerminalUnknownOscSequence osc;
                 uint64_t _padding[16]; } GhosttyTerminalUnknownSequenceValue;
typedef struct { GhosttyTerminalUnknownSequenceTag tag;
                 GhosttyTerminalUnknownSequenceValue value; } GhosttyTerminalUnknownSequence;
```

`GhosttyString` is `{ const uint8_t* ptr; size_t len; }` (`types.h:429-445`).
`GhosttyOscTerminator` is `ST = 0`, `BEL = 1` (`osc.h:120-127`).

### 6.2 Why `ESC ] setBackground BEL` reaches the callback

libtsm delivers *any* non-4/10/11 payload to kmscon's callback. libghostty-vt
is narrower ("an OSC whose number this build does not implement"), and a
non-numeric payload is classified as unknown by the OSC state machine:

```
src/terminal/osc.zig:855-867   state .start: '0'..'9' branch to digit states,
                               anything else → unknownOrInvalid(c)
src/terminal/osc.zig:748-781   unknownOrInvalid captures the prefix (here the
                               empty .start prefix) plus the offending byte and
                               enters .unknown
src/terminal/osc/parsers/unknown.zig:7-20  .end() → Command.unknown with
                               content = every byte of the sequence
```

The parser's own tests pin both facts: `.input = "I;name"` (non-numeric
identifier) yields `content == "I;name"`
(`src/terminal/osc/parsers/unknown.zig:86-87`, asserted at `:104`), and
`GhosttyTerminalUnknownOscSequence.content` is documented as "everything
between `ESC ]` and the terminator, including the number at the start"
(`terminal.h:646-651`).

So for the kmscon sequences the callback sees exactly:

| sequence | `tag` | `content` | `content.len` | `truncated` | `terminator` |
|---|---|---|---|---|---|
| `1B 5D … 07` | `…_OSC` (1) | `setBackground` | 13 | false | `BEL` (1) |
| `1B 5D … 07` | `…_OSC` (1) | `setForeground` | 13 | false | `BEL` (1) |
| `1B 5D … 1B 5C` | `…_OSC` (1) | `setBackground` | 13 | false | `ST` (0) |

No terminator is included in `content`, and no `;` is involved.

### 6.3 Handler sketch

```zig
// Sketch: names are as translateC emits them for ghostty/vt.h.
fn onUnknownSequence(
    _: c.GhosttyTerminal,
    userdata: ?*anyopaque,
    seq: *const c.GhosttyTerminalUnknownSequence,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(userdata.?));

    // New tags may appear in later library versions: ignore them.
    if (seq.tag != c.GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_OSC) return;
    const osc = seq.value.osc;
    if (osc.truncated) return;                     // never match a prefix
    const content = osc.content.ptr[0..osc.content.len];

    // Exact, case-sensitive compare — kmscon uses strcmp (terminal.c:494,497).
    if (std.mem.eql(u8, content, "setBackground")) {
        app.pending_session_effect = .background;  // applied after vt_write returns
    } else if (std.mem.eql(u8, content, "setForeground")) {
        app.pending_session_effect = .foreground;
    }
}
```

Hard rules for the handler:

1. **Do not do the work inside the callback.** It runs inside
   `ghostty_terminal_vt_write`, on the pty-read path, and must not call
   `ghostty_terminal_vt_write` again or mutate the terminal. Drop a
   `pending_session_effect` flag (or push to an intra-loop queue) and drain it
   immediately after the `vt_write` call returns, in the same loop iteration —
   that keeps §5's 200 ms budget and preserves ordering with the rest of the
   read.
2. **Do not reply.** kmscon emits nothing (§3.5), so `terminator` is
   informational only. If a future kmscon version adds a reply, end it with
   `terminator` (`BEL` → `\x07`, `ST` → `\x1b\x5c`) per `osc.h:109-127`.
3. `content` is borrowed and not NUL-terminated — compare with a length, never
   `strcmp`, and don't retain the slice.
4. `truncated` means the payload exceeded `UNKNOWN_MAX_BYTES`: a truncated
   buffer whose first 13 bytes spell `setBackground` must **not** match.

### 6.4 Divergences from kmscon that are acceptable

| topic | kmscon (libtsm) | libghostty-vt | verdict |
|---|---|---|---|
| CAN/SUB-aborted OSC (`… CAN`) | delivered to the callback (§1.2) | dropped (`src/terminal/osc/parsers/unknown.zig:141-157`, test "aborted sequences are dropped") | accept — no real sender aborts |
| payload cap | 127 bytes (`OSC_MAX_LEN - 1`) | `UNKNOWN_MAX_BYTES` (2048) | accept — both far above 13 |
| which OSCs are dispatched | everything except `4;…`, `10;?`, `11;?` | only unimplemented ones | no observable difference: kmscon ignores the rest anyway |
| repeated `ESC ]` inside an OSC | `ESC` ends the OSC and starts an escape sequence | same | — |

### 6.5 Mapping onto kmshaunt's modules

The kmscon primitives need counterparts; current state of the tree:

- `src/video.zig` `Backend.VTable` (`:75-115`) has `deinit`, `connectors`,
  `setMode`, `beginFrame`, `endFrame`, `flipPending`, `waitFlip`, `setDpms`,
  `setCursor`, `supportsHwCursor` — **no** sleep/wake. M2 needs a
  `sleep`/`wakeUp` pair (mirroring `video_ops.sleep`/`.wake_up`,
  `src/video/video.h:180-181`) with the DRM implementation doing: waitFlip on
  every display → atomic commit clearing cursor/overlay planes →
  `drmDropMaster`, and on wake `drmSetMaster` → modeset → clear to black →
  full redraw.
- The wake retry needs a `loop.Timer` one-shot of 50 ms
  (`src/loop.zig:337-339 armOneShot`), disarmed on success, capped at 20
  attempts.
- Session-level ordering to copy exactly: deactivate the render path (stop
  blink timers, hide the hardware cursor, pause asciicast) *before* dropping
  master; re-open input *before* `drmSetMaster`; redraw only after the wake
  succeeded (`src/terminal.c:1345-1369`).
- Input: closing the evdev fds on background and reopening on wake
  (`src/input/input.c:193-203,722-770`) is what actually lets the GUI grab the
  keyboard; a kmshaunt backend that only drops DRM master would leave libinput
  owning the devices.
- `src/misc/palette.zig` is irrelevant here — neither sequence touches the
  palette or any terminal attribute; nothing is written to the screen.

### 6.6 Verification vectors

Send the raw bytes from a shell inside the session and expect the kmscon log
line (no output on the tty):

```sh
printf '\033]setBackground\a'   # expect "Got OSC setBackground", DRM master released
printf '\033]setForeground\a'   # expect "Got OSC setForeground", mode restored, screen repainted
```

Negative vectors (must do nothing, silently):

```sh
printf '\033]setBackground;\a'      # trailing semicolon
printf '\033]8;setBackground\a'     # numeric prefix
printf '\033]setbackground\a'       # case
printf '\033]setBackground \a'      # trailing space
```

ST-terminated positive vector (must match — §1.2):

```sh
printf '\033]setBackground\033\\'   # ST instead of BEL
```

Cross-check on kmscon with `journalctl -u kmscon -f` or stderr; the
`log_info` lines are emitted at default verbosity, so no `--verbose` is needed.