//! src/input/libinput.zig -- libinput device/event dispatch
//! (ROADMAP M1.6 keyboard, M2.3 pointer).
//!
//! Turns libinput events into `session.InputEvent`s: keyboard events go
//! through `xkb.State.processKey` (modifiers, UTF-8, Compose), pointer
//! events carry relative deltas or absolute positions, wheel/finger
//! scrolls become axis events, and configured grabs intercept matching
//! key presses *before* anything reaches the session. Key repeat is a
//! `loop.Timer` wired by `attachLoop`; device hotplug is tracked and
//! reported through an optional hook.
//!
//! # C shim and build wiring
//!
//! All libinput/libudev access goes through the `LibinputOps` seam (one
//! function pointer per C call). `LibinputOps.real` binds the translate-c
//! output of the shim
//!
//!     #include <libinput.h>
//!     #include <libudev.h>
//!
//! via a lazy `@import("libinput-c")` inside the `Real` namespace: nothing
//! in that namespace is analyzed unless `LibinputOps.real` is referenced,
//! so this module compiles without libinput-c until the real backend is
//! used. The standalone tests reference it in one binding test (analyzed,
//! never called), so their command wires it like `xkb-c` (verified
//! against libinput 1.31.3, libudev from systemd 262, xkbcommon 1.13.2):
//!
//!     nix build nixpkgs#libinput.dev nixpkgs#libinput \
//!         nixpkgs#systemd.dev nixpkgs#systemd \
//!         nixpkgs#libxkbcommon.dev nixpkgs#libxkbcommon \
//!         nixpkgs#xkeyboard_config nixpkgs#libx11 --print-out-paths --no-link
//!     printf '#include <libinput.h>\n#include <libudev.h>\n' > /tmp/libinput_shim.h
//!     nix run nixpkgs#zig -- translate-c \
//!         -I<libinput.dev>/include -I<systemd.dev>/include -lc \
//!         /tmp/libinput_shim.h > /tmp/libinput_c.zig
//!     printf '#include <xkbcommon/xkbcommon.h>\n#include <xkbcommon/xkbcommon-compose.h>\n#include <xkbcommon/xkbcommon-names.h>\n' > /tmp/xkb_shim.h
//!     nix run nixpkgs#zig -- translate-c \
//!         -I<libxkbcommon.dev>/include -lc /tmp/xkb_shim.h > /tmp/xkb_c.zig
//!
//! Standalone test command (headless: fake libinput event queue, real
//! xkbcommon keymap; no devices, no udev, no seat daemon):
//!
//!     XKB_CONFIG_ROOT=<xkeyboard_config>/share/X11/xkb \
//!     XLOCALEDIR=<libx11>/share/X11/locale \
//!     nix run nixpkgs#zig -- test \
//!         --dep xkb-c --dep libinput-c \
//!         -Mroot=src/test_libinput.zig \
//!         -Mxkb-c=/tmp/xkb_c.zig -Mlibinput-c=/tmp/libinput_c.zig \
//!         -lc -I<libxkbcommon.dev>/include -I<libinput.dev>/include \
//!         -I<systemd.dev>/include \
//!         -L<libxkbcommon>/lib -lxkbcommon \
//!         -L<libinput>/lib -linput -L<systemd>/lib -ludev
//!
//! Module path: this file imports `../session.zig`, so the test root must
//! be `src/test_libinput.zig` (module root `src/`), not this file.
//!
//! # Event mapping (libinput 1.31.3 -> session.InputEvent)
//!
//! | libinput event                    | InputEvent       | notes |
//! |-----------------------------------|------------------|-------|
//! | KEYBOARD_KEY (300)                | key / grab       | xkb processKey; grab match intercepts presses and repeats |
//! | POINTER_MOTION (400)              | pointer_motion   | relative dx/dy; x/y accumulate from (0,0), clamped to the canvas |
//! | POINTER_MOTION_ABSOLUTE (401)     | pointer_motion   | absolute=true; x/y in device space (mm), dx/dy vs previous position |
//! | POINTER_BUTTON (402)              | pointer_button   | click_count from a 400 ms window (1/2/3, capped) |
//! | POINTER_SCROLL_WHEEL (404)        | pointer_axis     | get_axis_value, natural-scrolling invert |
//! | POINTER_SCROLL_FINGER (405)       | pointer_axis     | same |
//! | POINTER_SCROLL_CONTINUOUS (406)   | pointer_axis     | same |
//! | POINTER_AXIS (403, legacy)        | — (ignored)      | libinput >= 1.19 emits it *in addition* to the SCROLL_* events; processing both would double-scroll |
//! | DEVICE_ADDED (1) / REMOVED (2)    | — (hotplug hook) | tracked in `deviceList`, keyboard/pointer capabilities |
//! | touch/tablet/gesture/switch       | — (ignored)      | out of scope (M2.3 is pointer + keyboard) |
//!
//! libinput 1.31.3 removed `libinput_event_pointer_has_absolute`; the
//! event type (MOTION vs MOTION_ABSOLUTE) is the authoritative signal.
//! Absolute coordinates are the raw device-space values
//! (`get_absolute_x/y`, mm from the device's top-left); the input layer
//! does not know the screen size, so scaling to the framebuffer is the
//! consumer's job (the `_transformed` getters need width/height).
//!
//! # Grabs
//!
//! Every key press (and every repeat of a held key) is matched against
//! the 13 `cfg.grab_*` options BEFORE forwarding; a match emits
//! `InputEvent.grab{id}` instead of the key event. Releases are never
//! grabbed. Matching uses `config.Grab.matches`: exact equality of the
//! five kmscon modifier bits (shift, lock/caps, ctrl, alt, logo — side
//! bits and NumLock are ignored) and the keysym. The xkb state is updated
//! even for grabbed keys (processKey runs first). Grab ids:
//!
//! | id | GrabId        | config field        | default binding      |
//! |----|---------------|---------------------|----------------------|
//! | 1  | scroll_up     | grab_scroll_up      | Shift+Up             |
//! | 2  | scroll_down   | grab_scroll_down    | Shift+Down           |
//! | 3  | page_up       | grab_page_up        | Shift+Prior          |
//! | 4  | page_down     | grab_page_down      | Shift+Next           |
//! | 5  | zoom_in       | grab_zoom_in        | Ctrl+plus / Ctrl+equal |
//! | 6  | zoom_out      | grab_zoom_out       | Ctrl+minus           |
//! | 7  | session_next  | grab_session_next   | Ctrl+Logo+Right      |
//! | 8  | session_prev  | grab_session_prev   | Ctrl+Logo+Left       |
//! | 9  | session_close | grab_session_close  | Ctrl+Logo+BackSpace  |
//! | 10 | terminal_new  | grab_terminal_new   | Ctrl+Logo+Return     |
//! | 11 | rotate_cw     | grab_rotate_cw      | Logo+plus / Logo+equal |
//! | 12 | rotate_ccw    | grab_rotate_ccw     | Logo+minus           |
//! | 13 | reboot        | grab_reboot         | none (disabled)      |
//!
//! The session manager resolves the id; sessions receive it verbatim
//! (session.zig InputEvent.Grab). Session-control gating (`session_max`,
//! real-VT check) is the session manager's concern, not this layer's.
//!
//! Keysym caveat: grabs match the *effective keysym*. In the default
//! pc/us keymap Ctrl+Alt+F1..F12 produce XF86Switch_VT_1..12 (VT
//! switching, the seat's job), not F1..F12 — a grab written
//! "<Ctrl><Alt>F1" does not match them. The kmscon-style reboot binding
//! is "<Ctrl><Alt>Delete".
//!
//! # Repeat
//!
//! Repeat is driven through the `RepeatTimerOps` seam: the input layer
//! owns neither the Loop nor the timer (main.zig does; adapter example
//! below). A press of a key with `keymap.shouldRepeat(code)` calls
//! `arm(delay_ns, interval_ns)` with `xkb-repeat-delay` /
//! `xkb-repeat-rate` (both clamped through xkb.RepeatConfig.fromKmsconMs,
//! so 0 -> default and >= 1000 -> 999; the rate is converted to an
//! interval via Hz). The owner's timer callback forwards expirations to
//! `repeatExpired`, which emits `key` with action=repeat — through the
//! same grab check as the original press.
//!
//! The repeat tracks the repeating PHYSICAL key, not a translated event:
//! every expiration re-translates it with `xkb.State.translateKey`, using
//! the modifiers held at that moment and without updating the xkb state or
//! feeding Compose. Releasing Shift mid-repeat therefore turns "A" into
//! "a", and grab matching sees the current modifiers. A repeatable press
//! replaces the current repeat; a non-repeatable press (a modifier, a lock,
//! a function key) leaves it running because it changes how the held key
//! translates, not whether it repeats. Releasing the repeating key cancels
//! it (`disarm`). Without a timer there is no repeat.
//!
//! The seam keeps this module independent of loop.zig: importing
//! loop.zig into a libc-linked test build currently fails because its
//! SignalSource tests mix kernel and glibc sigset_t; main.zig wires the
//! adapter below instead.
//!
//! # Wiring points for main.zig
//!
//!     var input = try Input.init(alloc, io, &keymap, &cfg, LibinputOps.real);
//!     defer input.deinit();
//!     input.setSink(mySink, @intFromPtr(&ctx));   // REQUIRED before dispatch
//!     input.hotplug = .{ .callback = myHotplug, .userdata = ... }; // optional
//!     _ = try lp.addSource(input.fd(), loop.ev.in_, myHandler, @intFromPtr(&input));
//!     try input.dispatch();                       // once: initial DEVICE_ADDED
//!     // myHandler: input.dispatch() catch |err| log
//!
//! Repeat timer adapter (loop.Timer -> RepeatTimerOps):
//!
//!     const RepeatAdapter = struct {
//!         input: *Input,
//!         timer: loop.Timer = .{},
//!         fn arm(ctx: ?*anyopaque, delay_ns: u64, interval_ns: u64) !void {
//!             const self: *@This() = @ptrCast(@alignCast(ctx.?));
//!             try self.timer.arm(loop.nsToTimespec(delay_ns), loop.nsToTimespec(interval_ns));
//!         }
//!         fn disarm(ctx: ?*anyopaque) !void {
//!             const self: *@This() = @ptrCast(@alignCast(ctx.?));
//!             try self.timer.disarm();
//!         }
//!         fn fired(_: *loop.Timer, expirations: u64, userdata: usize) void {
//!             const self: *@This() = @ptrFromInt(userdata);
//!             self.input.repeatExpired(expirations);
//!         }
//!     };
//!     var repeat = RepeatAdapter{ .input = &input };
//!     try repeat.timer.init(&lp, .{ .callback = RepeatAdapter.fired, .userdata = @intFromPtr(&repeat) });
//!     defer repeat.timer.deinit();   // after input.deinit; the Loop outlives both
//!     input.attachRepeatTimer(.{ .ctx = &repeat, .arm = RepeatAdapter.arm, .disarm = RepeatAdapter.disarm });
//!
//! `Input` must be at its final address before setSink (the userdata
//! pointer is taken from it). The sink runs synchronously inside
//! dispatch/repeatExpired on the loop thread; `key.utf8` borrows the xkb
//! buffer and is only valid for the duration of the sink call — copy it
//! if it must outlive delivery (the terminal session encodes
//! synchronously). The sink returns void: session error policy belongs
//! to the caller wiring it (loop handlers cannot propagate).
//!
//! # Seat lifecycle (suspend/resume)
//!
//! Input is tied to seat ownership. When the seat deactivates (VT switch
//! away, libseat disable_seat) main.zig calls `Input.suspend_`: libinput
//! closes every evdev fd so no key/pointer event is read while another
//! session owns the console, key repeat is disarmed, and events queued
//! before the switch are dropped. `Input.resume_` (on activation) re-opens
//! the devices and drains the DEVICE_ADDED queue. `dispatch` is a no-op
//! while suspended. The dropped events include the VT-switch chord's
//! modifier releases, but the user may also still HOLD the chord that
//! switched to us, so `resume_` re-syncs the xkb state with the physical
//! key state (EVIOCGKEY on the open evdev fds) instead of resetting blind:
//! stale modifiers are cleared, held ones survive (Ctrl+Alt+Fn must keep
//! switching), and any in-progress Compose sequence is reset.
//! The sink owner additionally gates on seat ownership
//! (Console.onInput drops events while the seat is inactive) so the
//! no-input-while-inactive invariant holds even if a backend cannot
//! suspend.
//!
//! # Config flags
//!
//! `mouse=false` drops all pointer events (motion/button/axis); keyboard
//! and device tracking are unaffected. `natural_scrolling` inverts both
//! scroll axes. `soft_cursor` is carried on `cfg` for the renderer only —
//! it has no effect in the input layer (kmscon terminal.c:872).
//! Compose is initialized from `cfg.xkb_compose_file` and the
//! LC_ALL/LC_CTYPE/LANG locale (fallback "C", kmscon seat.c:590-599);
//! any compose-table failure disables compose and input continues
//! (kmscon parity), except OutOfMemory which propagates.
//!
//! The real backend opens device nodes through `Interface.open_restricted`
//! (openat with the flags libinput passes, negative-errno convention) and
//! assigns seat "seat0". A libseat-backed interface can replace it when
//! the seat manager lands (M6.1); the seam stays unchanged.

