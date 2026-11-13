# libseat, sd-login and locale1 — seat backend reference

Reference for kmshaunt's seat layer (ROADMAP M6.1 libseat backend, M6.2 multi-seat
daemon + fake VT, M6.5 locale1 XKB). Every signature, return value and protocol
step below is copied from the headers and sources of the exact versions pinned in
§0 — not from man pages or memory. Where a conclusion is derived rather than read
directly from code, it is marked `[INFERENCE]`.

---

## 0. Provenance and pins

All paths below were produced by the commands shown, on this workstation
(nixpkgs registry revision `f9a75f4`).

| Component | Version | Command | Dev output / source tree |
|---|---|---|---|
| seatd / libseat | **0.9.3** | `nix build nixpkgs#seatd.dev --print-out-paths --no-link` | dev `/nix/store/zazxxaxz9ym0v9cyfkm2mwianzip8c6z-seatd-0.9.3-dev`, lib `/nix/store/kchlliw1gc93fk9lm44jimh7dqdl4g9b-seatd-0.9.3` |
| seatd source | 0.9.3 | `nix build nixpkgs#seatd.src --print-out-paths --no-link` | `/nix/store/aqr4nyk6v9mb295d26y213pp4qxxyqz1-source` |
| systemd (sd-login, sd-bus, sd-event) | **262** | `nix build nixpkgs#systemd.dev --print-out-paths --no-link` | dev `/nix/store/gybvjdl14lbgym7958hkigsr3xwb4c7l-systemd-262-dev`, lib `/nix/store/avshcbcrykiffn4vlhmz848ab69wbp9n-systemd-262` |
| systemd source | 262 | `nix build nixpkgs#systemd.src --print-out-paths --no-link` | `/nix/store/hgvj3r5rf0hxx242vx92z8p6a0bzr3zf-source` |
| kmscon source | **10.1.0** | `nix build nixpkgs#kmscon.src --print-out-paths --no-link` | `/nix/store/87j2xajxjphwhla24iw4n9jpiy33av63-source` |

Version evidence:

- libseat 0.9.3: `seatd-0.9.3-dev/lib/pkgconfig/libseat.pc` →
  `Version: 0.9.3`, `Libs: -L${libdir} -lseat`, `Cflags: -I${includedir}`,
  `have_seatd=true`, `have_logind=true`, `have_builtin=true`.
- systemd 262: `systemd-262-dev/lib/pkgconfig/libsystemd.pc` → `Version: 262`,
  `Libs: -L${libdir} -lsystemd`, `Cflags: -I${includedir}`.
- kmscon 10.1.0: `nix eval --raw nixpkgs#kmscon.version` → `10.1.0`;
  `nix eval --json nixpkgs#kmscon.mesonFlags` → `["-Dlibseat=enabled"]`, i.e. the
  packaged build **does** include the libseat VT backend even though meson's
  default is `disabled` (`meson.options:8-10`).

### Citation convention

| Citation | Resolves to |
|---|---|
| `libseat.h:N` | `…-seatd-0.9.3-dev/include/libseat.h` |
| `include/*.h:N`, `libseat/**`, `seatd/**`, `common/**` | seatd 0.9.3 source tree |
| `sd-login.h:N`, `sd-bus.h:N`, `sd-event.h:N` | `…-systemd-262-dev/include/systemd/` |
| `libsystemd/**`, `login/**`, `locale/**`, `man/**` | systemd 262 source tree |
| `src/**` | kmscon 10.1.0 source tree |

The libseat header installs **flat**: `…-dev/include/libseat.h`, so the include
is `#include <libseat.h>`. There is no `libseat/libseat.h` (verified: the dev
output contains exactly `include/libseat.h`, `lib/pkgconfig/libseat.pc`,
`nix-support/propagated-build-inputs`).

### Quick facts

| Question | Answer | Evidence |
|---|---|---|
| Is there a `dummy` backend? | **No.** The names are `seatd`, `logind`, `builtin`, `noop` | `libseat/libseat.c:18-31` |
| Is `noop` ever auto-selected? | **No**, it is skipped in the fallback loop | `libseat/libseat.c:67-70` |
| Default libseat log level | `LIBSEAT_LOG_LEVEL_SILENT` — you get no diagnostics unless you opt in | `common/log.c:15` |
| Default seatd socket | `/run/seatd.sock`, override with `SEATD_SOCK` | `meson.build:20-22`, `libseat/backend/seatd.c:55-58` |
| Does `sd_pid_get_seat()` exist? | **No** in systemd 262 (no such symbol; compose `sd_pid_get_session` + `sd_session_get_seat`) | no symbol in `sd-login.h` nor `libsystemd/sd-login/` |
| locale1 interface / path | `org.freedesktop.locale1` / `/org/freedesktop/locale1` | `locale/localed.c:586-590` |
| locale1 XKB properties | `X11Layout`, `X11Model`, `X11Variant`, `X11Options`, all type `s` | `locale/localed.c:560-563` |
| Can plain seatd serve `seat1`? | **No.** The server only ever creates `seat0` | `seatd/server.c:42-45`, `seatd/client.c:159-160` |

### kmshaunt state at the time of writing

- `src/seat/` does not exist yet; nothing in `src/` calls libseat or sd-login.
- `build.zig` links only the libghostty-vt artifact (`build.zig:1-40`); no system
  library is linked, `translateC` is used only for `src/vt-c.h`.
- `deps.nix` is **empty (0 bytes)**. M6 needs it to export, at minimum:
  `seatd.dev` (headers) + `seatd` (libseat.so) and `systemd.dev` + `systemd`
  (libsystemd.so). Neither is currently wired.

---

## 1. What kmshaunt needs, and from where

| ROADMAP item | Need | API |
|---|---|---|
| M6.1 libseat backend | acquire/release seat, device fds, VT switching | libseat 0.9.3 (`<libseat.h>`, `-lseat`) |
| M6.2 multi-seat daemon | which seats exist, which is active, wake on change | `sd_get_seats`, `sd_seat_get_active`, `sd_login_monitor_new("seat")` |
| M6.2 fake VT | activate/deactivate a seat with no kernel VT | kmscon's model, §6.7 |
| M6.5 xkb from locale1 | initial RMLVO + live updates | sd-bus `Properties.Get` + `PropertiesChanged` |

Intended module split (matches `ROADMAP.md:70-79`):

```
src/seat/libseat.zig   thin, typed wrapper over libseat 0.9.3  (§2, §3)
src/seat/vt_real.zig   VT_PROCESS/VT_RELDISP owner            (§6.6)
src/seat/vt_fake.zig   no-VT seats                            (§6.7)
src/seat/multiseat.zig sd-login enumeration + monitor         (§4)
src/misc/locale1.zig   sd-bus client for org.freedesktop.locale1 (§5)
```

Division of responsibility that the sources force (do not blur it):

- **seat layer** owns: libseat handle, listener, device (fd, id) pairs, VT
  fd + KD/VT ioctls, enable/disable state machine.
- **video layer** owns DRM master: kmscon calls `drmSetMaster`/`drmDropMaster`
  in its video wake/sleep paths (`video/drm_shared.c:1227-1246`, `1560`,
  `1593`), not in the seat layer.

---

## 2. libseat 0.9.3 — API surface

### 2.1 Compile and link

```
-I <seatd-dev>/include
-L <seatd-lib>/lib            # contains libseat.so, libseat.so.1
-lseat
#include <libseat.h>
```

`libseat.pc` reports `Requires.private: libsystemd` and `Libs.private: -lrt` —
for a static link add both; for the normal shared link `-lseat` suffices
(`libseat.so.1` is expected to carry the DT_NEEDED entries `[INFERENCE]`). The
header includes `<stdarg.h>` only because of the log-handler typedef
(`libseat.h:4`).

### 2.2 Exact declarations

| Symbol | Exact declaration | Header line |
|---|---|---|
| opaque handle | `struct libseat;` | `libseat.h:10` |
| listener | see below | `libseat.h:15-36` |
| open | `struct libseat *libseat_open_seat(const struct libseat_seat_listener *listener, void *userdata);` | `libseat.h:60` |
| ack disable | `int libseat_disable_seat(struct libseat *seat);` | `libseat.h:69` |
| close | `int libseat_close_seat(struct libseat *seat);` | `libseat.h:76` |
| open device | `int libseat_open_device(struct libseat *seat, const char *path, int *fd);` | `libseat.h:90` |
| close device | `int libseat_close_device(struct libseat *seat, int device_id);` | `libseat.h:98` |
| seat name | `const char *libseat_seat_name(struct libseat *seat);` | `libseat.h:107` |
| switch session | `int libseat_switch_session(struct libseat *seat, int session);` | `libseat.h:119` |
| poll fd | `int libseat_get_fd(struct libseat *seat);` | `libseat.h:127` |
| dispatch | `int libseat_dispatch(struct libseat *seat, int timeout);` | `libseat.h:140` |
| log level enum | `enum libseat_log_level { SILENT=0, ERROR=1, INFO=2, DEBUG=3, LAST };` | `libseat.h:145-151` |
| log callback type | `typedef void (*libseat_log_func)(enum libseat_log_level level, const char *format, va_list args);` | `libseat.h:156` |
| log handler | `void libseat_set_log_handler(libseat_log_func handler);` | `libseat.h:165` |
| log level | `void libseat_set_log_level(enum libseat_log_level level);` | `libseat.h:173` |

