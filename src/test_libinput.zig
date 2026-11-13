//! src/test_libinput.zig -- hermetic tests for the libinput dispatch layer.
//!
//! `src/input/libinput.zig` imports `../session.zig`, so the module root
//! must be `src/`; run this root instead of the backend file. The fake
//! `LibinputOps` below feeds a pre-queued event list — no devices, no
//! udev, no seat daemon. Key conversion uses a REAL xkb.Keymap (us
//! layout, headless), so the xkb-c module and libxkbcommon are linked.
//! `LibinputOps.real` is referenced only by the final binding test (no
//! calls), which is why the command also wires libinput-c/-linput/-ludev.
//!
//! Exact command (paths from `nix build --print-out-paths --no-link` of
//! nixpkgs#libinput.dev, nixpkgs#libinput, nixpkgs#systemd.dev,
//! nixpkgs#systemd, nixpkgs#libxkbcommon.dev, nixpkgs#libxkbcommon,
//! nixpkgs#xkeyboard_config, nixpkgs#libx11; shims and translate-c steps
//! in the src/input/libinput.zig header):
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
test {
    _ = @import("input/libinput.zig");
}

const std = @import("std");
const libinput = @import("input/libinput.zig");
const xkb = @import("input/xkb.zig");
const kt = @import("input/keymap_table.zig");
const config = @import("config/config.zig");
const session = @import("session.zig");

const testing = std.testing;
const linux = std.os.linux;

// ---------------------------------------------------------------------------
// Fake libinput backend
// ---------------------------------------------------------------------------

/// Stand-in for `struct libinput_device`: capabilities as a bitmask
/// (bit 0 keyboard, bit 1 pointer) and a reference counter so tests can
/// assert the dispatch layer refs/unrefs correctly.
const FakeDevice = struct {
    name: [:0]const u8,
    caps: u8,
    refs: usize = 0,
};

/// One queued event. The getters read these fields; `device` is the
/// FakeDevice cast to the opaque seam type.
const FakeEvent = struct {
    type: c_int,
    device: ?*libinput.Device = null,
    key: u32 = 0,
    key_state: c_int = 0,
    dx: f64 = 0,
    dy: f64 = 0,
    abs_x: f64 = 0,
    abs_y: f64 = 0,
    button: u32 = 0,
    button_state: c_int = 0,
    axis_v: f64 = 0,
    axis_h: f64 = 0,
};

/// udev_new() takes no arguments, so the fake under construction is
/// published here for the duration of Input.init. Tests are
/// single-threaded; every other seam call recovers the Fake from the
/// opaque pointers it receives.
var active_fake: ?*Fake = null;

const Fake = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayListUnmanaged(*FakeEvent) = .empty,
    dispatch_calls: usize = 0,
    destroyed: usize = 0,
    poll_fd: c_int = 77,
    seat: [16]u8 = undefined,
    seat_len: usize = 0,
    udev_fails: bool = false,
    context_fails: bool = false,
    seat_fails: bool = false,
    dispatch_fails: bool = false,

    fn init(allocator: std.mem.Allocator) Fake {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Fake) void {
        for (self.queue.items) |p| self.allocator.destroy(p);
        self.queue.deinit(self.allocator);
    }

    fn push(self: *Fake, e: FakeEvent) void {
        const p = self.allocator.create(FakeEvent) catch @panic("fake: oom");
        p.* = e;
        self.queue.append(self.allocator, p) catch @panic("fake: oom");
    }

    fn pushKey(self: *Fake, code: u32, pressed: bool) void {
        self.push(.{
            .type = libinput.event.keyboard_key,
            .key = code,
            .key_state = if (pressed) libinput.key_state.pressed else libinput.key_state.released,
        });
    }

    fn pushMotion(self: *Fake, dx: f64, dy: f64) void {
        self.push(.{ .type = libinput.event.pointer_motion, .dx = dx, .dy = dy });
    }

    fn pushAbsolute(self: *Fake, x: f64, y: f64) void {
        self.push(.{ .type = libinput.event.pointer_motion_absolute, .abs_x = x, .abs_y = y });
    }

    fn pushButton(self: *Fake, button: u32, pressed: bool) void {
        self.push(.{
            .type = libinput.event.pointer_button,
            .button = button,
            .button_state = if (pressed) libinput.button_state.pressed else libinput.button_state.released,
        });
    }

    fn pushScroll(self: *Fake, kind: c_int, vertical: f64, horizontal: f64) void {
        self.push(.{ .type = kind, .axis_v = vertical, .axis_h = horizontal });
    }

    fn pushDevice(self: *Fake, kind: c_int, dev: *FakeDevice) void {
        self.push(.{ .type = kind, .device = @ptrCast(dev) });
    }

    fn seatName(self: *const Fake) []const u8 {
        return self.seat[0..self.seat_len];
    }

    fn ops(self: *Fake) libinput.LibinputOps {
        _ = self;
        return .{
            .udev_new = fakeUdevNew,
            .udev_unref = fakeUdevUnref,
            .udev_create_context = fakeUdevCreateContext,
            .udev_assign_seat = fakeAssignSeat,
            .unref = fakeUnref,
            .get_fd = fakeGetFd,
            .dispatch = fakeDispatch,
            .get_event = fakeGetEvent,
            .event_destroy = fakeEventDestroy,
            .event_get_type = fakeEventGetType,
            .event_get_device = fakeEventGetDevice,
            .keyboard_get_key = fakeKeyboardGetKey,
            .keyboard_get_key_state = fakeKeyboardGetKeyState,
            .pointer_get_dx = fakePointerGetDx,
            .pointer_get_dy = fakePointerGetDy,
            .pointer_get_absolute_x = fakePointerGetAbsoluteX,
            .pointer_get_absolute_y = fakePointerGetAbsoluteY,
            .pointer_get_button = fakePointerGetButton,
            .pointer_get_button_state = fakePointerGetButtonState,
            .pointer_get_axis_value = fakePointerGetAxisValue,
            .device_has_capability = fakeDeviceHasCapability,
            .device_ref = fakeDeviceRef,
            .device_unref = fakeDeviceUnref,
            .device_get_name = fakeDeviceGetName,
        };
    }
};