const std = @import("std");
const xkb = @import("xkb.zig");
const kt = @import("keymap_table.zig");
const session = @import("../session.zig");
const config = @import("../config/config.zig");

const linux = std.os.linux;

// ---------------------------------------------------------------------------
// C types (opaque; the seam never exposes translate-c types)
// ---------------------------------------------------------------------------

/// `struct libinput *` — the event context.
pub const Libinput = opaque {};
/// `struct libinput_event *` — one queued event. The keyboard/pointer
/// getters in C take the typed sub-structs, which are plain casts of the
/// same pointer; the seam uses this one type and `Real` casts.
pub const Event = opaque {};
/// `struct libinput_device *`.
pub const Device = opaque {};
/// `struct udev *`.
pub const Udev = opaque {};

/// `struct libinput_interface` (libinput.h:3617). Signatures match the
/// translate-c output exactly so `Real` can pass the pointer through.
/// libinput calls open_restricted for every device node it needs; the
/// return is the fd or a negative errno.
///
/// LIFETIME: libinput stores this struct BY POINTER (libinput.c
/// `libinput->interface = interface`) and calls through it for the whole
/// context lifetime, including close_restricted from evdev_device_remove
/// during libinput_unref. The instance handed to udev_create_context must
/// therefore outlive the context (the module-level `interface` below is
/// static); a stack copy dangles and graceful shutdown jumps through the
/// reused stack slot.
pub const Interface = extern struct {
    open_restricted: *const fn (path: [*c]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int,
    close_restricted: *const fn (fd: c_int, user_data: ?*anyopaque) callconv(.c) void,
};

/// libinput event types we handle (libinput.h enum libinput_event_type).
pub const event = struct {
    pub const device_added: c_int = 1;
    pub const device_removed: c_int = 2;
    pub const keyboard_key: c_int = 300;
    pub const pointer_motion: c_int = 400;
    pub const pointer_motion_absolute: c_int = 401;
    pub const pointer_button: c_int = 402;
    /// Legacy scroll event; ignored, see the module header.
    pub const pointer_axis: c_int = 403;
    pub const pointer_scroll_wheel: c_int = 404;
    pub const pointer_scroll_finger: c_int = 405;
    pub const pointer_scroll_continuous: c_int = 406;
};

/// `enum libinput_device_capability` (only the two we track).
pub const cap = struct {
    pub const keyboard: c_int = 0;
    pub const pointer: c_int = 1;
};

/// `enum libinput_key_state`.
pub const key_state = struct {
    pub const released: c_int = 0;
    pub const pressed: c_int = 1;
};

/// `enum libinput_button_state`.
pub const button_state = struct {
    pub const released: c_int = 0;
    pub const pressed: c_int = 1;
};

/// `enum libinput_pointer_axis`.
pub const axis = struct {
    pub const vertical: c_int = 0;
    pub const horizontal: c_int = 1;
};

/// Grab ids emitted as `InputEvent.grab.id`; see the module header table
/// for the config mapping and default bindings. The session manager
/// resolves them (scroll/page/zoom act on the focused session, session_*
/// and terminal_new on the manager, rotate_* on the video backend,
/// reboot on the seat).
pub const GrabId = enum(u16) {
    scroll_up = 1,
    scroll_down = 2,
    page_up = 3,
    page_down = 4,
    zoom_in = 5,
    zoom_out = 6,
    session_next = 7,
    session_prev = 8,
    session_close = 9,
    terminal_new = 10,
    rotate_cw = 11,
    rotate_ccw = 12,
    reboot = 13,
};

// ---------------------------------------------------------------------------
// Ops seam
// ---------------------------------------------------------------------------

/// Injectable seam over every libinput/libudev call this module makes.
/// Tests install a fake event queue; production uses `LibinputOps.real`.
/// Signatures follow the libinput 1.31.3 prototypes with the typed event
/// sub-structs collapsed to `*Event` (they are casts of the same pointer).
pub const LibinputOps = struct {
    udev_new: *const fn () callconv(.c) ?*Udev,
    udev_unref: *const fn (udev: *Udev) callconv(.c) ?*Udev,
    /// The interface is stored by pointer, NOT copied: it must stay valid
    /// until `unref` (see `Interface`).
    udev_create_context: *const fn (interface: *const Interface, user_data: ?*anyopaque, udev: *Udev) callconv(.c) ?*Libinput,
    udev_assign_seat: *const fn (li: *Libinput, seat_id: [*:0]const u8) callconv(.c) c_int,
    unref: *const fn (li: *Libinput) callconv(.c) ?*Libinput,
    /// Suspend the context: close every device fd and remove the devices
    /// (the context stays valid for `resume_`). Returns void in libinput
    /// 1.31.3.
    suspend_: *const fn (li: *Libinput) callconv(.c) void,
    /// Resume a suspended context: re-enable device monitoring and re-add
    /// the devices. Returns 0 on success, -1 on failure.
    resume_: *const fn (li: *Libinput) callconv(.c) c_int,
    get_fd: *const fn (li: *Libinput) callconv(.c) c_int,
    dispatch: *const fn (li: *Libinput) callconv(.c) c_int,
    get_event: *const fn (li: *Libinput) callconv(.c) ?*Event,
    event_destroy: *const fn (ev: *Event) callconv(.c) void,
    event_get_type: *const fn (ev: *Event) callconv(.c) c_int,
    event_get_device: *const fn (ev: *Event) callconv(.c) ?*Device,
    keyboard_get_key: *const fn (ev: *Event) callconv(.c) u32,
    keyboard_get_key_state: *const fn (ev: *Event) callconv(.c) c_int,
    pointer_get_dx: *const fn (ev: *Event) callconv(.c) f64,
    pointer_get_dy: *const fn (ev: *Event) callconv(.c) f64,
    pointer_get_absolute_x: *const fn (ev: *Event) callconv(.c) f64,
    pointer_get_absolute_y: *const fn (ev: *Event) callconv(.c) f64,
    pointer_get_absolute_x_transformed: *const fn (ev: *Event, width: u32) callconv(.c) f64,
    pointer_get_absolute_y_transformed: *const fn (ev: *Event, height: u32) callconv(.c) f64,
    pointer_get_button: *const fn (ev: *Event) callconv(.c) u32,
    pointer_get_button_state: *const fn (ev: *Event) callconv(.c) c_int,
    pointer_get_axis_value: *const fn (ev: *Event, which: c_int) callconv(.c) f64,
    device_has_capability: *const fn (dev: *Device, capability: c_int) callconv(.c) c_int,
    device_ref: *const fn (dev: *Device) callconv(.c) ?*Device,
    device_unref: *const fn (dev: *Device) callconv(.c) ?*Device,
    device_get_name: *const fn (dev: *Device) callconv(.c) ?[*:0]const u8,

    /// The real backend. Referencing this analyzes `Real` and therefore
    /// requires the `libinput-c` module and `-linput -ludev`; hermetic
    /// tests never reference it.
    pub const real: LibinputOps = .{
        .udev_new = Real.udevNew,
        .udev_unref = Real.udevUnref,
        .udev_create_context = Real.udevCreateContext,
        .udev_assign_seat = Real.udevAssignSeat,
        .unref = Real.unref,
        .suspend_ = Real.suspend_,
        .resume_ = Real.resume_,
        .get_fd = Real.getFd,
        .dispatch = Real.dispatch,
        .get_event = Real.getEvent,
        .event_destroy = Real.eventDestroy,
        .event_get_type = Real.eventGetType,
        .event_get_device = Real.eventGetDevice,
        .keyboard_get_key = Real.keyboardGetKey,
        .keyboard_get_key_state = Real.keyboardGetKeyState,
        .pointer_get_dx = Real.pointerGetDx,
        .pointer_get_dy = Real.pointerGetDy,
        .pointer_get_absolute_x = Real.pointerGetAbsoluteX,
        .pointer_get_absolute_y = Real.pointerGetAbsoluteY,
        .pointer_get_absolute_x_transformed = Real.pointerGetAbsoluteXTransformed,
        .pointer_get_absolute_y_transformed = Real.pointerGetAbsoluteYTransformed,
        .pointer_get_button = Real.pointerGetButton,
        .pointer_get_button_state = Real.pointerGetButtonState,
        .pointer_get_axis_value = Real.pointerGetAxisValue,
        .device_has_capability = Real.deviceHasCapability,
        .device_ref = Real.deviceRef,
        .device_unref = Real.deviceUnref,
        .device_get_name = Real.deviceGetName,
    };
};

/// translate-c bindings, analyzed only when `LibinputOps.real` is used.
const Real = struct {
    const c = @import("libinput-c");

    fn udevNew() callconv(.c) ?*Udev {
        return @ptrCast(c.udev_new());
    }

    fn udevUnref(udev: *Udev) callconv(.c) ?*Udev {
        return @ptrCast(c.udev_unref(@ptrCast(udev)));
    }

    fn udevCreateContext(intf: *const Interface, user_data: ?*anyopaque, udev: *Udev) callconv(.c) ?*Libinput {
        // Pass the caller's pointer straight through: libinput keeps it for
        // the context lifetime (see `Interface`). Copying into a local here
        // left libinput holding a dangling stack pointer; the first
        // close_restricted during libinput_unref (evdev_device_remove ->
        // evdev_device_suspend) then jumped through the reused stack slot
        // and segfaulted graceful shutdown. `Interface` is layout-identical
        // to the translate-c struct (two C function pointers, extern).
        comptime {
            std.debug.assert(@sizeOf(Interface) == @sizeOf(c.struct_libinput_interface));
            std.debug.assert(@alignOf(Interface) == @alignOf(c.struct_libinput_interface));
        }
        return @ptrCast(c.libinput_udev_create_context(@ptrCast(intf), user_data, @ptrCast(udev)));
    }

    fn udevAssignSeat(li: *Libinput, seat_id: [*:0]const u8) callconv(.c) c_int {
        return c.libinput_udev_assign_seat(@ptrCast(li), seat_id);
    }

    fn unref(li: *Libinput) callconv(.c) ?*Libinput {
        return @ptrCast(c.libinput_unref(@ptrCast(li)));
    }

    fn suspend_(li: *Libinput) callconv(.c) void {
        c.libinput_suspend(@ptrCast(li));
    }

    fn resume_(li: *Libinput) callconv(.c) c_int {
        return c.libinput_resume(@ptrCast(li));
    }

    fn getFd(li: *Libinput) callconv(.c) c_int {
        return c.libinput_get_fd(@ptrCast(li));
    }

    fn dispatch(li: *Libinput) callconv(.c) c_int {
        return c.libinput_dispatch(@ptrCast(li));
    }

    fn getEvent(li: *Libinput) callconv(.c) ?*Event {
        return @ptrCast(c.libinput_get_event(@ptrCast(li)));
    }

    fn eventDestroy(ev: *Event) callconv(.c) void {
        c.libinput_event_destroy(@ptrCast(ev));
    }

    fn eventGetType(ev: *Event) callconv(.c) c_int {
        return @intCast(c.libinput_event_get_type(@ptrCast(ev)));
    }

    fn eventGetDevice(ev: *Event) callconv(.c) ?*Device {
        return @ptrCast(c.libinput_event_get_device(@ptrCast(ev)));
    }

    fn keyboardGetKey(ev: *Event) callconv(.c) u32 {
        return c.libinput_event_keyboard_get_key(@ptrCast(ev));
    }

    fn keyboardGetKeyState(ev: *Event) callconv(.c) c_int {
        return @intCast(c.libinput_event_keyboard_get_key_state(@ptrCast(ev)));
    }

    fn pointerGetDx(ev: *Event) callconv(.c) f64 {
        return c.libinput_event_pointer_get_dx(@ptrCast(ev));
    }

    fn pointerGetDy(ev: *Event) callconv(.c) f64 {
        return c.libinput_event_pointer_get_dy(@ptrCast(ev));
    }

    fn pointerGetAbsoluteX(ev: *Event) callconv(.c) f64 {
        return c.libinput_event_pointer_get_absolute_x(@ptrCast(ev));
    }

    fn pointerGetAbsoluteY(ev: *Event) callconv(.c) f64 {
        return c.libinput_event_pointer_get_absolute_y(@ptrCast(ev));
    }

    fn pointerGetAbsoluteXTransformed(ev: *Event, width: u32) callconv(.c) f64 {
        return c.libinput_event_pointer_get_absolute_x_transformed(@ptrCast(ev), width);
    }

    fn pointerGetAbsoluteYTransformed(ev: *Event, height: u32) callconv(.c) f64 {
        return c.libinput_event_pointer_get_absolute_y_transformed(@ptrCast(ev), height);
    }

    fn pointerGetButton(ev: *Event) callconv(.c) u32 {
        return c.libinput_event_pointer_get_button(@ptrCast(ev));
    }

    fn pointerGetButtonState(ev: *Event) callconv(.c) c_int {
        return @intCast(c.libinput_event_pointer_get_button_state(@ptrCast(ev)));
    }

    fn pointerGetAxisValue(ev: *Event, which: c_int) callconv(.c) f64 {
        return c.libinput_event_pointer_get_axis_value(@ptrCast(ev), @intCast(which));
    }

    fn deviceHasCapability(dev: *Device, capability: c_int) callconv(.c) c_int {
        return c.libinput_device_has_capability(@ptrCast(dev), @intCast(capability));
    }

    fn deviceRef(dev: *Device) callconv(.c) ?*Device {
        return @ptrCast(c.libinput_device_ref(@ptrCast(dev)));
    }

    fn deviceUnref(dev: *Device) callconv(.c) ?*Device {
        return @ptrCast(c.libinput_device_unref(@ptrCast(dev)));
    }

    fn deviceGetName(dev: *Device) callconv(.c) ?[*:0]const u8 {
        return c.libinput_device_get_name(@ptrCast(dev));
    }
};

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/// Event sink: delivers one translated event synchronously. `key.utf8`
/// borrows the xkb buffer and is only valid during this call. Returns
/// void — the wiring owner decides session error policy.
pub const EventSink = *const fn (userdata: usize, event: session.InputEvent) void;

/// Key-repeat timer seam (the input layer owns neither the Loop nor the
/// timer). `arm` sets the first expiration to `delay_ns` and the repeat
/// interval to `interval_ns`; `disarm` stops the timer. The owner's
/// timer callback forwards expiration counts to `Input.repeatExpired`.
/// main.zig wires a loop.Timer through this seam (module header).
pub const RepeatTimerOps = struct {
    ctx: ?*anyopaque = null,
    arm: *const fn (ctx: ?*anyopaque, delay_ns: u64, interval_ns: u64) anyerror!void,
    disarm: *const fn (ctx: ?*anyopaque) anyerror!void,
};

/// Hotplug notification: `added` true on DEVICE_ADDED, false on
/// DEVICE_REMOVED. `device.name` borrows libinput storage and is valid
/// until the device is removed (we hold a reference while tracked).
pub const HotplugHook = struct {
    callback: *const fn (userdata: usize, device: DeviceInfo, added: bool) void,
    userdata: usize = 0,
};

/// One tracked device (DEVICE_ADDED until DEVICE_REMOVED).
pub const DeviceInfo = struct {
    device: *Device,
    name: []const u8,
    keyboard: bool,
    pointer: bool,
};

/// Double-click window: consecutive presses of the same button within
/// this many milliseconds increment click_count (capped at 3).
pub const double_click_window_ms: i64 = 400;

/// BTN_LEFT .. BTN_TASK (linux/input-event-codes.h); other button codes
/// get click_count 1.
const btn_left: u32 = 0x110;
const mouse_button_count = 8;

const ClickState = struct {
    last_ms: i64 = 0,
    count: u8 = 0,
};

/// libinput dispatch for one seat. Create with `init`, place at a stable
/// address, then `setSink` (required), optionally `hotplug` /
/// `attachRepeatTimer`, register `fd()` in the Loop and call `dispatch()`
/// on readiness (and once after init to pick up the initial devices).
pub const Input = struct {
    allocator: std.mem.Allocator,
    ops: LibinputOps,
    li: *Libinput,
    udev: *Udev,
    poll_fd: std.posix.fd_t,
    keymap: *xkb.Keymap,
    /// Exposed for keymap reloads (locale1, M6.5): `input.state.reload`.
    state: xkb.State,
    compose: ?*xkb.Compose,
    cfg: *const config.Config,

    sink: ?EventSink = null,
    userdata: usize = 0,
    hotplug: ?HotplugHook = null,

    devices: std.ArrayListUnmanaged(DeviceInfo) = .empty,

    /// Accumulated pointer position (relative devices) or last absolute
    /// position; carried on button events.
    ptr_x: f64 = 0,
    ptr_y: f64 = 0,
    /// Output size in pixels for absolute-pointer transformation (M5.7);
    /// 0 = unknown, absolute coords stay in device space.
    screen_w: u32 = 0,
    screen_h: u32 = 0,
    clicks: [mouse_button_count]ClickState = @splat(.{}),
    /// Monotonic millisecond clock; injectable for hermetic click tests.
    now_ms: *const fn () i64 = monotonicNowMs,
    /// Physical key-state source for the resume re-sync: fills the buffer
    /// with the evdev codes currently depressed and returns the count. The
    /// default queries EVIOCGKEY on the evdev fds libinput opened through
    /// `interface`; hermetic tests inject a fake (no real devices there).
    physical_keys: *const fn (buf: []u32) usize = realPhysicalKeys,

    repeat_timer: ?RepeatTimerOps = null,
    repeat_cfg: xkb.RepeatConfig,
    /// Evdev code of the key currently repeating; null when idle.
    repeat: ?u32 = null,

    /// True between `suspend_` and `resume_` (seat inactive): `dispatch` is a
    /// no-op so no evdev input reaches the sink while the seat is away.
    suspended: bool = false,

    /// Set by `deinit`; the only field left readable after the undefined
    /// poisoning, so a second deinit is a no-op.
    deinited: bool = false,

    /// Create the udev context, assign seat "seat0" and build the xkb
    /// state (+ optional Compose from cfg). `keymap` and `cfg` are
    /// borrowed and must outlive the Input.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        keymap: *xkb.Keymap,
        cfg: *const config.Config,
        ops: LibinputOps,
    ) !Input {
        const udev = ops.udev_new() orelse return error.UdevContextFailed;
        errdefer _ = ops.udev_unref(udev);
        const li = ops.udev_create_context(&interface, null, udev) orelse
            return error.LibinputContextFailed;
        errdefer _ = ops.unref(li);
        if (ops.udev_assign_seat(li, "seat0") < 0) return error.AssignSeatFailed;
        const poll_fd = ops.get_fd(li);
        if (poll_fd < 0) return error.InvalidFd;

        var state = try xkb.State.init(keymap);
        errdefer state.deinit();
        const compose = try initCompose(io, allocator, cfg);
        errdefer if (compose) |cp| {
            cp.deinit();
            allocator.destroy(cp);
        };
        if (compose) |cp| state.setCompose(cp);

        return .{
            .allocator = allocator,
            .ops = ops,
            .li = li,
            .udev = udev,
            .poll_fd = poll_fd,
            .keymap = keymap,
            .state = state,
            .compose = compose,
            .cfg = cfg,
            .repeat_cfg = xkb.RepeatConfig.fromKmsconMs(cfg.xkb_repeat_delay, cfg.xkb_repeat_rate),
        };
    }

    /// Release everything, idempotently: a second call is a no-op. Device
    /// references are dropped first, then the libinput context (which
    /// removes the devices and closes their fds through the interface),
    /// then the udev context. The repeat timer is owned by the caller
    /// (deinit it after this call; the Loop outlives both).
    pub fn deinit(self: *Input) void {
        if (self.deinited) return;
        self.repeat = null;
        for (self.devices.items) |d| _ = self.ops.device_unref(d.device);
        self.devices.deinit(self.allocator);
        self.state.deinit();
        if (self.compose) |cp| {
            cp.deinit();
            self.allocator.destroy(cp);
        }
        _ = self.ops.unref(self.li);
        _ = self.ops.udev_unref(self.udev);
        self.* = undefined;
        self.deinited = true;
    }

    /// The epoll-ready fd (libinput_get_fd). Register EPOLLIN and call
    /// dispatch() when readable.
    pub fn fd(self: *const Input) std.posix.fd_t {
        return self.poll_fd;
    }

    /// Install the event sink. Required before the first dispatch().
    /// `userdata` is handed back verbatim; take it from the Input's final
    /// address (or any stable context).
    pub fn setSink(self: *Input, sink: EventSink, userdata: usize) void {
        self.sink = sink;
        self.userdata = userdata;
    }

    /// Install the repeat-timer seam. Without it keys do not repeat.
    /// The timer stays owned by the caller.
    pub fn attachRepeatTimer(self: *Input, timer: RepeatTimerOps) void {
        self.repeat_timer = timer;
    }

    /// Tracked devices in hotplug order.
    pub fn deviceList(self: *const Input) []const DeviceInfo {
        return self.devices.items;
    }

    /// libinput_dispatch + drain the event queue, converting every
    /// event. Call on fd readiness and once after init (initial
    /// DEVICE_ADDED events). No-op while suspended (seat inactive).
    /// Errors: NoSink when setSink was not called, DispatchFailed on
    /// libinput_dispatch < 0, plus timer/append errors.
    pub fn dispatch(self: *Input) !void {
        if (self.suspended) return;
        if (self.sink == null) return error.NoSink;
        if (self.ops.dispatch(self.li) < 0) return error.DispatchFailed;
        while (self.ops.get_event(self.li)) |ev| {
            defer self.ops.event_destroy(ev);
            switch (self.ops.event_get_type(ev)) {
                event.keyboard_key => try self.handleKey(ev),
                event.pointer_motion => self.handleMotion(ev, false),
                event.pointer_motion_absolute => self.handleMotion(ev, true),
                event.pointer_button => self.handleButton(ev),
                event.pointer_scroll_wheel,
                event.pointer_scroll_finger,
                event.pointer_scroll_continuous,
                => self.handleAxis(ev),
                event.device_added => try self.handleDeviceAdded(ev),
                event.device_removed => self.handleDeviceRemoved(ev),
                // Legacy POINTER_AXIS is ignored (the SCROLL_* events
                // carry the same scrolls); touch/tablet/gesture/switch
                // are out of scope.
                else => {},
            }
        }
    }

    /// Suspend device monitoring (the seat deactivated): libinput closes
    /// every evdev fd, so no input is read while the seat is inactive.
    /// Disarms key repeat and drops events queued before the switch so they
    /// cannot leak into the session on return; device removals are still
    /// tracked. Idempotent. The sink owner's seat-ownership gate is the
    /// backstop if a backend cannot suspend.
    pub fn suspend_(self: *Input) !void {
        if (self.suspended) return;
        self.ops.suspend_(self.li);
        self.suspended = true;
        // Drain the queue: keep device tracking in sync (DEVICE_REMOVED)
        // and discard stale key/pointer events from before the switch.
        // Only device_removed is processed (it cannot fail), so the queue
        // is always emptied even if the repeat disarm below errors.
        while (self.ops.get_event(self.li)) |ev| {
            defer self.ops.event_destroy(ev);
            if (self.ops.event_get_type(ev) == event.device_removed) {
                self.handleDeviceRemoved(ev);
            }
        }
        try self.stopRepeat();
    }

    /// Resume device monitoring (the seat activated): libinput re-opens the
    /// devices and queues DEVICE_ADDED. Queued events do not make the poll
    /// fd readable, so drain once here (like the initial dispatch after
    /// init). Idempotent; a failed resume keeps the input suspended.
    pub fn resume_(self: *Input) !void {
        if (!self.suspended) return;
        if (self.ops.resume_(self.li) < 0) return error.ResumeFailed;
        self.suspended = false;
        // Re-sync the xkb state with the PHYSICAL key state. suspend_
        // dropped the VT-switch chord's releases, so stale modifiers must
        // go; but the user may still hold Ctrl+Alt from the chord that
        // switched TO us, and those must stay depressed or Ctrl+Alt+Fn
        // can never switch away again. libinput discards its key-state
        // sync on resume (evdev_device_resume: "Our device is in a neutral
        // state already"), so query the devices directly (EVIOCGKEY)
        // instead of resetting blind.
        var down: [key_max + 1]u32 = undefined;
        const n = self.physical_keys(&down);
        self.state.resyncPhysical(down[0..n]);
        if (self.compose) |cp| cp.reset();
        try self.dispatch();
    }

    // -- keyboard ----------------------------------------------------------

    fn handleKey(self: *Input, ev: *Event) !void {
        const code = self.ops.keyboard_get_key(ev);
        const pressed = self.ops.keyboard_get_key_state(ev) == key_state.pressed;
        // null: Compose is composing/cancelled — no event (kmscon -ENOKEY).
        const kev = self.state.processKey(code, pressed) orelse return;

        if (pressed) {
            // A repeatable press takes over the repeat. Non-repeatable
            // presses (modifiers, locks, function keys) leave a running
            // repeat alone: they change how the held key translates, not
            // whether it repeats.
            if (self.keymap.shouldRepeat(code)) try self.startRepeat(code);
        } else if (self.repeat) |repeating| {
            if (repeating == code) try self.stopRepeat();
        }

        const action: u8 = if (pressed)
            @intFromEnum(kt.GhosttyKeyAction.press)
        else
            @intFromEnum(kt.GhosttyKeyAction.release);
        self.emitKey(kev, action);
    }

    /// Grab check first (presses and repeats only), then the key event.
    fn emitKey(self: *Input, kev: xkb.KeyEvent, action: u8) void {
        if (action != @intFromEnum(kt.GhosttyKeyAction.release)) {
            if (self.matchGrab(kev.mods, kev.keysym)) |id| {
                self.emit(.{ .grab = .{ .id = @intFromEnum(id) } });
                return;
            }
        }
        self.emit(.{ .key = .{
            .ghostty_key = @intFromEnum(kev.ghostty_key),
            .mods = kev.mods,
            .consumed_mods = kev.consumed_mods,
            .action = action,
            .utf8 = kev.utf8,
            .unshifted_codepoint = kev.unshifted_codepoint,
        } });
    }

    /// Arm repeat for `code`. Only the physical key is stored: every repeat
    /// is translated against the state current at that moment.
    fn startRepeat(self: *Input, code: u32) !void {
        const timer = self.repeat_timer orelse return;
        try self.stopRepeat();
        self.repeat = code;
        // One arm covers both phases: first fire after the delay, then
        // every rate interval (timerfd it_value + it_interval).
        const delay_ns = @as(u64, self.repeat_cfg.delay_ms) * std.time.ns_per_ms;
        const interval_ns = std.time.ns_per_s / self.repeat_cfg.rate_hz;
        try timer.arm(timer.ctx, delay_ns, interval_ns);
    }

    fn stopRepeat(self: *Input) !void {
        if (self.repeat == null) return;
        self.repeat = null;
        if (self.repeat_timer) |t| try t.disarm(t.ctx);
    }

    /// Forward timer expirations here (the owner's timer callback calls
    /// this with the expiration count; timerfd coalesces after a stall,
    /// so one repeat is emitted per expiration). Each repeat is translated
    /// afresh from the current xkb state — text, modifiers, keysym and
    /// consumed mods all follow modifier changes while the key is held —
    /// and without synthetic key transitions or Compose replay. Requires
    /// the sink to be set.
    pub fn repeatExpired(self: *Input, expirations: u64) void {
        const code = self.repeat orelse return;
        var i: u64 = 0;
        while (i < expirations) : (i += 1) {
            self.emitKey(self.state.translateKey(code), @intFromEnum(kt.GhosttyKeyAction.repeat));
        }
    }

    // -- grabs ---------------------------------------------------------------

    /// The 13 grabs in config order; first match wins.
    const grab_table = [_]struct { field: []const u8, id: GrabId }{
        .{ .field = "grab_scroll_up", .id = .scroll_up },
        .{ .field = "grab_scroll_down", .id = .scroll_down },
        .{ .field = "grab_page_up", .id = .page_up },
        .{ .field = "grab_page_down", .id = .page_down },
        .{ .field = "grab_zoom_in", .id = .zoom_in },
        .{ .field = "grab_zoom_out", .id = .zoom_out },
        .{ .field = "grab_session_next", .id = .session_next },
        .{ .field = "grab_session_prev", .id = .session_prev },
        .{ .field = "grab_session_close", .id = .session_close },
        .{ .field = "grab_terminal_new", .id = .terminal_new },
        .{ .field = "grab_rotate_cw", .id = .rotate_cw },
        .{ .field = "grab_rotate_ccw", .id = .rotate_ccw },
        .{ .field = "grab_reboot", .id = .reboot },
    };

    fn matchGrab(self: *const Input, mods: kt.GhosttyMods, keysym: u32) ?GrabId {
        const m = grabMods(mods);
        var sym_buf: [1]u32 = undefined;
        const syms: []const u32 = if (keysym != 0) blk: {
            sym_buf[0] = keysym;
            break :blk &sym_buf;
        } else &.{};
        inline for (grab_table) |entry| {
            if (@field(self.cfg, entry.field).matches(m, syms)) return entry.id;
        }
        return null;
    }

    /// GhosttyMods -> the five kmscon grab bits (shl/misc.h:509-531).
    /// Side bits and NumLock do not participate in grab matching.
    fn grabMods(mods: kt.GhosttyMods) u5 {
        var m: u5 = 0;
        if (mods & kt.mod_shift != 0) m |= config.grab.shift;
        if (mods & kt.mod_caps_lock != 0) m |= config.grab.lock;
        if (mods & kt.mod_ctrl != 0) m |= config.grab.control;
        if (mods & kt.mod_alt != 0) m |= config.grab.alt;
        if (mods & kt.mod_super != 0) m |= config.grab.logo;
        return m;
    }

    // -- pointer -------------------------------------------------------------

    fn handleMotion(self: *Input, ev: *Event, absolute: bool) void {
        if (!self.cfg.mouse) return;
        var dx: f64 = 0;
        var dy: f64 = 0;
        if (absolute) {
            const x = if (self.screen_w != 0)
                self.ops.pointer_get_absolute_x_transformed(ev, self.screen_w)
            else
                self.ops.pointer_get_absolute_x(ev);
            const y = if (self.screen_h != 0)
                self.ops.pointer_get_absolute_y_transformed(ev, self.screen_h)
            else
                self.ops.pointer_get_absolute_y(ev);
            dx = x - self.ptr_x;
            dy = y - self.ptr_y;
            self.ptr_x = x;
            self.ptr_y = y;
        } else {
            // Relative device: accumulate the libinput deltas, but clamp the
            // running position to the canvas. Without the clamp the
            // accumulator drifts arbitrarily far past an edge, so the pointer
            // sticks there and needs excess reverse motion to come back (the
            // model clamps only the displayed position, not this accumulator).
            // Report the effective (post-clamp) delta so x/y and dx/dy agree.
            const old_x = self.ptr_x;
            const old_y = self.ptr_y;
            self.ptr_x = clampPointerAxis(old_x + self.ops.pointer_get_dx(ev), self.screen_w);
            self.ptr_y = clampPointerAxis(old_y + self.ops.pointer_get_dy(ev), self.screen_h);
            dx = self.ptr_x - old_x;
            dy = self.ptr_y - old_y;
        }
        self.emit(.{ .pointer_motion = .{
            .dx = dx,
            .dy = dy,
            .absolute = absolute,
            .x = self.ptr_x,
            .y = self.ptr_y,
        } });
    }

    /// Clamp one accumulated pointer coordinate to [0, extent - 1]. An extent
    /// of 0 means the canvas size is not yet known, so the value passes
    /// through unchanged (relative motion then accumulates unbounded, as the
    /// hermetic tests expect). NaN parks at the origin so a poisoned delta
    /// cannot run the pointer away.
    fn clampPointerAxis(v: f64, extent: u32) f64 {
        if (extent == 0) return v;
        if (std.math.isNan(v)) return 0;
        const max: f64 = @floatFromInt(extent - 1);
        return @max(0.0, @min(v, max));
    }

    /// Clamp one scroll axis value: a hostile evdev device can report
    /// arbitrary deltas, and the terminal session converts the
    /// accumulated scroll into an integer line count, so unbounded
    /// input is a crash vector. NaN parks at zero like the pointer
    /// clamp; 1000 is far above any real detent (wheel reports +/-15).
    fn clampAxis(v: f64) f64 {
        if (std.math.isNan(v)) return 0;
        return std.math.clamp(v, -1000.0, 1000.0);
    }

    /// Set the output size in pixels: absolute (tablet) coordinates are
    /// transformed to framebuffer pixels (M5.7 absolute-pointer transform),
    /// and relative motion is clamped to it so the accumulator cannot drift
    /// past the canvas edge.
    pub fn setScreenSize(self: *Input, w: u32, h: u32) void {
        self.screen_w = w;
        self.screen_h = h;
    }

    fn handleButton(self: *Input, ev: *Event) void {
        if (!self.cfg.mouse) return;
        const button = self.ops.pointer_get_button(ev);
        const pressed = self.ops.pointer_get_button_state(ev) == button_state.pressed;
        var count: u8 = 1;
        if (buttonIndex(button)) |i| {
            const click = &self.clicks[i];
            if (pressed) {
                const now = self.now_ms();
                if (click.count > 0 and now - click.last_ms <= double_click_window_ms) {
                    count = @min(click.count + 1, 3);
                }
                click.last_ms = now;
                click.count = count;
            } else if (click.count > 0) {
                count = click.count;
            }
        }
        self.emit(.{ .pointer_button = .{
            .button = button,
            .pressed = pressed,
            .x = self.ptr_x,
            .y = self.ptr_y,
            .click_count = count,
        } });
    }

    fn handleAxis(self: *Input, ev: *Event) void {
        if (!self.cfg.mouse) return;
        var dx = clampAxis(self.ops.pointer_get_axis_value(ev, axis.horizontal));
        var dy = clampAxis(self.ops.pointer_get_axis_value(ev, axis.vertical));
        if (self.cfg.natural_scrolling) {
            dx = -dx;
            dy = -dy;
        }
        if (dx == 0 and dy == 0) return; // scroll stop
        self.emit(.{ .pointer_axis = .{ .dx = dx, .dy = dy } });
    }

    fn buttonIndex(button: u32) ?usize {
        if (button >= btn_left and button < btn_left + mouse_button_count)
            return button - btn_left;
        return null;
    }

    // -- devices -------------------------------------------------------------

    fn handleDeviceAdded(self: *Input, ev: *Event) !void {
        const dev = self.ops.event_get_device(ev) orelse return;
        _ = self.ops.device_ref(dev);
        errdefer _ = self.ops.device_unref(dev);
        const info = DeviceInfo{
            .device = dev,
            .name = if (self.ops.device_get_name(dev)) |n| std.mem.span(n) else "",
            .keyboard = self.ops.device_has_capability(dev, cap.keyboard) != 0,
            .pointer = self.ops.device_has_capability(dev, cap.pointer) != 0,
        };
        try self.devices.append(self.allocator, info);
        if (self.hotplug) |h| h.callback(h.userdata, info, true);
    }

    fn handleDeviceRemoved(self: *Input, ev: *Event) void {
        const dev = self.ops.event_get_device(ev) orelse return;
        for (self.devices.items, 0..) |d, i| {
            if (d.device == dev) {
                if (self.hotplug) |h| h.callback(h.userdata, d, false);
                _ = self.devices.orderedRemove(i);
                _ = self.ops.device_unref(dev);
                return;
            }
        }
    }

    fn emit(self: *Input, e: session.InputEvent) void {
        // dispatch() rejects a missing sink; repeats only run after a
        // successful dispatch, so the sink is always set here.
        (self.sink.?)(self.userdata, e);
    }
};