The listener, verbatim (`libseat.h:15-36`):

```c
struct libseat_seat_listener {
	/* enable_seat comment: "Re-open all seat devices to ensure that they are
	 * operational, as existing fds may have had their functionality blocked or
	 * revoked." Must be non-NULL. */
	void (*enable_seat)(struct libseat *seat, void *userdata);   /* :23 */

	/* disable_seat comment: "The event *must* be acknowledged with
	 * libseat_disable_seat shortly after receiving this event. If the recepient
	 * fails to acknowledge the event in time, seat devices may be forcibly
	 * revoked by the seat provider." Must be non-NULL. */
	void (*disable_seat)(struct libseat *seat, void *userdata);  /* :35 */
};
```

Both members are mandatory: `libseat_open_seat` rejects a NULL listener or a
NULL member with `errno = EINVAL` (`libseat/libseat.c:38-41`). There is no ABI
version macro in the header; the pkg-config version (0.9.3) is the only version
signal.

### 2.3 Return conventions

- Functions returning `int` return `0`/positive on success, `-1` with `errno`
  set on error (`libseat.h:67`, `:74`, `:88`, `:96`, `:117`, `:125`,
  `:137-138`).
- `libseat_open_seat` returns `NULL` and sets `errno` (`libseat.h:57-58`).
- `libseat_open_device` returns the **device id** (>= 0) on success and stores
  the fd in the `int *fd` out-parameter; `-1` + `errno` on error
  (`libseat.h:88`).
- `libseat_dispatch` returns **> 0 = processed internal messages**, `0 = nothing
  done`, `-1` + `errno` on error (`libseat.h:137-138`).
- `libseat_seat_name` returns a string owned by the instance, valid while the
  seat is open, must not be modified (`libseat.h:104-105`).

### 2.4 Backend selection

Compile-time table and runtime selection, from `libseat/libseat.c`:

```c
static const struct named_backend impls[] = {
#ifdef SEATD_ENABLED
	{"seatd", &seatd_impl},        /* :20 */
#endif
#ifdef LOGIND_ENABLED
	{"logind", &logind_impl},      /* :23 */
#endif
#ifdef BUILTIN_ENABLED
	{"builtin", &builtin_impl},    /* :26 */
#endif
	{"noop", &noop_impl},          /* :28 */
	{NULL, NULL},
};
```

- `LIBSEAT_BACKEND` is read with `getenv` at open time (`libseat.c:45`).
  The value must equal one of the four names **exactly**; an unknown value logs
  `No backend matched name '…'` and fails with `errno = EINVAL`
  (`libseat.c:46-53`). A backend that is not compiled in simply is not in the
  table, so selecting it yields the same `EINVAL`.
- With no environment variable, the list is tried in order `seatd`, `logind`,
  `builtin`, and `noop` is **skipped** (`libseat.c:67-70`). If all fail:
  `errno = ENOSYS` (`libseat.c:79-81`).
- nixpkgs' seatd 0.9.3 has all three real backends compiled in
  (`have_seatd`, `have_logind`, `have_builtin` in `libseat.pc`), so on NixOS the
  auto order is: connect to `/run/seatd.sock` → else logind D-Bus → else
  embedded server.

| Backend | Requires at runtime | Seat served | `libseat_switch_session` |
|---|---|---|---|
| `seatd` | reachable seatd socket (`SEATD_SOCK` or `/run/seatd.sock`), ACL/group | always the seat the daemon has: `seat0` only | real VT switch when the seat is VT-bound |
| `logind` | system bus + logind, process in a session | the seat of **your session** (`sd_session_get_seat`) | `Seat.SwitchTo` |
| `builtin` | permission to open the seat's devices *and* to `drmSetMaster(3)` at open time (`libseat.h:44-53`); typically root | `seat0` (it forks the same seatd server) | as `seatd` |
| `noop` | nothing; only reachable explicitly | reports `"seat0"` | fails (`-1`) |

`builtin` mechanics: `socketpair(AF_UNIX, SOCK_STREAM|SOCK_NONBLOCK|SOCK_CLOEXEC)`
+ `fork()`; the child runs an embedded seatd server
(`server_init`/`server_add_client`), the parent reuses `_open_seat` on the other
socket end (`libseat/backend/seatd.c:677-737`). Consequence for kmshaunt: the
process forks **after** you may have created an sd-bus connection; anything the
child touches would hit the `-ECHILD` fork guard of sd-bus (§5.6). The child in
libseat only runs the seatd loop and `exit()`s, so keep the child free of Zig
allocators/atexit work.

`noop` (`libseat/backend/noop.c`) exists for tests: `seat_name()` is the
constant `"seat0"` (`noop.c:47-50`), `open_device` is a plain
`open(path, O_RDWR|O_NOCTTY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)` (`noop.c:52-63`),
`device_id` is that fd, `close_device` does nothing (`noop.c:65-69`),
`disable_seat` does nothing (`noop.c:42-45`), `switch_session` fails with a log
(`noop.c:71-76`), and `dispatch` calls `enable_seat` once on the first call then
polls a dummy socketpair (`noop.c:83-112`, `:106-124`, impl `:126-135`).

### 2.5 Device ids: never assume `id == fd`

| Backend | `device_id` | fd | `close_device` |
|---|---|---|---|
| seatd/builtin | opaque id ≥ 1 allocated by the server, sent with the fd over `SCM_RIGHTS` (`seatd/client.c:221-258`, `seatd/seat.c:352-366`) | a dup of the seatd-owned fd | decrements the server refcount; at 0 the device is deactivated and closed (`seatd/seat.c:480-510`) |
| logind | **the fd itself** — `open_device` returns `tmpfd` and writes `*fd = tmpfd` (`libseat/backend/logind.c:145-151`) | a `F_DUPFD_CLOEXEC` of the fd received from `TakeDevice` | `fstat(device_id)` → `ReleaseDevice(major,minor)` (`logind.c:154-186`) |
| noop | the fd | the fd | no-op |

So kmshaunt must store the pair `{ fd, device_id }` per device and pass the id
to `libseat_close_device`, then `close(fd)` itself — exactly what kmscon does
(`src/uterm/vt_libseat.c:329-338`: `libseat_close_device(...); close(fd);`).
Closing the fd without closing the id leaks the seatd entry (refcount stays 1
until process exit).

Two more server-side facts that shape the API:

- Re-opening the same canonical path returns the **same** device id and the same
  file description, with the refcount incremented (`seatd/seat.c:350-360`,
  reply path `seatd/client.c:236-241`). Config reloads must not blindly
  re-open an already-open path.
- Supported device classes are only evdev, DRM, hidraw, wscons
  (`seatd/seat.c:329-349`); anything else fails with `ENOENT`.

---

## 3. The enable/disable protocol

### 3.1 The contract

From `libseat.h:16-36` and `:62-68`:

1. `disable_seat` means *you are about to lose the seat*. You must stop using
   seat devices and you must acknowledge with `libseat_disable_seat()`, or the
   provider may revoke your fds by force.
2. After `libseat_disable_seat()` returns, every seat request fails until
   `enable_seat` arrives; seat devices must not be used in that window.
3. `enable_seat` means *the seat is yours again*; existing fds may have been
   blocked or revoked, so devices must be re-opened.

### 3.2 What the seatd server does (server side, authoritative)

The server has a per-client state machine: `CLIENT_NEW` → `CLIENT_ACTIVE` →
`CLIENT_PENDING_DISABLE` → `CLIENT_DISABLED` (`seatd/client.c`, `seatd/seat.c`).

Disable sequence for session switch (`seatd/seat.c:593-623`, in this order):

1. For every open device of the active client, `seat_deactivate_device()`:
   - DRM → `DRM_IOCTL_DROP_MASTER` (`common/drm.c`, `seat.c:448-451`)
   - evdev → `EVIOCREVOKE` (`common/evdev.c:24-26`, `seat.c:453-457`)
   - hidraw → `HIDIOCREVOKE` (`seat.c:459-463`)
     Comment: *"We cannot just close them is that certain device fds, such as for
     DRM, must maintain the exact same file description for their contexts to
     remain valid."* (`seat.c:601-606`)