fn fromUdev(p: *libinput.Udev) *Fake {
    return @ptrCast(@alignCast(p));
}
fn fromLi(p: *libinput.Libinput) *Fake {
    return @ptrCast(@alignCast(p));
}
fn fromEv(p: *libinput.Event) *FakeEvent {
    return @ptrCast(@alignCast(p));
}
fn fromDev(p: *libinput.Device) *FakeDevice {
    return @ptrCast(@alignCast(p));
}

fn fakeUdevNew() callconv(.c) ?*libinput.Udev {
    const f = active_fake orelse return null;
    if (f.udev_fails) return null;
    return @ptrCast(f);
}

fn fakeUdevUnref(udev: *libinput.Udev) callconv(.c) ?*libinput.Udev {
    _ = fromUdev(udev);
    return null;
}

fn fakeUdevCreateContext(interface: *const libinput.Interface, user_data: ?*anyopaque, udev: *libinput.Udev) callconv(.c) ?*libinput.Libinput {
    _ = interface;
    _ = user_data;
    const f = fromUdev(udev);
    if (f.context_fails) return null;
    return @ptrCast(f);
}

fn fakeAssignSeat(li: *libinput.Libinput, seat_id: [*:0]const u8) callconv(.c) c_int {
    const f = fromLi(li);
    const s = std.mem.span(seat_id);
    @memcpy(f.seat[0..s.len], s);
    f.seat_len = s.len;
    return if (f.seat_fails) -1 else 0;
}

fn fakeUnref(li: *libinput.Libinput) callconv(.c) ?*libinput.Libinput {
    _ = fromLi(li);
    return null;
}

fn fakeGetFd(li: *libinput.Libinput) callconv(.c) c_int {
    return fromLi(li).poll_fd;
}

fn fakeDispatch(li: *libinput.Libinput) callconv(.c) c_int {
    const f = fromLi(li);
    f.dispatch_calls += 1;
    return if (f.dispatch_fails) -1 else 0;
}

fn fakeGetEvent(li: *libinput.Libinput) callconv(.c) ?*libinput.Event {
    const f = fromLi(li);
    if (f.queue.items.len == 0) return null;
    return @ptrCast(f.queue.orderedRemove(0));
}

fn fakeEventDestroy(ev: *libinput.Event) callconv(.c) void {
    const f = active_fake.?;
    f.destroyed += 1;
    f.allocator.destroy(fromEv(ev));
}

fn fakeEventGetType(ev: *libinput.Event) callconv(.c) c_int {
    return fromEv(ev).type;
}

fn fakeEventGetDevice(ev: *libinput.Event) callconv(.c) ?*libinput.Device {
    return fromEv(ev).device;
}

fn fakeKeyboardGetKey(ev: *libinput.Event) callconv(.c) u32 {
    return fromEv(ev).key;
}

fn fakeKeyboardGetKeyState(ev: *libinput.Event) callconv(.c) c_int {
    return fromEv(ev).key_state;
}

fn fakePointerGetDx(ev: *libinput.Event) callconv(.c) f64 {
    return fromEv(ev).dx;
}

fn fakePointerGetDy(ev: *libinput.Event) callconv(.c) f64 {
    return fromEv(ev).dy;
}

fn fakePointerGetAbsoluteX(ev: *libinput.Event) callconv(.c) f64 {
    return fromEv(ev).abs_x;
}

fn fakePointerGetAbsoluteY(ev: *libinput.Event) callconv(.c) f64 {
    return fromEv(ev).abs_y;
}

fn fakePointerGetButton(ev: *libinput.Event) callconv(.c) u32 {
    return fromEv(ev).button;
}

fn fakePointerGetButtonState(ev: *libinput.Event) callconv(.c) c_int {
    return fromEv(ev).button_state;
}

fn fakePointerGetAxisValue(ev: *libinput.Event, which: c_int) callconv(.c) f64 {
    const e = fromEv(ev);
    return if (which == libinput.axis.vertical) e.axis_v else e.axis_h;
}

fn fakeDeviceHasCapability(dev: *libinput.Device, capability: c_int) callconv(.c) c_int {
    const d = fromDev(dev);
    const bit: u8 = @as(u8, 1) << @intCast(capability);
    return if (d.caps & bit != 0) 1 else 0;
}

fn fakeDeviceRef(dev: *libinput.Device) callconv(.c) ?*libinput.Device {
    fromDev(dev).refs += 1;
    return dev;
}

fn fakeDeviceUnref(dev: *libinput.Device) callconv(.c) ?*libinput.Device {
    fromDev(dev).refs -= 1;
    return null;
}

fn fakeDeviceGetName(dev: *libinput.Device) callconv(.c) ?[*:0]const u8 {
    return fromDev(dev).name.ptr;
}

// ---------------------------------------------------------------------------
// Fake repeat timer (RepeatTimerOps seam)
// ---------------------------------------------------------------------------