// ---------------------------------------------------------------------------
// Real interface + helpers
// ---------------------------------------------------------------------------

/// Passed to every udev_create_context call; libinput opens device nodes
/// through it. Plain syscalls, no libc symbols — safe to analyze in
/// hermetic builds. Static storage: libinput stores the pointer for the
/// context lifetime (see `Interface`), so this must never become a local.
pub const interface = Interface{
    .open_restricted = openRestricted,
    .close_restricted = closeRestricted,
};

fn openRestricted(path: [*c]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = user_data;
    const path_z: [*:0]const u8 = @ptrCast(path);
    const o: linux.O = @bitCast(@as(u32, @bitCast(flags)));
    const rc = linux.openat(linux.AT.FDCWD, path_z, o, 0);
    const e = linux.errno(rc);
    if (e == .SUCCESS) {
        trackFd(@intCast(rc));
        return @intCast(rc);
    }
    return -@as(c_int, @intCast(@intFromEnum(e)));
}

fn closeRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    untrackFd(fd);
    _ = linux.close(fd);
}

/// EVIOCGKEY bitmap size: KEY_MAX (0x2ff, linux/input-event-codes.h) + 1
/// bits, rounded up to bytes.
const key_max: u32 = 0x2ff;
const key_bitmap_len = (key_max + 1 + 7) / 8;