2. `client->state = CLIENT_PENDING_DISABLE`.
3. Send `SERVER_DISABLE_SEAT` (`seat.c:614-620`, `client.c:445-455`).

Ack handling (`seatd/client.c:312-335`, `seatd/seat.c:631-657`):

4. `CLIENT_DISABLE_SEAT` → `seat_ack_disable_client()` → state
   `CLIENT_DISABLED`, reply `SERVER_SEAT_DISABLED`, then
   `seat_activate()` picks the next client (queued `next_client`, the client on
   the current VT, or the first client) and sends it `SERVER_ENABLE_SEAT`.
5. If you never ack, the switch never completes: a VT-bound seat refuses a new
   `CLIENT_OPEN_SEAT` while it still has an active client that is not pending
   disable (`EBUSY`, `seat.c:198-204`), and the queued next client never
   becomes active.

Enable on open: `handle_open_seat` writes `SERVER_SEAT_OPENED` **first**, then
calls `seat_open_client`, which sends `SERVER_ENABLE_SEAT`
(`seatd/client.c:184-197`, `seatd/seat.c:542-586`). Because libseat's
`read_until_response` stops as soon as it sees `SERVER_SEAT_OPENED`
(`libseat/backend/seatd.c:303-327`), the enable event is delivered on the
**next** `libseat_dispatch`, not inside `libseat_open_seat`. kmscon relies on
this: after connecting it immediately calls `libseat_dispatch(seat, 0)`
specifically to drain the queued enable (`src/uterm/vt_libseat.c:226-233`).

VT-bound seats (the default, `SEATD_VTBOUND` unset or `"1"`,
`seatd/server.c:42-45`):

- The client's `session` is the **current VT number** at `CLIENT_OPEN_SEAT`
  time (`seat.c:212-232`), so `libseat_switch_session(seat, n)` is
  "activate VT n" (`seat.c:686-694`).
- On open the server does `vt_open(session)`: open `/dev/ttyN`, set
  `VT_PROCESS`, keyboard `K_OFF`, `KD_GRAPHICS` (`seat.c:77-90`,
  `common/terminal.c:154-166`, `:195-211`, `:243-268`, `:270-280`).
- On final close it does `vt_close`: keyboard back to `K_UNICODE`,
  `KD_TEXT` (`seat.c:92-105`).

### 3.3 libseat's seatd client path

- `libseat_dispatch` (`libseat/backend/seatd.c:329-372`):
  1. `read_and_queue()` parses complete packets; `SERVER_ENABLE_SEAT` /
     `SERVER_DISABLE_SEAT` are pushed onto a pending-event list
     (`seatd.c:231-268`), `SERVER_PONG` clears `awaiting_pong`.
  2. `execute_events()` runs the listener callbacks in order
     (`seatd.c:200-229`).
  3. Before blocking, it runs `read_and_queue` once without waiting, then
     either reads immediately (if something was dispatched or `timeout == 0`)
     or `poll()`s. Result: no blocking if there was work.
- `libseat_disable_seat` on seatd performs a **blocking round trip**: send
  `CLIENT_DISABLE_SEAT`, then `read_until_response()` until
  `SERVER_SEAT_DISABLED` (`seatd.c:636-660`). Calling it from inside the
  `disable_seat` callback is therefore legal and expected (kmscon does exactly
  that, `vt_libseat.c:142-151`); the call re-enters socket I/O but not
  `execute_events`, so there is no recursion into your callbacks.
- Wake-up trick: if a background event becomes pending during a blocking
  request (`open_device`, `close_device`, `switch_session`, `disable_seat`), the
  client sends `CLIENT_PING` so the app's poll wakes up even though the socket
  was already drained (`seatd.c:489-519`). Your epoll must therefore stay
  registered and must tolerate `libseat_dispatch` returning `0` after a ping.
- Every blocking request ends with `check_pending_events()` (`seatd.c:556`,
  `:592`, `:628`, `:655`).

### 3.4 libseat's logind path

Open (`libseat/backend/logind.c:652-710`):
`get_display_session` (`XDG_SESSION_ID` → `sd_pid_get_session(getpid())` →
`sd_uid_get_display(getuid())`, `logind.c:607-650`) →
`sd_session_get_seat` → `sd_bus_default_system` → `Manager.GetSession` /
`Manager.GetSeat` for object paths → two signal matches → read `Active` →
`Session.TakeControl(false)` → optional `Session.SetType($XDG_SESSION_TYPE)`.

Matches installed (`logind.c:520-543`):

```c
sd_bus_match_signal(bus, NULL, "org.freedesktop.login1", session_path,
                    "org.freedesktop.login1.Session", "PauseDevice",
                    /* on_pause_device, userdata */);
sd_bus_match_signal(bus, NULL, "org.freedesktop.login1", session_path,
                    "org.freedesktop.DBus.Properties", "PropertiesChanged",
                    /* on_props_changed, userdata */);
```

Disable is triggered from **two** sources:

1. `PauseDevice(u,u,s)` with type `"pause"` → the backend calls
   `set_active(session,false)` → your `disable_seat` → then it immediately sends
   `Session.PauseDeviceComplete(u,u)` (`logind.c:363-405`). The source admits
   the ordering is optimistic: *"let's assume that running the disable_seat
   handler will close everything immediately. The 'right' thing to do is to
   queue up pause completions until the seat user called disable_seat"*
   (`logind.c:388-395`). Type `"gone"` is ignored; type `"force"` relies on the
   coming `Active=false` property change.
2. `PropertiesChanged` on `org.freedesktop.login1.Session` with `Active=false`
   (value present or listed in the invalidated array, `logind.c:408-508`).

`libseat_disable_seat` on logind is a **no-op that returns 0**
(`logind.c:215-218`). Your ack obligation is already satisfied by
libseat's `PauseDeviceComplete`; you still must close/stop using devices before
returning from the callback.

Enable: `initial_setup` is set at open (`logind.c:704`) and the **first**
`libseat_dispatch` invokes `enable_seat` or `disable_seat` depending on the
session's `Active` state (`logind.c:252-262`). Subsequent transitions come from
the `Active` property. `libseat_switch_session` → `Seat.SwitchTo(u)`
(`logind.c:188-213`). `libseat_close_seat` → `Session.ReleaseControl()`
(`logind.c:718-723`).

`libseat_get_fd` on logind returns `sd_bus_get_fd()` or `-1` with `errno`
(`logind.c:220-229`); `libseat_dispatch` drains `sd_bus_process` in a loop and
polls only when nothing was dispatched and `timeout != 0` (`logind.c:252-282`).

### 3.5 What kmshaunt must do — normative checklist

Disable (inside `disable_seat`):

1. Stop using the seat: cancel page flips, stop input processing, drop the
   current frame. kmscon does `vt_cb_deactivate` (display sleep, terminal
   deactivate) then `tty_deactivate` (`vt_libseat.c:142-151`).
2. Restore your own VT if you manage one: `KDSKBMODE` back to the saved mode,
   `KDSETMODE KD_TEXT` (`vt_libseat.c:122-130`). seatd does this server-side for
   VT-bound seats, but **logind does not** — kmscon does it unconditionally
   precisely because "Some libseat backends (elogind/logind) do not set K_OFF"
   (`vt_libseat.c:104-120`).
3. For every **evdev/hidraw** device: `libseat_close_device(seat, id)` then
   `close(fd)`. Do **not** merely keep the fd — the server cannot re-activate
   evdev/hidraw (`seat_activate_device` returns `-EINVAL` for both,
   `seatd/seat.c:509-527`), and `EVIOCREVOKE` permanently kills that file
   description.
4. For **DRM**: either keep `{fd,id}` (seatd re-runs `DRM_IOCTL_SET_MASTER` on
   the same file description at enable, `seatd/seat.c:511-519`) **or** close id
   + fd and re-open later. Never `libseat_open_device()` a DRM path you did not
   close: the server reuses the entry and bumps the refcount
   (`seatd/seat.c:350-360`), leaking a reference.
5. Call `libseat_disable_seat(seat)` and check the result. On seatd this blocks
   until the server confirms; on logind it is a no-op. Do not call it *after*
   returning from the callback, and do not call it twice.
6. Do not touch seat devices until `enable_seat`; do not call seat APIs from
   other threads concurrently with dispatch.

Enable (inside `enable_seat`):