/// Records arm/disarm calls; expirations are fired manually by the test
/// through Input.repeatExpired. The real loop.Timer adapter lives in
/// main.zig (see the libinput.zig header); loop.zig itself is not
/// imported here because its SignalSource tests do not compile in
/// libc-linked builds.
const FakeTimer = struct {
    arms: std.ArrayListUnmanaged(Arm) = .empty,
    disarms: usize = 0,

    const Arm = struct { delay_ns: u64, interval_ns: u64 };

    fn deinit(self: *FakeTimer) void {
        self.arms.deinit(testing.allocator);
    }

    fn arm(ctx: ?*anyopaque, delay_ns: u64, interval_ns: u64) !void {
        const self: *FakeTimer = @ptrCast(@alignCast(ctx.?));
        try self.arms.append(testing.allocator, .{ .delay_ns = delay_ns, .interval_ns = interval_ns });
    }

    fn disarm(ctx: ?*anyopaque) !void {
        const self: *FakeTimer = @ptrCast(@alignCast(ctx.?));
        self.disarms += 1;
    }

    fn ops(self: *FakeTimer) libinput.RepeatTimerOps {
        return .{ .ctx = self, .arm = arm, .disarm = disarm };
    }

    fn lastArm(self: *const FakeTimer) Arm {
        return self.arms.items[self.arms.items.len - 1];
    }
};

// ---------------------------------------------------------------------------
// Recording sink + harness
// ---------------------------------------------------------------------------

fn monotonicMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Injected clock for deterministic double-click windows.
var fake_clock: i64 = 0;
fn fakeNowMs() i64 {
    return fake_clock;
}

/// Records every delivered event. `key.utf8` borrows the xkb buffer only
/// for the duration of the sink call, so it is duplicated here.
const Recorder = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct {
        event: session.InputEvent,
        at_ms: i64,
    };

    fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Recorder) void {
        for (self.entries.items) |e| {
            if (e.event == .key) {
                if (e.event.key.utf8) |t| self.allocator.free(t);
            }
        }
        self.entries.deinit(self.allocator);
    }

    fn sink(userdata: usize, event: session.InputEvent) void {
        const self: *Recorder = @ptrFromInt(userdata);
        var copy = event;
        if (copy == .key) {
            if (copy.key.utf8) |t| copy.key.utf8 = self.allocator.dupe(u8, t) catch @panic("recorder: oom");
        }
        self.entries.append(self.allocator, .{ .event = copy, .at_ms = monotonicMs() }) catch
            @panic("recorder: oom");
    }

    fn count(self: *const Recorder, tag: std.meta.Tag(session.InputEvent)) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (std.meta.activeTag(e.event) == tag) n += 1;
        }
        return n;
    }

    fn countAction(self: *const Recorder, action: u8) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (e.event == .key and e.event.key.action == action) n += 1;
        }
        return n;
    }

    fn countGrabs(self: *const Recorder, id: u16) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (e.event == .grab and e.event.grab.id == id) n += 1;
        }
        return n;
    }

    fn last(self: *const Recorder) session.InputEvent {
        return self.entries.items[self.entries.items.len - 1].event;
    }
};

fn nullSink(userdata: usize, event: session.InputEvent) void {
    _ = userdata;
    _ = event;
}

/// Heap-allocated so every pointer handed to the Input (sink userdata,
/// fake, keymap, cfg) stays stable.
const Harness = struct {
    km: xkb.Keymap,
    cfg: config.Config,
    fake: Fake,
    rec: Recorder,
    input: libinput.Input,

    const Opts = struct {
        km: xkb.Options = .{ .layout = "us" },
        compose_file: ?[]const u8 = null,
        repeat_delay: u32 = 250,
        repeat_rate: u32 = 50,
    };

    fn init(opts: Opts) !*Harness {
        const alloc = testing.allocator;
        const h = try alloc.create(Harness);
        errdefer alloc.destroy(h);
        h.km = try xkb.Keymap.init(testing.io, alloc, opts.km);
        errdefer h.km.deinit();
        h.cfg = config.Config.init(alloc);
        errdefer h.cfg.deinit();
        h.cfg.xkb_compose_file = opts.compose_file;
        h.cfg.xkb_repeat_delay = opts.repeat_delay;
        h.cfg.xkb_repeat_rate = opts.repeat_rate;
        h.fake = Fake.init(alloc);
        errdefer h.fake.deinit();
        h.rec = Recorder.init(alloc);
        errdefer h.rec.deinit();
        active_fake = &h.fake;
        errdefer active_fake = null;
        h.input = try libinput.Input.init(alloc, testing.io, &h.km, &h.cfg, h.fake.ops());
        h.input.setSink(Recorder.sink, @intFromPtr(&h.rec));
        return h;
    }

    fn deinit(self: *Harness) void {
        self.input.deinit();
        self.rec.deinit();
        self.fake.deinit();
        self.cfg.deinit();
        self.km.deinit();
        active_fake = null;
        testing.allocator.destroy(self);
    }
};

/// Parse a grab into a cfg field (arena-owned; freed by cfg.deinit).
fn setGrab(h: *Harness, comptime field: []const u8, arg: []const u8) !void {
    var diag = config.Diag{};
    @field(h.cfg, field) = config.Grab.parse(h.cfg.allocator(), arg, &diag) catch |err| {
        std.debug.print("grab parse '{s}' failed: {s}\n", .{ arg, diag.message() });
        return err;
    };
}