/// EVIOCGKEY(len) = _IOC(_IOC_READ, 'E', 0x18, len): the global key-state
/// bitmap of an evdev device (linux/input.h). NOT 0x06, which is EVIOCGNAME.
const eviocgkey: u32 = linux.IOCTL.IOR('E', 0x18, [key_bitmap_len]u8);

/// EVIOCGBIT(ev, len) = _IOC(_IOC_READ, 'E', 0x20 + ev, len): the device's
/// capability bitmap for event type `ev` (0 = the event-type bitmap itself).
const eviocgbit_ev: u32 = linux.IOCTL.IOR('E', 0x20, [8]u8);
const eviocgbit_key: u32 = linux.IOCTL.IOR('E', 0x21, [key_bitmap_len]u8);

comptime {
    std.debug.assert(eviocgkey == 0x80604518);
}

fn bitSet(bits: []const u8, code: u32) bool {
    return bits[code / 8] & (@as(u8, 1) << @intCast(code % 8)) != 0;
}

/// Whether the evdev fd is a keyboard: it must report EV_KEY and the letter
/// keys Q/A/Z. Non-keyboard devices (mice, tablets, ACPI buttons) also answer
/// EVIOCGKEY, but their bitmaps carry button/tool codes — unioning those into
/// the key state would press spurious modifiers on resume.
fn isKeyboard(fd: std.posix.fd_t) bool {
    var evbits: [8]u8 = @splat(0);
    if (linux.errno(linux.ioctl(fd, eviocgbit_ev, @intFromPtr(&evbits))) != .SUCCESS) return false;
    if (!bitSet(&evbits, 1)) return false; // EV_KEY
    var keybits: [key_bitmap_len]u8 = @splat(0);
    if (linux.errno(linux.ioctl(fd, eviocgbit_key, @intFromPtr(&keybits))) != .SUCCESS) return false;
    return bitSet(&keybits, kt.key_code.key_q) and
        bitSet(&keybits, kt.key_code.key_a) and
        bitSet(&keybits, kt.key_code.key_z);
}