1. Re-open evdev/hidraw through `libseat_open_device` (new ids), then re-open
   the input devices in libinput/xkb layer. kmscon's retry loop exists because
   udev notices devices faster than the seat manager claims them:
   `ENODEV|EACCES|EBUSY` retried up to 20×100 ms (`vt_libseat.c:297-313`).
2. Re-acquire DRM master if you closed the fd, and re-program the mode: with
   seatd the existing fd is already master; with logind kmshaunt's DRM layer
   must call `drmSetMaster` itself (kmscon: `video/drm_shared.c:1227-1246`).
3. Re-apply your VT mode (`KD_GRAPHICS`, `K_OFF`) on the tty fd for logind.
4. Resume rendering/input and mark the seat enabled.
5. Be prepared for `enable_seat` to arrive on the **first dispatch after**
   `libseat_open_seat` (seatd) or on the first dispatch ever (logind). Store
   the handle and set an `enabled` flag before dispatching, then drain with
   `libseat_dispatch(seat, 0)` inside your open path.

Other rules:

- `libseat_dispatch` timeout: `0` = never block, `-1` = block indefinitely,
  `>0` = at most that many **milliseconds** (`libseat.h:132-138`). In an epoll
  loop use `0` when the fd is readable and `-1` only if the seat is your only
  event source.
- `libseat_open_seat` may legitimately fail with `EBUSY` when another client is
  mid-disable; kmscon retries 50×100 ms on `EBUSY`/`EBADF`
  (`vt_libseat.c:166-196`). Treat `EBUSY` as transient.
- Set a log handler/level explicitly; default is `SILENT` (`common/log.c:15`).
- `libseat_get_fd` must be re-read after `libseat_open_seat` only; it is stable
  afterwards for both seatd and logind.

### 3.6 Zig skeleton (0.17)

```zig
pub const libseat = opaque {};

pub const SeatListener = extern struct {
    enable_seat: *const fn (seat: ?*libseat, userdata: ?*anyopaque) callconv(.c) void,
    disable_seat: *const fn (seat: ?*libseat, userdata: ?*anyopaque) callconv(.c) void,
};

extern fn libseat_open_seat(l: *const SeatListener, userdata: ?*anyopaque) ?*libseat;
extern fn libseat_close_seat(s: *libseat) c_int;
extern fn libseat_disable_seat(s: *libseat) c_int;
extern fn libseat_open_device(s: *libseat, path: [*:0]const u8, fd: *c_int) c_int;
extern fn libseat_close_device(s: *libseat, id: c_int) c_int;
extern fn libseat_seat_name(s: *libseat) [*:0]const u8;
extern fn libseat_switch_session(s: *libseat, session: c_int) c_int;
extern fn libseat_get_fd(s: *libseat) c_int;
extern fn libseat_dispatch(s: *libseat, timeout: c_int) c_int;

// errno is per-thread C errno; std.c.errno() maps -1 to std.posix.E.
//   const e = std.c.errno(rc);            // std/c.zig:76-78
//   if (e == .BUSY) ...                   // tags: .BUSY .NODEV .ACCES .AGAIN .INVAL .NOSYS
```

The listener struct must be `extern struct` (C layout; two pointers, no
padding). Keep the `SeatListener` alive for the whole seat lifetime — libseat
stores the pointer, it does not copy it (`seatd.c:385-386`).

---

## 4. sd-login (systemd 262)

### 4.1 Header and conventions

`#include <systemd/sd-login.h>`; link `-lsystemd`. `sd-login.h:22-35` states the
contract for the whole API:

- empty result sets may be `NULL` instead of an empty array;
- returned strings/arrays are allocated with `malloc` and must be freed with
  `free()` — array *and* each string, arrays are `NULL`-terminated;
- errors are negative errno, success is `0` or positive;
- data comes from `/proc`, `/sys/fs/cgroup` and `/run` and is cheap to read.

This differs from libseat (which returns `-1` + `errno`); the Zig wrapper must
not mix the two conventions.

### 4.2 Functions kmshaunt needs

| Purpose | Exact declaration | Line |
|---|---|---|
| enumerate seats | `int sd_get_seats(char ***ret_seats);` | `sd-login.h:232` |
| enumerate sessions | `int sd_get_sessions(char ***ret_sessions);` | `sd-login.h:236` |
| active session of a seat | `int sd_seat_get_active(const char *seat, char **ret_session, uid_t *ret_uid);` | `sd-login.h:205` |
| all sessions of a seat | `int sd_seat_get_sessions(const char *seat, char ***ret_sessions, uid_t **ret_uids, unsigned *ret_n_uids);` | `sd-login.h:209-213` |
| session of this process | `int sd_pid_get_session(pid_t pid, char **ret_session);` | `sd-login.h:48` |
| seat of a session | `int sd_session_get_seat(const char *session, char **ret_seat);` | `sd-login.h:169` |
| VT of a session | `int sd_session_get_vt(const char *session, unsigned *ret_vtnr);` | `sd-login.h:202` |
| session active? | `int sd_session_is_active(const char *session);` | `sd-login.h:148` |
| seats of a uid | `int sd_uid_get_seats(uid_t uid, int require_active, char ***ret_seats);` | `sd-login.h:145` |
| monitor | `int sd_login_monitor_new(const char *category, sd_login_monitor **ret);` | `sd-login.h:251` |
| monitor free | `sd_login_monitor* sd_login_monitor_unref(sd_login_monitor *m);` | `sd-login.h:254` |
| drain | `int sd_login_monitor_flush(sd_login_monitor *m);` | `sd-login.h:257` |
| fd | `int sd_login_monitor_get_fd(sd_login_monitor *m);` | `sd-login.h:260` |
| poll mask | `int sd_login_monitor_get_events(sd_login_monitor *m);` | `sd-login.h:263` |
| timeout | `int sd_login_monitor_get_timeout(sd_login_monitor *m, uint64_t *ret_timeout_usec);` | `sd-login.h:266` |

Result semantics that matter:

- `sd_get_seats` / `sd_get_sessions` return the **count** (positive) or `0`
  when `/run/systemd/seats` / `…/sessions` does not exist (they then set the
  out-array to `NULL`) and never `-ENOENT` (`libsystemd/sd-login/sd-login.c:988-1010`).
- `sd_seat_get_active` returns `-ENXIO` when the seat has no state file,
  `-ENODATA` when the seat exists but has no active session / no uid
  (`sd-login.c:854-886`). Handle both as "no active session", not as fatal.
- `sd_seat_get_sessions` parses the `SESSIONS=`/`UIDS=` lines of the seat file;
  same `-ENXIO` convention (`sd-login.c:888-933`).
- There is **no** `sd_pid_get_seat` and **no** `sd_get_seat_name`. For the
  current seat use `sd_pid_get_session(getpid(), &sid)` +
  `sd_session_get_seat(sid, &seat)` — the same two-call composition libseat's
  logind backend uses (`libseat/backend/logind.c:607-676`).

### 4.3 The monitor is an inotify fd

`sd_login_monitor_new` is a thin inotify wrapper — this is the whole
implementation (`libsystemd/sd-login/sd-login.c:1183-1218`):

```c
fd = inotify_init1(IN_NONBLOCK|IN_CLOEXEC);
categories[] = {
    { "seat",     "/run/systemd/seats/"    },
    { "session",  "/run/systemd/sessions/" },
    { "uid",      "/run/systemd/users/"    },
    { "machine",  "/run/systemd/machines/" },
};
inotify_add_watch(fd, c->path, IN_MOVED_TO|IN_DELETE);
```

- `category == NULL` installs **all four** watches; a named category installs
  one; an unknown category returns `-EINVAL`; a missing directory returns the
  inotify error (`-ENOENT`).
- The returned object is the fd encoded as `fd+1` (`sd-login.c:1175-1181`), so
  `sd_login_monitor_get_fd()` is just the raw fd.
- `sd_login_monitor_get_events()` always returns `POLLIN`
  (`sd-login.c:1246-1255`); `sd_login_monitor_get_timeout()` always returns
  `UINT64_MAX` (`sd-login.c:1257-1267`). There is no timer to integrate.
- `sd_login_monitor_flush()` drains the fd (`flush_fd`, `sd-login.c:1227-1236`);
  call it every time the fd is readable, otherwise epoll stays hot.

Why `IN_MOVED_TO` also fires on *content* changes: logind writes seat state
atomically — `fopen_tmpfile_linkable()` into `/run/systemd/seats/<seat>`, then
`flink_tmpfile(..., LINK_TMPFILE_REPLACE)` (`login/logind-seat.c:101-166`,
rename at `:164`), and calls `seat_save()` on session add/remove and on
`ActiveSession` changes (`login/logind-seat.c:235-236`, `:438`,
`login/logind-session.c:939-949`). So a `"seat"` monitor fires for both seat
creation and active-session changes `[INFERENCE from the atomic-replace write +
IN_MOVED_TO watch]`.