fn expectKey(e: session.InputEvent, key: kt.GhosttyKey, action: u8, utf8: ?[]const u8) !void {
    try testing.expect(e == .key);
    try testing.expectEqual(@as(u32, @intFromEnum(key)), e.key.ghostty_key);
    try testing.expectEqual(action, e.key.action);
    if (utf8) |t| {
        try testing.expectEqualStrings(t, e.key.utf8 orelse return error.TestUnexpectedResult);
    } else {
        try testing.expect(e.key.utf8 == null);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "init: udev context, seat0 assignment, poll fd" {
    const h = try Harness.init(.{});
    defer h.deinit();
    try testing.expectEqualStrings("seat0", h.fake.seatName());
    try testing.expectEqual(@as(std.posix.fd_t, 77), h.input.fd());
    try testing.expectEqual(@as(usize, 0), h.fake.dispatch_calls);
}

test "init: udev/context/seat failures are typed errors and clean up" {
    const alloc = testing.allocator;
    var km = try xkb.Keymap.init(testing.io, alloc, .{ .layout = "us" });
    defer km.deinit();
    var cfg = config.Config.init(alloc);
    defer cfg.deinit();
    var fake = Fake.init(alloc);
    defer fake.deinit();
    active_fake = &fake;
    defer active_fake = null;

    fake.udev_fails = true;
    try testing.expectError(error.UdevContextFailed, libinput.Input.init(alloc, testing.io, &km, &cfg, fake.ops()));
    fake.udev_fails = false;

    fake.context_fails = true;
    try testing.expectError(error.LibinputContextFailed, libinput.Input.init(alloc, testing.io, &km, &cfg, fake.ops()));
    fake.context_fails = false;

    fake.seat_fails = true;
    try testing.expectError(error.AssignSeatFailed, libinput.Input.init(alloc, testing.io, &km, &cfg, fake.ops()));
}

test "dispatch: requires a sink; libinput_dispatch failure propagates" {
    const alloc = testing.allocator;
    var km = try xkb.Keymap.init(testing.io, alloc, .{ .layout = "us" });
    defer km.deinit();
    var cfg = config.Config.init(alloc);
    defer cfg.deinit();
    var fake = Fake.init(alloc);
    defer fake.deinit();
    active_fake = &fake;
    defer active_fake = null;

    var input = try libinput.Input.init(alloc, testing.io, &km, &cfg, fake.ops());
    defer input.deinit();
    try testing.expectError(error.NoSink, input.dispatch());
    try testing.expectEqual(@as(usize, 0), fake.dispatch_calls);

    input.setSink(nullSink, 0);
    fake.dispatch_fails = true;
    try testing.expectError(error.DispatchFailed, input.dispatch());
    try testing.expectEqual(@as(usize, 1), fake.dispatch_calls);
}

test "keyboard: press/release, shift, ctrl through the real us keymap" {
    const h = try Harness.init(.{});
    defer h.deinit();

    h.fake.pushKey(kt.key_code.key_a, true);
    h.fake.pushKey(kt.key_code.key_a, false);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 2), h.rec.entries.items.len);
    try expectKey(h.rec.entries.items[0].event, .a, 1, "a");
    try testing.expectEqual(@as(?u21, 'a'), h.rec.entries.items[0].event.key.unshifted_codepoint);
    try testing.expectEqual(@as(u16, 0), h.rec.entries.items[0].event.key.mods);
    try expectKey(h.rec.entries.items[1].event, .a, 0, null);

    h.fake.pushKey(kt.key_code.key_leftshift, true);
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    const shifted = h.rec.last();
    try expectKey(shifted, .a, 1, "A");
    try testing.expectEqual(kt.mod_shift, shifted.key.mods);

    h.fake.pushKey(kt.key_code.key_a, false);
    h.fake.pushKey(kt.key_code.key_leftshift, false);
    h.fake.pushKey(kt.key_code.key_leftctrl, true);
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    const controlled = h.rec.last();
    try expectKey(controlled, .a, 1, "\x01");
    try testing.expectEqual(kt.mod_ctrl, controlled.key.mods);

    // Every queued event was destroyed exactly once.
    try testing.expectEqual(@as(usize, 8), h.fake.destroyed);
    try testing.expectEqual(@as(usize, 3), h.fake.dispatch_calls);
}

test "compose: dead-key sequence suppresses keys, then emits composed text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/Compose", .{tmp.sub_path[0..]});
    defer testing.allocator.free(path);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "Compose",
        .data = "<dead_acute> <a> : \"á\" aacute\n",
    });

    // us(intl) puts dead_acute on the apostrophe key (evdev 40) — the
    // same setup as the xkb.zig compose integration test.
    const h = try Harness.init(.{ .km = .{ .layout = "us", .variant = "intl" }, .compose_file = path });
    defer h.deinit();
    try testing.expect(h.input.compose != null);

    // dead_acute then a: the dead-key press is swallowed, the 'a' press
    // carries the composed text.
    h.fake.pushKey(kt.key_code.key_apostrophe, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 0), h.rec.entries.items.len);
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), h.rec.entries.items.len);
    try expectKey(h.rec.last(), .a, 1, "á");

    // Releases always pass through.
    h.fake.pushKey(kt.key_code.key_a, false);
    h.fake.pushKey(kt.key_code.key_apostrophe, false);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 3), h.rec.entries.items.len);
    try expectKey(h.rec.last(), .quote, 0, null);

    // A cancelled sequence swallows the cancelling key too; plain input
    // resumes afterwards.
    h.fake.pushKey(kt.key_code.key_apostrophe, true);
    h.fake.pushKey(kt.key_code.key_x, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 3), h.rec.entries.items.len);
    h.fake.pushKey(kt.key_code.key_x, false);
    h.fake.pushKey(kt.key_code.key_apostrophe, false);
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try expectKey(h.rec.last(), .a, 1, "a");
}