/// evdev fds libinput opened through `interface`, tracked so `resume_` can
/// query the physical key state (EVIOCGKEY): libinput exposes no device-fd
/// getter. One Input per process (seat workers are separate processes), so
/// a module-level table is safe. Fixed-size: a seat opens a handful of
/// nodes; an fd that does not fit is simply not tracked (the resume re-sync
/// then sees fewer devices, never a wrong key state).
const max_tracked_fds = 64;
var tracked_fds: [max_tracked_fds]std.posix.fd_t = @splat(-1);

fn trackFd(fd: std.posix.fd_t) void {
    for (&tracked_fds) |*slot| {
        if (slot.* < 0) {
            slot.* = fd;
            return;
        }
    }
}

fn untrackFd(fd: std.posix.fd_t) void {
    for (&tracked_fds) |*slot| {
        if (slot.* == fd) {
            slot.* = -1;
            return;
        }
    }
}

/// Fill `buf` with the evdev codes physically depressed on the tracked
/// devices (the EVIOCGKEY bitmaps unioned) and return the count. Devices
/// that cannot be queried are skipped; no tracked device means an empty
/// result, which makes the resume re-sync clear all stale modifiers.
///
/// EVIOCGKEY flushes pending EV_KEY events from the queried fd's queue
/// (kernel evdev_handle_get_val), so this MUST run immediately after
/// libinput_resume — which drained the fds — and before dispatch: the
/// queue is empty then, and the bitmap is the physical truth. (kmscon
/// reverted its EVIOCGKEY re-sync, e083e3c, because its async wake-up
/// raced queued events; the synchronous drain-query-dispatch order here
/// leaves no such window.)
fn realPhysicalKeys(buf: []u32) usize {
    var bitmap: [key_bitmap_len]u8 = @splat(0);
    var any = false;
    for (tracked_fds) |fd| {
        if (fd < 0) continue;
        if (!isKeyboard(fd)) continue;
        var b: [key_bitmap_len]u8 = @splat(0);
        const rc = linux.ioctl(fd, eviocgkey, @intFromPtr(&b));
        if (linux.errno(rc) != .SUCCESS) continue;
        // KEY_RESERVED (code 0) is never a real key: a device reporting it
        // depressed is returning an uninitialized/garbage key bitmap (e.g. a
        // secondary raw keyboard node). Skip it rather than press its keys.
        if (b[0] & 1 != 0) continue;
        for (&bitmap, b) |*dst, src| dst.* |= src;
        any = true;
    }
    if (!any) return 0;
    var n: usize = 0;
    for (bitmap, 0..) |byte, i| {
        var bits = byte;
        while (bits != 0) : (bits &= bits - 1) {
            if (n == buf.len) return n;
            buf[n] = @intCast(i * 8 + @as(usize, @ctz(bits)));
            n += 1;
        }
    }
    return n;
}

fn monotonicNowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Compose is optional (kmscon parity): a missing/broken table disables
/// it, input continues. OutOfMemory propagates. The Compose is heap-
/// allocated so State.compose stays valid after Input is moved.
fn initCompose(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
) error{OutOfMemory}!?*xkb.Compose {
    const cp = try allocator.create(xkb.Compose);
    cp.* = xkb.Compose.init(io, allocator, composeLocale(), cfg.xkb_compose_file) catch |err| {
        allocator.destroy(cp);
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
    return cp;
}

/// kmscon seat.c:590-599: LC_ALL, then LC_CTYPE, then LANG, then "C".
fn composeLocale() []const u8 {
    for ([_][:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
        if (std.c.getenv(name.ptr)) |value| {
            const s = std.mem.span(value);
            if (s.len > 0) return s;
        }
    }
    return "C";
}