### 4.4 epoll integration recipe

1. `sd_login_monitor_new("seat", &mon)`; `sd_login_monitor_get_fd(mon)`.
2. `epoll_ctl(ADD, fd, EPOLLIN, tag_seat_monitor)`.
3. On readable: `sd_login_monitor_flush(mon)` **first** (drains all events), then
   re-enumerate: `sd_get_seats(&seats)` → for each seat
   `sd_seat_get_active(seat, &sess, &uid)`; diff against your per-seat
   instance table.
4. For each changed seat: start/stop a seat worker; for the active seat, use
   `sd_session_get_vt(sess, &vtnr)` to know which VT should be foregrounded.
5. `sd_login_monitor_unref(mon)` at shutdown (it just `close()`s the fd).

Latency/robustness note: the monitor tells you *that* something changed, never
*what*. Every wake-up costs one directory read plus one file read per seat.
If you need the exact old/new session, add a logind match on
`org.freedesktop.login1.Seat` `PropertiesChanged` (`ActiveSession` is
`SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE`, `login/logind-seat-dbus.c:403`) or
`Manager.SessionNew`/`SessionRemoved` (`login/logind-dbus.c:4215-4220`), which
is what `loginctl` does.

---

## 5. locale1 over sd-bus (M6.5)

### 5.1 What localed exposes

| Item | Value | Evidence |
|---|---|---|
| Bus | system | `locale/localed.c:592-600` (`connect_bus`) |
| Name | `org.freedesktop.locale1` | `locale/localed.c:587-589` |
| Object path | `/org/freedesktop/locale1` | `locale/localed.c:587` |
| Interface | `org.freedesktop.locale1` | `locale/localed.c:588` |
| `X11Layout` | `s` | `localed.c:560` |
| `X11Model` | `s` | `localed.c:561` |
| `X11Variant` | `s` | `localed.c:562` |
| `X11Options` | `s` | `localed.c:563` |
| Also emitted | `VConsoleKeymap`, `VConsoleKeymapToggle` (`s`), `Locale` (`as`) | `localed.c:559-565` |

Property getter: `property_get_xkb` returns the stored string verbatim
(`localed.c:91-126`); an unset value is the **empty string**, not an error, so
kmshaunt must treat `""` as "unset" and fall back to its own defaults.
`Set*` methods are polkit-guarded (`org.freedesktop.locale1.set-keyboard`,
`set-locale`; `localed.c:280`, `:385`, `:505`). The property getters themselves
are not polkit-guarded (`property_get_xkb`, `localed.c:91-126`). All four
properties are declared `SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE`, and
`SetX11Keyboard` emits them together:

```c
sd_bus_emit_properties_changed(bus, "/org/freedesktop/locale1",
        "org.freedesktop.locale1",
        "X11Layout", "X11Model", "X11Variant", "X11Options",
        /* plus VConsoleKeymap... */);                    /* localed.c:542-549 */
```

### 5.2 Startup read (one shot)

Two equivalent options; prefer the first for simplicity:

**(a) Four convenience calls** (`sd_bus_get_property_string`, `sd-bus.h:277`):

```c
char *v = NULL;
sd_bus_get_property_string(bus, "org.freedesktop.locale1",
        "/org/freedesktop/locale1", "org.freedesktop.locale1",
        "X11Layout", &err, &v);   /* v: malloc'd, free() it */
```

`sd_bus_get_property_string` is declared with the comment `/* free the result! */`
(`sd-bus.h:277`); failure leaves `v` untouched, and `sd_bus_error_free(&err)`
releases the error (`sd-bus.h:361`).

**(b) One round trip** with `Properties.GetAll`:
`org.freedesktop.DBus.Properties.GetAll("org.freedesktop.locale1")` →
reply signature `a{sv}`; walk it with the container calls in §5.4. Get/GetAll
signatures per the D-Bus spec: `Get(ss) → v`, `GetAll(s) → a{sv}`.

Do not fail hard if localed is missing (containers, minimal images): a
`ServiceUnknown`/`NameHasNoOwner` error means "no locale1", and kmshaunt then
keeps the `XKB_DEFAULT_*` environment or its config values — exactly how kmscon
treats a missing locale1 (`src/misc/dbus.c:125-138` sets `XKB_DEFAULT_*` from locale1 and only logs on
failure, wired at `src/main.c:149-152`).

### 5.3 Live follow — exact match rule

Two shapes, in decreasing order of precision:

```c
/* 1. exact, recommended: filter on arg0 = the changed interface */
static const char *match =
    "type='signal',"
    "sender='org.freedesktop.locale1',"
    "path='/org/freedesktop/locale1',"
    "interface='org.freedesktop.DBus.Properties',"
    "member='PropertiesChanged',"
    "arg0='org.freedesktop.locale1'";

sd_bus_add_match(bus, &slot, match, on_props_changed, userdata);   /* sd-bus.h:140 */

/* 2. same thing without a string (no arg0 filter; check arg0 yourself) */
sd_bus_match_signal(bus, &slot, "org.freedesktop.locale1",
                    "/org/freedesktop/locale1",
                    "org.freedesktop.DBus.Properties",
                    "PropertiesChanged", on_props_changed, userdata); /* sd-bus.h:309 */
```

Facts behind the exact string:

- `arg0` matching is a `dbus-daemon` match-rule feature and sd-bus parses
  `argN` itself (`libsystemd/sd-bus/bus-match.c:596-613`, `:981-993`) and also
  filters received messages locally (`bus_match_run` is called for every
  incoming message, `libsystemd/sd-bus/sd-bus.c:2919-2922`).