test "grabs: ctrl+alt+Delete intercepts before the session; releases pass" {
    const h = try Harness.init(.{});
    defer h.deinit();
    // The kmscon-docs reboot binding. (Ctrl+Alt+F1 would NOT match with
    // the default pc keymap: it yields XF86Switch_VT_1, not F1.)
    try setGrab(h, "grab_reboot", "<Ctrl><Alt>Delete");

    h.fake.pushKey(kt.key_code.key_leftctrl, true);
    h.fake.pushKey(kt.key_code.key_leftalt, true);
    h.fake.pushKey(kt.key_code.key_delete, true);
    try h.input.dispatch();

    try testing.expectEqual(@as(usize, 3), h.rec.entries.items.len);
    try expectKey(h.rec.entries.items[0].event, .control_left, 1, null);
    try expectKey(h.rec.entries.items[1].event, .alt_left, 1, null);
    try testing.expect(h.rec.last() == .grab);
    try testing.expectEqual(@as(u16, @intFromEnum(libinput.GrabId.reboot)), h.rec.last().grab.id);
    // No key event for Delete reached the sink.
    for (h.rec.entries.items) |e| {
        if (e.event == .key) try testing.expect(e.event.key.ghostty_key != @intFromEnum(kt.GhosttyKey.delete));
    }

    // The release is NOT grabbed.
    h.fake.pushKey(kt.key_code.key_delete, false);
    try h.input.dispatch();
    try expectKey(h.rec.last(), .delete, 0, null);
}

test "grabs: defaults, exact modifier equality, dual keysyms, locks" {
    const h = try Harness.init(.{});
    defer h.deinit();

    // Default page-up: Shift+Prior.
    h.fake.pushKey(kt.key_code.key_leftshift, true);
    h.fake.pushKey(kt.key_code.key_pageup, true);
    try h.input.dispatch();
    try testing.expect(h.rec.last() == .grab);
    try testing.expectEqual(@as(u16, @intFromEnum(libinput.GrabId.page_up)), h.rec.last().grab.id);
    h.fake.pushKey(kt.key_code.key_pageup, false);
    h.fake.pushKey(kt.key_code.key_leftshift, false);

    // Dual-keysym zoom-in: Ctrl+equal matches...
    h.fake.pushKey(kt.key_code.key_leftctrl, true);
    h.fake.pushKey(kt.key_code.key_equal, true);
    try h.input.dispatch();
    try testing.expect(h.rec.last() == .grab);
    try testing.expectEqual(@as(u16, @intFromEnum(libinput.GrabId.zoom_in)), h.rec.last().grab.id);
    h.fake.pushKey(kt.key_code.key_equal, false);

    // ...but an extra Shift breaks the exact-equality match (keysym plus,
    // mods ctrl|shift), so the key event goes through.
    h.fake.pushKey(kt.key_code.key_leftshift, true);
    h.fake.pushKey(kt.key_code.key_equal, true);
    try h.input.dispatch();
    try expectKey(h.rec.last(), .equal, 1, "+");
    h.fake.pushKey(kt.key_code.key_equal, false);
    h.fake.pushKey(kt.key_code.key_leftshift, false);
    h.fake.pushKey(kt.key_code.key_leftctrl, false);

    // Caps Lock adds the lock bit: Ctrl+minus no longer matches zoom-out.
    h.fake.pushKey(kt.key_code.key_capslock, true);
    h.fake.pushKey(kt.key_code.key_capslock, false);
    h.fake.pushKey(kt.key_code.key_leftctrl, true);
    h.fake.pushKey(kt.key_code.key_minus, true);
    try h.input.dispatch();
    try expectKey(h.rec.last(), .minus, 1, "-");
    h.fake.pushKey(kt.key_code.key_minus, false);
    h.fake.pushKey(kt.key_code.key_leftctrl, false);
    h.fake.pushKey(kt.key_code.key_capslock, true);
    h.fake.pushKey(kt.key_code.key_capslock, false);

    // NumLock is NOT one of the five grab bits: Shift+Up still matches.
    h.fake.pushKey(kt.key_code.key_numlock, true);
    h.fake.pushKey(kt.key_code.key_numlock, false);
    h.fake.pushKey(kt.key_code.key_leftshift, true);
    h.fake.pushKey(kt.key_code.key_up, true);
    try h.input.dispatch();
    try testing.expect(h.rec.last() == .grab);
    try testing.expectEqual(@as(u16, @intFromEnum(libinput.GrabId.scroll_up)), h.rec.last().grab.id);
}

test "repeat: press arms delay then rate; expirations emit repeats; release disarms" {
    const h = try Harness.init(.{ .repeat_delay = 40, .repeat_rate = 20 });
    defer h.deinit();
    var timer = FakeTimer{};
    defer timer.deinit();
    h.input.attachRepeatTimer(timer.ops());

    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), h.rec.entries.items.len);
    try expectKey(h.rec.last(), .a, 1, "a");

    // One arm covers both phases: first expiration after the 40 ms
    // delay, then every 20 ms (xkb-repeat-rate is an interval, not Hz).
    try testing.expectEqual(@as(usize, 1), timer.arms.items.len);
    try testing.expectEqual(@as(u64, 40 * std.time.ns_per_ms), timer.lastArm().delay_ns);
    try testing.expectEqual(@as(u64, 20 * std.time.ns_per_ms), timer.lastArm().interval_ns);

    // The owner's timer callback forwards expirations; each becomes one
    // repeat with the press-time text (coalesced expirations are kept).
    h.input.repeatExpired(1);
    h.input.repeatExpired(3);
    try testing.expectEqual(@as(usize, 4), h.rec.countAction(2));
    for (h.rec.entries.items[1..]) |e| {
        try expectKey(e.event, .a, 2, "a");
    }

    // Release disarms and stops repeats.
    h.fake.pushKey(kt.key_code.key_a, false);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), timer.disarms);
    h.input.repeatExpired(2);
    try testing.expectEqual(@as(usize, 4), h.rec.countAction(2));
    try expectKey(h.rec.last(), .a, 0, null);
}