- The match string is sent verbatim to the broker as
  `org.freedesktop.DBus.AddMatch` and installed **synchronously**
  (`libsystemd/sd-bus/bus-control.c:965-1005`; man page: "installed
  synchronously when connected to a bus broker", `man/sd_bus_add_match.xml:98-100`).
  `sd_bus_add_match_async` is the non-blocking variant
  (`sd-bus.h:141`).
- kmscon 10.1 uses libdbus, and its match rule is the same except for the
  `arg0` term: `type='signal',sender='org.freedesktop.locale1',
  path='/org/freedesktop/locale1',interface='org.freedesktop.DBus.Properties',
  member='PropertiesChanged'` (`src/misc/dbus.c:354-358`); it then checks
  `dbus_message_is_signal(msg,"org.freedesktop.DBus.Properties",
  "PropertiesChanged")` (`dbus.c:236-241`).

Ordering (prevents a lost update):

1. `sd_bus_default_system(&bus)`
2. `sd_bus_add_match(...)` — returns only after the broker confirmed
3. then read the current values (§5.2)

Installing the match *after* the read would drop a change that lands between the
two.

### 5.4 Parsing `PropertiesChanged`

Signal signature is `s a{sv} as` (interface, changed values, invalidated names).
sd-bus recipe, mirroring libseat's own logind handler
(`libseat/backend/logind.c:408-508`):

```c
const char *iface;
sd_bus_message_read_basic(m, 's', &iface);            /* sd-bus.h:241 */
if (strcmp(iface, "org.freedesktop.locale1") != 0)
    return 0;                                          /* not ours */

sd_bus_message_enter_container(m, 'a', "{sv}");        /* sd-bus.h:246 */
while ((r = sd_bus_message_enter_container(m, 'e', "sv")) > 0) {
    const char *name = NULL, *value = NULL;
    sd_bus_message_read_basic(m, 's', &name);
    r = sd_bus_message_enter_container(m, 'v', "s");   /* variant of string */
    if (r > 0) {
        sd_bus_message_read_basic(m, 's', &value);
        apply(name, value);
        sd_bus_message_exit_container(m);              /* sd-bus.h:247 */
    } else {
        sd_bus_message_skip(m, "v");                   /* not a string: ignore */
    }
    sd_bus_message_exit_container(m);                  /* leave the dict entry */
}
sd_bus_message_exit_container(m);                      /* leave a{sv} */

sd_bus_message_enter_container(m, 'a', "s");           /* invalidated names */
while ((r = sd_bus_message_read_basic(m, 's', &name)) > 0)
    refresh_property(name);                            /* re-Get it */
sd_bus_message_exit_container(m);
```

Notes:

- `sd_bus_message_enter_container(m, 'v', NULL)` is legal (systemd does it in
  `libsystemd/sd-bus/bus-convenience.c:560`); use it when you do not know the
  variant's type and then `sd_bus_message_peek_type` (`sd-bus.h:248`).
- A type mismatch returns a negative error; do not assume a specific code.
  Variants may hold anything, and `arg3` (invalidated) genuinely happens.
- Do not keep the borrowed `sd_bus_message *` past the callback
  (`man/sd_bus_add_match.xml:129-133`).
- Callback return: `0` = "let other matching callbacks run", negative = error,
  positive = stop (`man/sd_bus_add_match.xml:135-138`).

### 5.5 Raw epoll integration vs `sd_bus_attach_event`

`sd-bus` supports three I/O models (`man/sd_bus_get_fd.xml:95-107`). kmshaunt
already owns an epoll loop (`src/loop.zig`), so use the fd trio:

| Function | Meaning | Line |
|---|---|---|
| `int sd_bus_get_fd(sd_bus *bus);` | pollable fd; may be an internal inotify fd; `-ENOTCONN` before connect/after close, `-ECHILD` after `fork`, `-EPERM` if input≠output fd | `sd-bus.h:115`, impl `sd-bus.c:2570-2586` |
| `int sd_bus_get_events(sd_bus *bus);` | `POLLIN`/`POLLOUT` mask for the current state (running: `POLLIN` if no queued read, `POLLOUT` if write queue non-empty) | `sd-bus.h:116`, impl `sd-bus.c:2588-2632` |
| `int sd_bus_get_timeout(sd_bus *bus, uint64_t *ret);` | **absolute** CLOCK_MONOTONIC deadline in µs; `UINT64_MAX` = infinite; returns `1` if set, `0` if not, negative on error | `sd-bus.h:117`, impl `sd-bus.c:2634-2690`, doc `man/sd_bus_get_fd.xml:69-92` |
| `int sd_bus_process(sd_bus *bus, sd_bus_message **ret);` | dispatch one thing; call in a loop **until it returns 0** | `sd-bus.h:118`, `sd-bus.c:3349-3351` |
| `int sd_bus_wait(sd_bus *bus, uint64_t timeout_usec);` | blocking wait; returns `0` if there was already something to process, `1` on readiness | `sd-bus.h:120`, `sd-bus.c:3422-3450` |

Loop contract, quoting the implementation comment
(`sd-bus.c:3286-3290`): *"Returns 0 when we didn't do anything. This should
cause the caller to invoke sd_bus_wait() before returning the next time."*
Callbacks (matches, method replies) run inside `sd_bus_process`.

Correct epoll shape:

```
register: fd = sd_bus_get_fd(bus); events = sd_bus_get_events(bus);
          epoll_ctl(ADD, fd, events)
every iteration:
    mask = sd_bus_get_events(bus);            // may change (write queue drains)
    epoll_ctl(MOD, fd, mask) if mask != last
    if (sd_bus_get_timeout(bus, &remaining) == 0) remaining = UINT64_MAX;
    timeout_ms = remaining == UINT64_MAX ? -1 : ceil_div(remaining - now_us, 1000)
    n = epoll_wait(epfd, evs, timeout_ms)
    if (bus fd fired || timeout_ms == 0) {
        while (sd_bus_process(bus, NULL) > 0) {}
    }
```

Alternative: `sd_bus_attach_event(bus, sd_event, priority)` (`sd-bus.h:129`)
attaches the connection to an **sd-event** loop (`sd_event_new` /
`sd_event_loop`, `sd-event.h:85`, `:107`). That means adopting a second event
loop (`sd_event_add_io`, `sd-event.h:88`) next to kmshaunt's epoll loop — not
worth it unless the whole daemon moves to sd-event.

### 5.6 Lifecycle and errors

- `sd_bus_default_system()` returns a **per-thread shared** connection with an
  incremented refcount (`man/sd_bus_default.xml:114-127`); the same thread gets
  the same object. Drop the reference with `sd_bus_flush_close_unref(bus)`
  (`sd-bus.h:98`) or `sd_bus_unref`.
- All bus objects are fork-hostile: after `fork()` the child sees `-ECHILD`
  (`sd-bus.h` impl `sd_bus.c:2574` guard, documented in
  `man/sd_bus_get_fd.xml:132-134`). If you ever use libseat's `builtin`
  backend, it forks — keep the child innocent.
- Everything returns negative errno; there is no `errno` side channel.
- Errors of the form `org.freedesktop.DBus.Error.ServiceUnknown` (or
  `NameHasNoOwner`) mean localed is not running: disable the feature, log once.
- `sd_bus_slot_unref` (`sd-bus.h:153`) removes the match; passing `NULL` as
  `ret_slot` binds it to the bus lifetime (`man/sd_bus_add_match.xml:120-127`).

### 5.7 Zig skeleton

```zig
extern fn sd_bus_default_system(ret: *?*sd_bus) c_int;
extern fn sd_bus_add_match(bus: *sd_bus, ret_slot: ?*?*sd_bus_slot, match: [*:0]const u8,
    cb: *const fn (m: ?*sd_bus_message, userdata: ?*anyopaque, ret_error: ?*sd_bus_error) callconv(.c) c_int,
    userdata: ?*anyopaque) c_int;
extern fn sd_bus_get_fd(bus: *sd_bus) c_int;
extern fn sd_bus_get_events(bus: *sd_bus) c_int;
extern fn sd_bus_get_timeout(bus: *sd_bus, ret: *u64) c_int;
extern fn sd_bus_process(bus: *sd_bus, ret: ?*?*sd_bus_message) c_int;

const locale1_match =
    "type='signal',sender='org.freedesktop.locale1'," ++
    "path='/org/freedesktop/locale1'," ++
    "interface='org.freedesktop.DBus.Properties'," ++
    "member='PropertiesChanged',arg0='org.freedesktop.locale1'";
```

RMLVO handling in kmshaunt: apply the four values as the default xkb
model/layout/variant/options when the user did not pass `--xkb-*`, and re-apply
on every signal. kmscon's equivalent path is
`kmscon_seat_update_xkb_layout()` (`src/seat.c:601-614`) called from the
locale1 callback (`src/main.c:97-118`).

---

## 6. kmscon 10.1 multi-seat model

### 6.1 One process = one seat

kmscon has no seat enumeration and no seat registry. `main.c` builds a single
`kmscon_app` with one `struct kmscon_seat` (`src/main.c:61`,
`src/seat.c:681-793`), one `ev_eloop`, one input object, one VT object, one
device monitor, one terminal-session list. "Multi-seat" is achieved by running
one kmscon per seat (systemd instantiates them), not by the process.

`struct kmscon_seat` (`src/seat.c:83-104`) holds exactly what a seat needs:
`eloop`, `conf_ctx`/`conf`, `mon` (udev monitor), `name`, `input`, `vt`,
`displays`, `videos`, `session_count`, `sessions`, `awake`, `foreground`,
`current_sess`, plus DPMS timer state.

### 6.2 Seat name

The seat name is **not** a CLI option; it is derived from the VT backend
(`src/seat.c:703-726`):

```c
seat->vt = uterm_vt_allocate(seat->eloop, conf->libseat, seat->input, conf->vt,
                             &seat_vt_cb, seat);
seatname = uterm_vt_get_name(seat->vt);       /* :709 */
seat->name = strdup(seatname);                /* :725 */
```

- `uterm_vt_get_name()` is `vt->ops->get_name(vt)` with a hardcoded fallback
  `"seat0"` (`src/uterm/vt.c:206-212`).
- **Only** the libseat backend implements `.get_name`; `real_ops`
  (`src/uterm/vt_real.c:606-615`) and the fake VT ops
  (`src/uterm/vt_fake.c:95-99`) have no `get_name`, so real and fake VT seats
  are always named `"seat0"`.
- libseat backend: `libseat_seat_name()` once connected, and the hardcoded
  string `"seat0"` *before* connecting (`src/uterm/vt_libseat.c:279-288`, with
  the comment "seatd serves a single seat named seat0; we may not be connected
  yet").

Net effect: kmscon can only ever call its seat `seat1` when libseat+logind
answers with that name (`libseat_seat_name` → `sd_session_get_seat`); with the
default real-VT backend every instance believes it is on `seat0`, and per-seat
config (§6.3) and `ID_SEAT` filtering (§6.4) then key off `"seat0"`.

### 6.3 Per-seat configuration

`kmscon_conf_load_seat()` parses the main configuration, then
`<configdir>/<seat>.seat.conf` (`src/config.c:1165-1186`, called from
`src/seat.c:728`). `configdir` defaults to `/etc/kmscon`
(`kmscon-options.md` §1, `--configdir`). So a per-seat override file is
`/etc/kmscon/seat1.seat.conf` — this is the only per-seat knob kmscon has.

### 6.4 Per-seat device filtering

`uterm_monitor_scan(mon, seat_name)` records the seat name and enumerates udev
devices; `ID_SEAT` must match, otherwise the device is skipped
(`src/uterm/monitor.c:638-651`, matching at `:423-426`; for the "device moved
seat" hotplug path the property is re-read and the device re-added,
`:448-456`). Input, DRM and fbdev all flow through this filter
(`monitor.c:387`, `:397`, `:412`). kmshaunt should mirror this: one
`ID_SEAT`-filtered device set per seat, not a global one.

### 6.5 Sessions live inside a seat

- `--session-control` (default **off**, auto-disabled on real VTs because
  session switching would conflict with VT switching, `src/seat.c:780-784`)
  enables the grabs.
- `grab-terminal-new` → `kmscon_seat_new_session()` + `seat_switch()`
  (`src/seat.c:564-572`), `grab-session-next`/`-prev`/`-close` →
  `seat_next`/`seat_prev`/unregister (`src/seat.c:536-562`).
- `--session-max` (default 50, 0 = unlimited) caps the list
  (`src/seat.c:1085-1089`), counter maintained at `:1115`/`:1141`.
- Each session is a terminal with its own pty; the child environment carries
  `XDG_SEAT` and `XDG_VTNR` (`src/misc/pty.c:234-237`), so login/PAM sees the
  right seat.

### 6.6 VT backends and their selection order

`uterm_vt_allocate()` (`src/uterm/vt.c:65-97`):

```c
if (libseat)          vt = uterm_vt_libseat_new(eloop, input, vt_name);  /* :80-81 */
if (!vt)              vt = uterm_vt_real_new(eloop, input, vt_name);     /* :85 */
if (!vt)              vt = uterm_vt_fake_new(eloop, input);              /* :88 */
```

`--libseat` is off by default (`kmscon-options.md`, `--libseat`) and the meson
option defaults to `disabled` (`meson.options:8-10`), but the nixpkgs build
enables it (`-Dlibseat=enabled`).

**real VT** (`src/uterm/vt_real.c`): open `/dev/ttyN`, register it with the
eloop, `VT_GETSTATE` to remember the caller's VT, `KDSETMODE KD_GRAPHICS`,
`VT_SETMODE` with `VT_PROCESS` + `acqsig=SIGUSR1` + `relsig=SIGUSR2`,
`KDGKBMODE`/`KDSKBMODE K_RAW` then `K_OFF` (`vt_real.c:258-330`). Activation is
`VT_ACTIVATE` returning `-EINPROGRESS` until the signal arrives
(`vt_real.c:400-433`); deactivation switches back to the saved VT
(`vt_real.c:436-478`). This is exactly the "VT owner" role kmshaunt's
`vt_real.zig` must implement when it is not using libseat.

**libseat VT** (`src/uterm/vt_libseat.c`):

- opens `/dev/ttyN` itself (`open_tty`, `:63-105`), remembers the number and
  `KDGKBMODE` state;
- `vt_libseat_wait()` blocks in `VT_WAITACTIVE` for that VT, then
  `seat_connect()` (`:245-260`);
- `seat_connect`: `libseat_open_seat` with the two-callback listener, retry
  loop on `EBUSY`/`EBADF`, then register `libseat_get_fd()` as `EV_READABLE`
  (`:166-211`); the fd handler is just `libseat_dispatch(seat, 0)`
  (`:153-159`);
- `vt_libseat_activate`: connect, `tty_activate` (KD_GRAPHICS + K_OFF), then
  `libseat_dispatch(seat,0)` to deliver the queued enable (`:220-236`);
- device fds go through `libseat_open_device` with a 20×100 ms retry on
  `ENODEV|EACCES|EBUSY` (`:297-327`) and `libseat_close_device(id)` + `close(fd)`
  (`:329-338`);
- Ctrl+Alt+F1..F12 / `XF86Switch_VT_n` → `libseat_switch_session(id)` after a
  local `vt_cb_deactivate` (`:370-407`).

**fake VT** (`src/uterm/vt_fake.c`) is the fallback when neither the kernel VT
nor libseat is available.

### 6.7 Fake VT: why it exists, and the real constraint

The header comment is explicit (`src/uterm/vt_fake.c:26-49`):

> *Fake VT: For systems without CONFIG_VT or for all seats that have no real VTs
> (which is all seats except seat0), we support a fake-VT mechanism. This
> mechanism is only used for debugging and should not be used in production.*

So the actual constraints are the two physical facts, not a kmscon design
choice:

1. **`CONFIG_VT` may be absent.** Without the kernel virtual-terminal layer
   there is no `/dev/ttyN` to open and no `VT_ACTIVATE`/`VT_RELDISP`/`KD*`
   ioctl family; `real_open` cannot work at all.
2. **Non-`seat0` seats have no VTs by definition.** VTs are a seat0 concept; a
   second seat (USB GPU + keyboard) has no `/dev/ttyN` bound to it, so a
   VT-bound backend has nothing to bind to. Even libseat cannot help: seatd only
   serves `seat0`, and its VT handling is seat0's (`seatd/server.c:42-45`).

Mechanism: the fake VT synthesizes activation state from input instead of the
kernel. Ctrl+Logo+F12 toggles it (`vt_fake.c:69-91`); activate/deactivate are
just callbacks (`vt_fake.c:56-67`, `:95-99`); no fd, no VT number, no kernel
state. The comment also spells out why it is fragile: switching between two
fake VTs requires deactivating the current one first, so each fake VT needs its
own hotkey, and two fake-VT owners on one seat cannot coordinate. Recommended
usage in the same comment: activate once at startup and never use the hotkey,
i.e. treat the fake VT as "this seat is always foreground" — for kmshaunt that
means `vt_fake.zig` should be a stateless stub whose `activate()`/`deactivate()`
just drive the seat's awake/foreground flags, with the hotkey disabled unless a
debug flag is set.

### 6.8 What kmscon deliberately does *not* do

| Missing capability | Consequence for kmshaunt |
|---|---|
| seat discovery / enumeration | kmshaunt must enumerate via sd-login (§4) and spawn one instance per seat |
| choosing a seat by name in libseat | not possible: seatd = `seat0`; logind = the seat of your session; `builtin` = `seat0`. Per-seat service units + logind is the only portable multi-seat path |
| `seat1` on plain seatd | impossible (`seatd/server.c:42-45` TODO, `client.c:159-160` TODO) |
| VT ownership when using libseat+logind | kmshaunt must do its own `KD_GRAPHICS`/`K_OFF` and `VT_WAITACTIVE` (`vt_libseat.c:104-130`, `:245-260`) |
| DRM master management | video layer must do `drmSetMaster`/`drmDropMaster` (kmscon: `video/drm_shared.c:1227-1246`) |

---

## 7. API gaps and decisions for M6

| # | Gap / surprise | Evidence | Decision for kmshaunt |
|---|---|---|---|
| G1 | No `dummy` backend; the test backend is spelled `noop` and is only reachable via `LIBSEAT_BACKEND=noop` | `libseat/libseat.c:18-31`, `:67-70` | never rely on auto-selection for tests; set the env var explicitly |
| G2 | `LIBSEAT_BACKEND` failure is `EINVAL`, not a fallback | `libseat.c:46-53` | treat as configuration error, log and exit |
| G3 | libseat cannot enumerate seats or pick one by name | `libseat.h:60`, `logind.c:664`, `seatd/client.c:159-160` | multi-seat = one process per seat, seat chosen by the process's session (logind) |
| G4 | seatd (and therefore `builtin`) serves only `seat0` | `seatd/server.c:42-45`, `seatd/client.c:159-160` | on NixOS use `LIBSEAT_BACKEND=logind` for `seat1+`; document it |
| G5 | `device_id != fd` on seatd, `device_id == fd` on logind | `logind.c:145-151`, `seatd/seat.c:352-366` | always store the pair; never reuse one as the other |
| G6 | Re-opening an already-open path bumps a refcount and returns the same file description | `seatd/seat.c:350-360` | device table keyed by canonical path; idempotent open |
| G7 | evdev/hidraw revoke is irreversible; the server cannot re-activate them | `common/evdev.c:24-26`, `seatd/seat.c:509-527` | must `close_device` + `close(fd)` on disable, then re-open on enable |
| G8 | `libseat_disable_seat` is a blocking round-trip on seatd, a no-op on logind | `seatd.c:636-660`, `logind.c:215-218` | ack exactly once, inside the callback, and treat both results as success |
| G9 | logind acks `PauseDevice` *before* the app finishes (`PauseDeviceComplete` immediately) | `logind.c:388-405` | finish device teardown synchronously inside `disable_seat` |
| G10 | libseat's default log level is `SILENT` | `common/log.c:15` | install a handler; map DEBUG→trace, INFO→debug, ERROR→err |
| G11 | `sd_pid_get_seat` does not exist in systemd 262 | absent from `sd-login.h`/`sd-login.c` | compose `sd_pid_get_session` + `sd_session_get_seat`, with `XDG_SESSION_ID` fast path (`logind.c:607-620`) |
| G12 | sd-login seat monitor signals "something changed" only; `get_events()`=POLLIN, `get_timeout()`=UINT64_MAX | `sd-login.c:1183-1267` | flush + full re-enumerate on each wake; no timer integration |
| G13 | `sd_seat_get_active` returns `-ENXIO`/`-ENODATA` for "no active session" | `sd-login.c:854-886` | map both to `null`, not to an error path |
| G14 | locale1 properties can be empty strings and can arrive in the *invalidated* (no-value) array of `PropertiesChanged` | `localed.c:91-126`, `localed.c:542-549`, sd-bus `a{sv} as` | treat `""` as unset; re-Get on invalidated names |
| G15 | `sd_bus_get_timeout` returns an **absolute** CLOCK_MONOTONIC µs deadline, `UINT64_MAX` for infinite | `sd-bus.c:2634-2690`, `man/sd_bus_get_fd.xml:69-92` | convert with `ceil`, never pass the raw value to `epoll_wait` |
| G16 | sd-bus objects are per-thread and return `-ECHILD` after `fork()`; libseat's `builtin` forks | `man/sd_bus_get_fd.xml:132-134`, `seatd.c:677-700` | keep the forked child free of sd-bus/Zig allocations |
| G17 | libseat's seat handle has no "am I enabled?" query | `libseat.h:60-140` | track state in your listener; gate every device call on it |
| G18 | `libseat_get_fd` for logind is `sd_bus_get_fd`, which can be an inotify fd | `logind.c:220-229`, `sd-bus.c:2570-2586` | register the fd you get after open; do not dup it, do not poll for writability yourself |
| G19 | locale1's `Set*` methods need polkit; reads do not | `localed.c:280`, `:385`, `:505` | kmshaunt only reads — no polkit interaction needed |
| G20 | Seat name is not selectable: real and fake VT backends have no `get_name`, so `uterm_vt_get_name()` falls back to `"seat0"`; the libseat backend also says `"seat0"` until connected | `src/uterm/vt.c:206-212`, `vt_real.c:606-615`, `vt_fake.c:95-99`, `vt_libseat.c:279-288` | take the seat name from sd-login/config in kmshaunt; never derive it from the VT backend |
| G21 | kmscon's seat name feeds the per-seat config file **and** the `ID_SEAT` device filter, so a wrongly named seat silently gets seat0's devices and config | `src/seat.c:709-728`, `src/uterm/monitor.c:423-426` | validate the resolved seat name against `sd_get_seats()` at startup |

---

## 8. M6 implementation checklist

1. **build wiring** (`build.zig`): `exe.root_module.linkSystemLibrary("seat")`,
   `linkSystemLibrary("systemd")`; include paths from `deps.nix`
   (`seatd.dev`/`systemd.dev`). Fill `deps.nix` (currently 0 bytes) with
   `${pkgs.seatd.dev}`, `${pkgs.seatd}`, `${pkgs.systemd.dev}`,
   `${pkgs.systemd}`.
2. **`src/seat/libseat.zig`**: extern decls from §2.2, `extern struct`
   listener with `callconv(.c)`, `std.c.errno()` mapping, epoll registration of
   `libseat_get_fd()` with `EPOLLIN`, `dispatch(0)` handler, device table
   `{path, fd, id}` implementing §3.5.
3. **`src/seat/vt_real.zig`**: `VT_GETSTATE` → save caller VT → `KD_GRAPHICS`
   → `VT_SETMODE VT_PROCESS` (SIGUSR1/SIGUSR2) → `K_RAW`/`K_OFF`; on release
   `VT_RELDISP 1`, on re-acquire `VT_RELDISP VT_ACKACQ`; restore `KD_TEXT` and
   saved kbmode on exit (`vt_real.c:258-330`, `common/terminal.c:223-241`).
4. **`src/seat/vt_fake.zig`**: always-foreground stub, no hotkey by default
   (§6.7).
5. **`src/seat/multiseat.zig`**: sd-login enumeration + `"seat"` monitor
   (§4.2-4.4), per-seat child spawn (one process per seat), `XDG_SEAT`/
   `XDG_VTNR` propagation for the session layer (`src/misc/pty.c:234-237`).
6. **`src/misc/locale1.zig`**: `sd_bus_default_system`, four property reads,
   `PropertiesChanged` match with `arg0='org.freedesktop.locale1'`, absolute
   timeout conversion, re-Get on invalidated names (§5).
7. **tests**: unit-test the state machines with `LIBSEAT_BACKEND=noop`
   (open/close, dispatch-enables-once) and with a fake bus (feed
   `PropertiesChanged` messages constructed in-process), so M6 does not need
   root, a VT, or a running localed in CI.

---

## Appendix A — citation index (most-load-bearing lines)

| Claim | Citation |
|---|---|
| listener contract, "must be acknowledged", "re-open devices" | `libseat.h:16-36` |
| `LIBSEAT_BACKEND`, exact names, auto order skips noop, `ENOSYS` | `libseat/libseat.c:18-31`, `:45-53`, `:67-81` |
| default log level SILENT | `seatd/common/log.c:15` |
| builtin forks an embedded seatd | `libseat/backend/seatd.c:677-737` |
| seatd disable: revoke fds → PENDING_DISABLE → send event | `seatd/seat.c:593-623` |
| seatd ack → DISABLED → activate next client | `seatd/seat.c:631-657`, `:147-182` |
| seatd VT-bound client session == current VT | `seatd/seat.c:212-232` |
| seatd VT setup K_OFF + KD_GRAPHICS | `seatd/seat.c:77-105`, `common/terminal.c:195-280` |
| device refcount reuse by canonical path | `seatd/seat.c:350-360` |
| evdev/hidraw cannot be re-activated | `seatd/seat.c:509-527` |
| DRM master reacquisition on enable | `seatd/seat.c:511-519` |
| ping wake-up when events queued during a request | `libseat/backend/seatd.c:489-519` |
| logind `disable_seat` is a no-op | `libseat/backend/logind.c:215-218` |
| logind PauseDevice/PauseDeviceComplete ordering | `logind.c:363-405` |
| logind `Active` property drives enable/disable | `logind.c:348-361`, `:408-508` |
| logind seat resolution from session | `logind.c:607-676` |
| `sd_login_monitor` is inotify on the four state dirs | `libsystemd/sd-login/sd-login.c:1183-1267` |
| seat state file written via tmpfile+rename (IN_MOVED_TO) | `login/logind-seat.c:101-166` |
| `sd_get_seats` returns 0 when the directory is absent | `sd-login.c:988-1001` |
| `sd_seat_get_active` `-ENXIO`/`-ENODATA` | `sd-login.c:854-886` |
| locale1 path/interface/properties | `locale/localed.c:557-590`, `:91-126` |
| locale1 emits the four X11 properties together | `locale/localed.c:542-549` |
| match rule installed synchronously; argN parsing | `libsystemd/sd-bus/bus-control.c:965-1005`, `bus-match.c:596-613`, `:981-993`, `man/sd_bus_add_match.xml:98-100` |
| client-side match filtering | `libsystemd/sd-bus/sd-bus.c:2919-2922` |
| fd/events/timeout semantics | `libsystemd/sd-bus/sd-bus.c:2570-2690`, `man/sd_bus_get_fd.xml:69-107` |
| process must loop until it returns 0 | `libsystemd/sd-bus/sd-bus.c:3286-3290` |
| kmscon one seat per process / struct | `src/seat.c:83-104`, `:681-793` |
| kmscon per-seat config file | `src/config.c:1165-1186`, `src/seat.c:728` |
| kmscon `ID_SEAT` device filter | `src/uterm/monitor.c:423-426`, `:638-651` |
| kmscon VT backend selection order | `src/uterm/vt.c:65-97` |
| kmscon real VT ioctl sequence | `src/uterm/vt_real.c:258-330`, `:400-478` |
| kmscon libseat enable/disable/ack | `src/uterm/vt_libseat.c:132-164` |
| kmscon libseat open/hotkey/device retry | `src/uterm/vt_libseat.c:166-235`, `:245-260`, `:297-338`, `:370-407` |
| fake VT rationale and constraints | `src/uterm/vt_fake.c:26-49`, `:69-101` |
| kmscon locale1 (libdbus) match + startup env | `src/misc/dbus.c:125-138`, `:334-360`, `src/main.c:97-118`, `:149-152` |
| seatd serves only seat0 | `seatd/server.c:42-45`, `seatd/client.c:159-160` |