test "repeat: kmscon clamping of delay and rate" {
    // 0 selects the kmscon defaults (250 ms delay / 50 ms interval).
    const h = try Harness.init(.{ .repeat_delay = 0, .repeat_rate = 0 });
    defer h.deinit();
    var timer = FakeTimer{};
    defer timer.deinit();
    h.input.attachRepeatTimer(timer.ops());
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), timer.lastArm().delay_ns);
    try testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), timer.lastArm().interval_ns);

    // >= 1000 clamps to 999 ms delay and 1 Hz (1 s interval).
    const h2 = try Harness.init(.{ .repeat_delay = 1000, .repeat_rate = 1000 });
    defer h2.deinit();
    var timer2 = FakeTimer{};
    defer timer2.deinit();
    h2.input.attachRepeatTimer(timer2.ops());
    h2.fake.pushKey(kt.key_code.key_a, true);
    try h2.input.dispatch();
    try testing.expectEqual(@as(u64, 999 * std.time.ns_per_ms), timer2.lastArm().delay_ns);
    try testing.expectEqual(@as(u64, std.time.ns_per_s), timer2.lastArm().interval_ns);
}

test "repeat: text and mods are frozen at press time" {
    const h = try Harness.init(.{});
    defer h.deinit();
    var timer = FakeTimer{};
    defer timer.deinit();
    h.input.attachRepeatTimer(timer.ops());

    h.fake.pushKey(kt.key_code.key_leftshift, true);
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    h.fake.pushKey(kt.key_code.key_leftshift, false);
    try h.input.dispatch();
    // Releasing a different key must not cancel the 'a' repeat.
    try testing.expectEqual(@as(usize, 0), timer.disarms);
    h.input.repeatExpired(1);
    const rep = h.rec.last();
    try expectKey(rep, .a, 2, "A");
    try testing.expectEqual(kt.mod_shift, rep.key.mods);
}

test "repeat: non-repeatable press cancels; modifiers never arm" {
    const h = try Harness.init(.{});
    defer h.deinit();
    var timer = FakeTimer{};
    defer timer.deinit();
    h.input.attachRepeatTimer(timer.ops());

    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), timer.arms.items.len);

    // A modifier press replaces the repeat with nothing.
    h.fake.pushKey(kt.key_code.key_leftctrl, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), timer.disarms);
    try testing.expectEqual(@as(usize, 1), timer.arms.items.len);
    h.input.repeatExpired(1);
    try testing.expectEqual(@as(usize, 0), h.rec.countAction(2));

    // A lone modifier never arms; a new repeatable press re-arms.
    h.fake.pushKey(kt.key_code.key_leftctrl, false);
    h.fake.pushKey(kt.key_code.key_leftshift, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), timer.arms.items.len);
    h.fake.pushKey(kt.key_code.key_leftshift, false);
    h.fake.pushKey(kt.key_code.key_q, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 2), timer.arms.items.len);
    h.input.repeatExpired(1);
    try expectKey(h.rec.last(), .q, 2, "q");
}

test "repeat: a grabbed key repeats as grab events (Shift+Up scrolls on)" {
    const h = try Harness.init(.{});
    defer h.deinit();
    var timer = FakeTimer{};
    defer timer.deinit();
    h.input.attachRepeatTimer(timer.ops());

    h.fake.pushKey(kt.key_code.key_leftshift, true);
    h.fake.pushKey(kt.key_code.key_up, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), h.rec.countGrabs(@intFromEnum(libinput.GrabId.scroll_up)));

    h.input.repeatExpired(3);
    try testing.expectEqual(@as(usize, 4), h.rec.countGrabs(@intFromEnum(libinput.GrabId.scroll_up)));
    // Repeats of a grabbed key never leak key events.
    try testing.expectEqual(@as(usize, 0), h.rec.countAction(2));

    h.fake.pushKey(kt.key_code.key_up, false);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), timer.disarms);
    h.input.repeatExpired(2);
    try testing.expectEqual(@as(usize, 4), h.rec.countGrabs(@intFromEnum(libinput.GrabId.scroll_up)));
}

test "repeat: without a timer seam presses do not repeat" {
    const h = try Harness.init(.{});
    defer h.deinit();
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    h.input.repeatExpired(3);
    try testing.expectEqual(@as(usize, 0), h.rec.countAction(2));
    try testing.expectEqual(@as(usize, 1), h.rec.entries.items.len);
}

test "pointer: relative motion accumulates; absolute reports device position" {
    const h = try Harness.init(.{});
    defer h.deinit();

    h.fake.pushMotion(3.5, -2.0);
    h.fake.pushMotion(1.0, 1.0);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 2), h.rec.count(.pointer_motion));
    const m1 = h.rec.entries.items[0].event.pointer_motion;
    try testing.expectEqual(@as(f64, 3.5), m1.dx);
    try testing.expectEqual(@as(f64, -2.0), m1.dy);
    try testing.expect(!m1.absolute);
    try testing.expectEqual(@as(f64, 3.5), m1.x);
    try testing.expectEqual(@as(f64, -2.0), m1.y);
    const m2 = h.rec.entries.items[1].event.pointer_motion;
    try testing.expectEqual(@as(f64, 4.5), m2.x);
    try testing.expectEqual(@as(f64, -1.0), m2.y);

    // Absolute (QEMU USB tablet): position in device space, deltas
    // against the previous position.
    h.fake.pushAbsolute(100.0, 200.0);
    try h.input.dispatch();
    const a1 = h.rec.last().pointer_motion;
    try testing.expect(a1.absolute);
    try testing.expectEqual(@as(f64, 100.0), a1.x);
    try testing.expectEqual(@as(f64, 200.0), a1.y);
    try testing.expectEqual(@as(f64, 95.5), a1.dx);
    try testing.expectEqual(@as(f64, 201.0), a1.dy);
    h.fake.pushAbsolute(110.0, 190.0);
    try h.input.dispatch();
    const a2 = h.rec.last().pointer_motion;
    try testing.expectEqual(@as(f64, 10.0), a2.dx);
    try testing.expectEqual(@as(f64, -10.0), a2.dy);
    try testing.expectEqual(@as(f64, 110.0), a2.x);
}

test "pointer: buttons carry position; double/triple click window per button" {
    const h = try Harness.init(.{});
    defer h.deinit();
    fake_clock = 0;
    h.input.now_ms = fakeNowMs;

    const left: u32 = 0x110; // BTN_LEFT
    const right: u32 = 0x111; // BTN_RIGHT

    h.fake.pushMotion(7.0, 9.0);
    try h.input.dispatch();

    // Single click at t=0.
    h.fake.pushButton(left, true);
    h.fake.pushButton(left, false);
    try h.input.dispatch();
    try testing.expectEqual(@as(u8, 1), h.rec.entries.items[1].event.pointer_button.click_count);
    try testing.expectEqual(@as(u8, 1), h.rec.last().pointer_button.click_count);
    try testing.expectEqual(@as(f64, 7.0), h.rec.last().pointer_button.x);
    try testing.expectEqual(@as(f64, 9.0), h.rec.last().pointer_button.y);
    try testing.expectEqual(left, h.rec.last().pointer_button.button);
    try testing.expect(!h.rec.last().pointer_button.pressed);

    // Double at t=300 (within 400 ms), triple at t=350, capped at 3.
    fake_clock = 300;
    h.fake.pushButton(left, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(u8, 2), h.rec.last().pointer_button.click_count);
    fake_clock = 350;
    h.fake.pushButton(left, false);
    h.fake.pushButton(left, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(u8, 3), h.rec.last().pointer_button.click_count);
    fake_clock = 450;
    h.fake.pushButton(left, false);
    h.fake.pushButton(left, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(u8, 3), h.rec.last().pointer_button.click_count);

    // Gap > 400 ms resets to 1; a different button starts its own chain.
    fake_clock = 1000;
    h.fake.pushButton(left, false);
    h.fake.pushButton(left, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(u8, 1), h.rec.last().pointer_button.click_count);
    fake_clock = 1010;
    h.fake.pushButton(right, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(u8, 1), h.rec.last().pointer_button.click_count);
    try testing.expectEqual(right, h.rec.last().pointer_button.button);

    // Out-of-range button codes always report a single click.
    fake_clock = 1020;
    h.fake.pushButton(0x14a, true); // BTN_TOUCH
    try h.input.dispatch();
    try testing.expectEqual(@as(u8, 1), h.rec.last().pointer_button.click_count);
}

test "pointer: axis sources, natural scrolling, legacy axis and stops ignored" {
    const h = try Harness.init(.{});
    defer h.deinit();

    // Wheel down: positive dy scrolls down.
    h.fake.pushScroll(libinput.event.pointer_scroll_wheel, 1.0, 0.0);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), h.rec.count(.pointer_axis));
    try testing.expectEqual(@as(f64, 1.0), h.rec.last().pointer_axis.dy);
    try testing.expectEqual(@as(f64, 0.0), h.rec.last().pointer_axis.dx);

    // Natural scrolling inverts both axes.
    h.cfg.natural_scrolling = true;
    h.fake.pushScroll(libinput.event.pointer_scroll_wheel, 1.0, 2.0);
    try h.input.dispatch();
    try testing.expectEqual(@as(f64, -1.0), h.rec.last().pointer_axis.dy);
    try testing.expectEqual(@as(f64, -2.0), h.rec.last().pointer_axis.dx);
    h.cfg.natural_scrolling = false;

    // Finger and continuous sources convert the same way.
    h.fake.pushScroll(libinput.event.pointer_scroll_finger, -2.0, 0.0);
    h.fake.pushScroll(libinput.event.pointer_scroll_continuous, 0.5, 0.0);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 4), h.rec.count(.pointer_axis));

    // Legacy POINTER_AXIS is ignored (libinput >= 1.19 also emits the
    // SCROLL_* events; processing both would double-scroll), and an
    // all-zero scroll is a stop, not an event.
    h.fake.pushScroll(libinput.event.pointer_axis, 5.0, 5.0);
    h.fake.pushScroll(libinput.event.pointer_scroll_wheel, 0.0, 0.0);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 4), h.rec.count(.pointer_axis));
}

test "mouse=false drops pointer events; keyboard is unaffected" {
    const h = try Harness.init(.{});
    defer h.deinit();
    h.cfg.mouse = false;

    h.fake.pushMotion(1.0, 1.0);
    h.fake.pushAbsolute(5.0, 5.0);
    h.fake.pushButton(0x110, true);
    h.fake.pushScroll(libinput.event.pointer_scroll_wheel, 1.0, 0.0);
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), h.rec.entries.items.len);
    try expectKey(h.rec.last(), .a, 1, "a");

    // Re-enabling delivers pointer events again without re-init.
    h.cfg.mouse = true;
    h.fake.pushMotion(2.0, 3.0);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), h.rec.count(.pointer_motion));
}

test "devices: add/remove tracking, capabilities, hotplug hook, refcounts" {
    const h = try Harness.init(.{});
    defer h.deinit();

    const HookLog = struct {
        entries: std.ArrayListUnmanaged(struct { name: []const u8, added: bool }) = .empty,
        fn callback(userdata: usize, device: libinput.DeviceInfo, added: bool) void {
            const self: *@This() = @ptrFromInt(userdata);
            self.entries.append(testing.allocator, .{ .name = device.name, .added = added }) catch
                @panic("hook: oom");
        }
    };
    var log = HookLog{};
    defer log.entries.deinit(testing.allocator);
    h.input.hotplug = .{ .callback = HookLog.callback, .userdata = @intFromPtr(&log) };

    var kbd = FakeDevice{ .name = "testkbd", .caps = 1 };
    var ptr = FakeDevice{ .name = "testptr", .caps = 2 };
    var both = FakeDevice{ .name = "testboth", .caps = 3 };

    h.fake.pushDevice(libinput.event.device_added, &kbd);
    h.fake.pushDevice(libinput.event.device_added, &ptr);
    h.fake.pushDevice(libinput.event.device_added, &both);
    try h.input.dispatch();

    const list = h.input.deviceList();
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("testkbd", list[0].name);
    try testing.expect(list[0].keyboard and !list[0].pointer);
    try testing.expect(!list[1].keyboard and list[1].pointer);
    try testing.expect(list[2].keyboard and list[2].pointer);
    try testing.expectEqual(@as(usize, 1), kbd.refs);
    try testing.expectEqual(@as(usize, 1), ptr.refs);
    try testing.expectEqual(@as(usize, 3), log.entries.items.len);
    try testing.expect(log.entries.items[0].added);

    // Remove the middle device: order preserved, ref released, hook fired.
    h.fake.pushDevice(libinput.event.device_removed, &ptr);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 2), h.input.deviceList().len);
    try testing.expectEqualStrings("testboth", h.input.deviceList()[1].name);
    try testing.expectEqual(@as(usize, 0), ptr.refs);
    try testing.expectEqual(@as(usize, 4), log.entries.items.len);
    try testing.expect(!log.entries.items[3].added);
    try testing.expectEqualStrings("testptr", log.entries.items[3].name);

    // Removing an unknown device is a no-op.
    var stray = FakeDevice{ .name = "stray", .caps = 1 };
    h.fake.pushDevice(libinput.event.device_removed, &stray);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 2), h.input.deviceList().len);
    try testing.expectEqual(@as(usize, 4), log.entries.items.len);

    // Drain the rest; deinit must release the remaining references.
    h.fake.pushDevice(libinput.event.device_removed, &kbd);
    h.fake.pushDevice(libinput.event.device_removed, &both);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 0), h.input.deviceList().len);
    try testing.expectEqual(@as(usize, 0), kbd.refs);
    try testing.expectEqual(@as(usize, 0), both.refs);
}

test "LibinputOps.real binds the translate-c surface (analyzed, never called)" {
    // Referencing `real` forces analysis of the lazy libinput-c import
    // and links every C symbol; no device is opened.
    const ops = libinput.LibinputOps.real;
    try testing.expect(@intFromPtr(ops.udev_new) != 0);
    try testing.expect(@intFromPtr(ops.udev_unref) != 0);
    try testing.expect(@intFromPtr(ops.udev_create_context) != 0);
    try testing.expect(@intFromPtr(ops.udev_assign_seat) != 0);
    try testing.expect(@intFromPtr(ops.unref) != 0);
    try testing.expect(@intFromPtr(ops.get_fd) != 0);
    try testing.expect(@intFromPtr(ops.dispatch) != 0);
    try testing.expect(@intFromPtr(ops.get_event) != 0);
    try testing.expect(@intFromPtr(ops.event_destroy) != 0);
    try testing.expect(@intFromPtr(ops.event_get_type) != 0);
    try testing.expect(@intFromPtr(ops.event_get_device) != 0);
    try testing.expect(@intFromPtr(ops.keyboard_get_key) != 0);
    try testing.expect(@intFromPtr(ops.keyboard_get_key_state) != 0);
    try testing.expect(@intFromPtr(ops.pointer_get_dx) != 0);
    try testing.expect(@intFromPtr(ops.pointer_get_dy) != 0);
    try testing.expect(@intFromPtr(ops.pointer_get_absolute_x) != 0);
    try testing.expect(@intFromPtr(ops.pointer_get_absolute_y) != 0);
    try testing.expect(@intFromPtr(ops.pointer_get_button) != 0);
    try testing.expect(@intFromPtr(ops.pointer_get_button_state) != 0);
    try testing.expect(@intFromPtr(ops.pointer_get_axis_value) != 0);
    try testing.expect(@intFromPtr(ops.device_has_capability) != 0);
    try testing.expect(@intFromPtr(ops.device_ref) != 0);
    try testing.expect(@intFromPtr(ops.device_unref) != 0);
    try testing.expect(@intFromPtr(ops.device_get_name) != 0);
}
