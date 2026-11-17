//! src/test_libinput.zig -- hermetic tests for the libinput dispatch layer.
//!
//! `src/input/libinput.zig` imports `../session.zig`, so the module root
//! must be `src/`; run this root instead of the backend file. The fake
//! `LibinputOps` below feeds a pre-queued event list — no devices, no
//! udev, no seat daemon. Key conversion uses a REAL xkb.Keymap (us
//! layout, headless), so the xkb-c module and libxkbcommon are linked.
//! `LibinputOps.real` is referenced only by the final binding test (no
//! calls), which is why the command also wires libinput-c/-linput/-ludev.
//! The key-translation acceptance tests feed the adapter's output through
//! the REAL libghostty-vt key encoder (the same call TerminalSession makes),
//! so they also need the `vt-c` module and libghostty-vt; the canonical
//! runner is `zig build test`, which wires every module.
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
const vt = @import("vt.zig");

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
    unref_calls: usize = 0,
    udev_unref_calls: usize = 0,
    poll_fd: c_int = 77,
    /// A real fd that fakeUnref closes through the stored interface, the
    /// way libinput closes device fds during unref. -1: nothing to close.
    device_fd: c_int = -1,
    /// libinput stores the interface BY POINTER for the context lifetime;
    /// the fake does the same so tests can prove the pointer outlives init.
    interface: ?*const libinput.Interface = null,
    seat: [16]u8 = undefined,
    seat_len: usize = 0,
    udev_fails: bool = false,
    context_fails: bool = false,
    seat_fails: bool = false,
    dispatch_fails: bool = false,
    suspend_calls: usize = 0,
    resume_calls: usize = 0,
    resume_fails: bool = false,
    suspended: bool = false,
    /// Devices currently open (added, not removed). Models libinput's
    /// device list so suspend can remove them and resume re-add them.
    open_devices: std.ArrayListUnmanaged(*FakeDevice) = .empty,
    /// Devices closed by suspend; re-added by resume.
    suspended_devices: std.ArrayListUnmanaged(*FakeDevice) = .empty,

    fn init(allocator: std.mem.Allocator) Fake {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Fake) void {
        for (self.queue.items) |p| self.allocator.destroy(p);
        self.queue.deinit(self.allocator);
        self.open_devices.deinit(self.allocator);
        self.suspended_devices.deinit(self.allocator);
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
        if (kind == libinput.event.device_added) {
            self.open_devices.append(self.allocator, dev) catch @panic("fake: oom");
        } else if (kind == libinput.event.device_removed) {
            for (self.open_devices.items, 0..) |d, i| {
                if (d == dev) {
                    _ = self.open_devices.orderedRemove(i);
                    break;
                }
            }
        }
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
            .suspend_ = fakeSuspend,
            .resume_ = fakeResume,
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
            .pointer_get_absolute_x_transformed = fakePointerGetAbsoluteXTransformed,
            .pointer_get_absolute_y_transformed = fakePointerGetAbsoluteYTransformed,
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
    fromUdev(udev).udev_unref_calls += 1;
    return null;
}

fn fakeUdevCreateContext(interface: *const libinput.Interface, user_data: ?*anyopaque, udev: *libinput.Udev) callconv(.c) ?*libinput.Libinput {
    _ = user_data;
    const f = fromUdev(udev);
    if (f.context_fails) return null;
    f.interface = interface;
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
    const f = fromLi(li);
    f.unref_calls += 1;
    // libinput removes every device during unref and closes its fd through
    // the STORED interface pointer (evdev_device_remove ->
    // evdev_device_suspend -> close_restricted). Mirror that here: a
    // dangling interface faults in this call, exactly like real teardown.
    if (f.device_fd >= 0) {
        if (f.interface) |intf| intf.close_restricted(f.device_fd, null);
        f.device_fd = -1;
    }
    return null;
}

fn fakeSuspend(li: *libinput.Libinput) callconv(.c) void {
    const f = fromLi(li);
    f.suspend_calls += 1;
    f.suspended = true;
    // libinput closes every device and queues a DEVICE_REMOVED for each.
    for (f.open_devices.items) |dev| {
        f.push(.{ .type = libinput.event.device_removed, .device = @ptrCast(dev) });
        f.suspended_devices.append(f.allocator, dev) catch @panic("fake: oom");
    }
    f.open_devices.clearRetainingCapacity();
}

fn fakeResume(li: *libinput.Libinput) callconv(.c) c_int {
    const f = fromLi(li);
    f.resume_calls += 1;
    if (f.resume_fails) return -1;
    f.suspended = false;
    // libinput re-opens the devices and queues a DEVICE_ADDED for each.
    for (f.suspended_devices.items) |dev| {
        f.push(.{ .type = libinput.event.device_added, .device = @ptrCast(dev) });
        f.open_devices.append(f.allocator, dev) catch @panic("fake: oom");
    }
    f.suspended_devices.clearRetainingCapacity();
    return 0;
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

fn fakePointerGetAbsoluteXTransformed(ev: *libinput.Event, width: u32) callconv(.c) f64 {
    return fromEv(ev).abs_x * @as(f64, @floatFromInt(width)) / 1000.0;
}

fn fakePointerGetAbsoluteYTransformed(ev: *libinput.Event, height: u32) callconv(.c) f64 {
    return fromEv(ev).abs_y * @as(f64, @floatFromInt(height)) / 1000.0;
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

/// Bridges the adapter's session events into the REAL libghostty-vt key
/// encoder, the same call chain TerminalSession.handleKey performs: map the
/// event onto `vt.Key`/`vt.KeyAction`, refresh the encoder's terminal modes,
/// encode. Only the pty write is omitted, so the assertions below are on the
/// exact bytes a terminal would receive. Terminal modes (Kitty flags,
/// modifyOtherKeys) are negotiated the way a program does it: by writing the
/// sequence into the terminal.
const KeyPipe = struct {
    allocator: std.mem.Allocator,
    terminal: vt.Vt,
    encoder: vt.KeyEncoder,
    /// Everything encoded so far, in order.
    out: std.ArrayListUnmanaged(u8) = .empty,

    fn init(allocator: std.mem.Allocator) !KeyPipe {
        var terminal = try vt.Vt.init(80, 24);
        errdefer terminal.deinit();
        const encoder = try vt.KeyEncoder.new();
        return .{ .allocator = allocator, .terminal = terminal, .encoder = encoder };
    }

    fn deinit(self: *KeyPipe) void {
        self.out.deinit(self.allocator);
        self.encoder.free();
        self.terminal.deinit();
        self.* = undefined;
    }

    /// Drop encoded bytes without touching terminal or encoder state.
    fn clear(self: *KeyPipe) void {
        self.out.clearRetainingCapacity();
    }

    /// Program output that changes keyboard reporting (e.g. "\x1b[>1u").
    fn negotiate(self: *KeyPipe, sequence: []const u8) void {
        self.terminal.write(sequence);
    }

    fn sink(userdata: usize, event: session.InputEvent) void {
        const self: *KeyPipe = @ptrFromInt(userdata);
        switch (event) {
            .key => |k| self.encode(k) catch @panic("key pipe: encode failed"),
            // Grabs never reach the encoder; other events are irrelevant here.
            else => {},
        }
    }

    fn encode(self: *KeyPipe, k: session.InputEvent.Key) !void {
        const key = std.enums.fromInt(vt.Key, k.ghostty_key) orelse return;
        const action = std.enums.fromInt(vt.KeyAction, k.action) orelse return;
        try self.encoder.setFromTerminal(&self.terminal);
        const ev: vt.KeyEvent = .{
            .action = action,
            .key = key,
            .mods = k.mods,
            .consumed_mods = k.consumed_mods,
            .utf8 = k.utf8 orelse "",
            .unshifted_codepoint = k.unshifted_codepoint orelse 0,
        };
        var buf: [64]u8 = undefined;
        const bytes = self.encoder.encode(ev, &buf) catch |err| switch (err) {
            error.OutOfSpace => {
                var big: [256]u8 = undefined;
                try self.out.appendSlice(self.allocator, try self.encoder.encode(ev, &big));
                return;
            },
            else => return err,
        };
        try self.out.appendSlice(self.allocator, bytes);
    }
};

/// Injected physical key state for the resume re-sync (the real source
/// reads EVIOCGKEY on evdev fds, which do not exist here). Tests set the
/// codes the "device" reports held across the suspend/resume.
var fake_physical_keys: []const u32 = &.{};
fn fakePhysicalKeys(buf: []u32) usize {
    const n = @min(fake_physical_keys.len, buf.len);
    @memcpy(buf[0..n], fake_physical_keys[0..n]);
    return n;
}

/// Heap-allocated so every pointer handed to the Input (sink userdata,
/// fake, keymap, cfg) stays stable.
const Harness = struct {
    km: xkb.Keymap,
    cfg: config.Config,
    fake: Fake,
    rec: Recorder,
    pipe: ?*KeyPipe = null,
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
        h.pipe = null;
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

    /// Route key events through the real terminal encoder instead of the
    /// Recorder. Call at most once per harness.
    fn attachPipe(self: *Harness) !*KeyPipe {
        const p = try testing.allocator.create(KeyPipe);
        errdefer testing.allocator.destroy(p);
        p.* = try KeyPipe.init(testing.allocator);
        self.pipe = p;
        self.input.setSink(KeyPipe.sink, @intFromPtr(p));
        return p;
    }

    fn deinit(self: *Harness) void {
        self.input.deinit();
        if (self.pipe) |p| {
            p.deinit();
            testing.allocator.destroy(p);
        }
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
    // Ghostty applies the Control transformation from the modifiers; the
    // adapter hands over the layout text.
    try expectKey(controlled, .a, 1, "a");
    try testing.expectEqual(kt.mod_ctrl, controlled.key.mods);
    try testing.expectEqual(kt.mod_shift | kt.mod_caps_lock, controlled.key.consumed_mods);

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

test "repeat: re-translates with the current modifiers (Shift release mid-repeat)" {
    const h = try Harness.init(.{});
    defer h.deinit();
    var timer = FakeTimer{};
    defer timer.deinit();
    h.input.attachRepeatTimer(timer.ops());

    // Hold Shift, hold A: press and repeats are uppercase.
    h.fake.pushKey(kt.key_code.key_leftshift, true);
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    h.input.repeatExpired(1);
    const upper = h.rec.last();
    try expectKey(upper, .a, 2, "A");
    try testing.expectEqual(kt.mod_shift, upper.key.mods);

    // Release Shift while A is still held: the release must not cancel the
    // repeat, and the next repeats translate against the new state.
    h.fake.pushKey(kt.key_code.key_leftshift, false);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 0), timer.disarms);
    h.input.repeatExpired(1);
    const lower = h.rec.last();
    try expectKey(lower, .a, 2, "a");
    try testing.expectEqual(@as(u16, 0), lower.key.mods);

    // Pressing Shift again mid-repeat changes the next repeat back to
    // uppercase instead of stopping it.
    h.fake.pushKey(kt.key_code.key_leftshift, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 0), timer.disarms);
    h.input.repeatExpired(1);
    try expectKey(h.rec.last(), .a, 2, "A");

    // Releasing the repeating key still cancels.
    h.fake.pushKey(kt.key_code.key_a, false);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), timer.disarms);
    h.input.repeatExpired(2);
    try testing.expectEqual(@as(usize, 3), h.rec.countAction(2));
}

test "repeat: modifiers neither arm nor cancel; a repeatable press replaces" {
    const h = try Harness.init(.{});
    defer h.deinit();
    var timer = FakeTimer{};
    defer timer.deinit();
    h.input.attachRepeatTimer(timer.ops());

    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), timer.arms.items.len);

    // A modifier press leaves the running repeat alone...
    h.fake.pushKey(kt.key_code.key_leftctrl, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 0), timer.disarms);
    h.input.repeatExpired(1);
    const rep = h.rec.last();
    try expectKey(rep, .a, 2, "a");
    try testing.expectEqual(kt.mod_ctrl, rep.key.mods);
    h.fake.pushKey(kt.key_code.key_leftctrl, false);
    try h.input.dispatch();

    // ...and a lone modifier never arms.
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

test "repeat: grabs match the modifiers held at repeat time" {
    const h = try Harness.init(.{});
    defer h.deinit();
    var timer = FakeTimer{};
    defer timer.deinit();
    h.input.attachRepeatTimer(timer.ops());

    // Default scroll-up grab: Shift+Up.
    h.fake.pushKey(kt.key_code.key_leftshift, true);
    h.fake.pushKey(kt.key_code.key_up, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), h.rec.countGrabs(@intFromEnum(libinput.GrabId.scroll_up)));
    h.input.repeatExpired(1);
    try testing.expectEqual(@as(usize, 2), h.rec.countGrabs(@intFromEnum(libinput.GrabId.scroll_up)));

    // Releasing Shift while Up repeats: the grab no longer matches, so the
    // repeat is delivered as a plain Up key event instead.
    h.fake.pushKey(kt.key_code.key_leftshift, false);
    try h.input.dispatch();
    h.input.repeatExpired(1);
    try testing.expectEqual(@as(usize, 2), h.rec.countGrabs(@intFromEnum(libinput.GrabId.scroll_up)));
    const rep = h.rec.last();
    try expectKey(rep, .arrow_up, 2, null);
    try testing.expectEqual(@as(u16, 0), rep.key.mods);

    // Pressing Shift again re-matches the grab on the next repeat.
    h.fake.pushKey(kt.key_code.key_leftshift, true);
    try h.input.dispatch();
    h.input.repeatExpired(1);
    try testing.expectEqual(@as(usize, 3), h.rec.countGrabs(@intFromEnum(libinput.GrabId.scroll_up)));
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

// ---------------------------------------------------------------------------
// Keyboard translation: xkb adapter -> session event -> real key encoder
//
// These exercise the adapter that produced the malformed events (Ctrl text
// transformed twice, consumed modifiers dropped) and hand its output to the
// same libghostty-vt encoder TerminalSession.handleKey uses. Expectations are
// the C0/CSI bytes a terminal receives, not hand-corrected encoder inputs.
// ---------------------------------------------------------------------------

/// Dispatch ctrl+<code> (press/release, in that order) and assert the exact
/// bytes the encoder emits for the pair.
fn expectCtrlSequence(h: *Harness, pipe: *KeyPipe, code: u32, want: []const u8) !void {
    pipe.clear();
    h.fake.pushKey(kt.key_code.key_leftctrl, true);
    h.fake.pushKey(code, true);
    h.fake.pushKey(code, false);
    h.fake.pushKey(kt.key_code.key_leftctrl, false);
    try h.input.dispatch();
    try testing.expectEqualStrings(want, pipe.out.items);
}

test "keyboard: ctrl control bytes across the adapter (A1)" {
    const h = try Harness.init(.{});
    defer h.deinit();
    const pipe = try h.attachPipe();

    // Ctrl-A .. Ctrl-Z. Most map to C0 directly; i and m are deliberately
    // CSI u in Paul Evans' fixterms (distinct from Tab and CR), and the
    // adapter must not special-case them into legacy bytes.
    const cases = [_]struct { code: u32, want: []const u8 }{
        .{ .code = kt.key_code.key_a, .want = "\x01" },
        .{ .code = kt.key_code.key_b, .want = "\x02" },
        .{ .code = kt.key_code.key_c, .want = "\x03" },
        .{ .code = kt.key_code.key_d, .want = "\x04" },
        .{ .code = kt.key_code.key_e, .want = "\x05" },
        .{ .code = kt.key_code.key_f, .want = "\x06" },
        .{ .code = kt.key_code.key_g, .want = "\x07" },
        .{ .code = kt.key_code.key_h, .want = "\x08" },
        .{ .code = kt.key_code.key_i, .want = "\x1b[105;5u" },
        .{ .code = kt.key_code.key_j, .want = "\x0a" },
        .{ .code = kt.key_code.key_k, .want = "\x0b" },
        .{ .code = kt.key_code.key_l, .want = "\x0c" },
        .{ .code = kt.key_code.key_m, .want = "\x1b[109;5u" },
        .{ .code = kt.key_code.key_n, .want = "\x0e" },
        .{ .code = kt.key_code.key_o, .want = "\x0f" },
        .{ .code = kt.key_code.key_p, .want = "\x10" },
        .{ .code = kt.key_code.key_q, .want = "\x11" },
        .{ .code = kt.key_code.key_r, .want = "\x12" },
        .{ .code = kt.key_code.key_s, .want = "\x13" },
        .{ .code = kt.key_code.key_t, .want = "\x14" },
        .{ .code = kt.key_code.key_u, .want = "\x15" },
        .{ .code = kt.key_code.key_v, .want = "\x16" },
        .{ .code = kt.key_code.key_w, .want = "\x17" },
        .{ .code = kt.key_code.key_x, .want = "\x18" },
        .{ .code = kt.key_code.key_y, .want = "\x19" },
        .{ .code = kt.key_code.key_z, .want = "\x1a" },
    };
    for (cases) |case| try expectCtrlSequence(h, pipe, case.code, case.want);

    // Ctrl-Space is NUL; representative control punctuation.
    try expectCtrlSequence(h, pipe, kt.key_code.key_space, "\x00");
    try expectCtrlSequence(h, pipe, kt.key_code.key_rightbrace, "\x1d");
    try expectCtrlSequence(h, pipe, kt.key_code.key_backslash, "\x1c");
    try expectCtrlSequence(h, pipe, kt.key_code.key_slash, "\x1f");
    // '[' stays CSI u (fixterms keeps it distinct from ESC).
    try expectCtrlSequence(h, pipe, kt.key_code.key_leftbrace, "\x1b[91;5u");
}

test "keyboard: ctrl+L and ctrl+R under legacy, modifyOtherKeys=2, Kitty (A2)" {
    const h = try Harness.init(.{});
    defer h.deinit();
    const pipe = try h.attachPipe();

    // Legacy: the encoder builds the C0 byte from text "l"/"r" plus Ctrl.
    try expectCtrlSequence(h, pipe, kt.key_code.key_l, "\x0c");
    try expectCtrlSequence(h, pipe, kt.key_code.key_r, "\x12");

    // modifyOtherKeys=2: xterm's CSI 27 form carries the UNSHIFTED codepoint
    // of the layout text (108/114), not the C0 byte (12/18).
    pipe.negotiate("\x1b[>4;2m");
    try expectCtrlSequence(h, pipe, kt.key_code.key_l, "\x1b[27;5;108~");
    try expectCtrlSequence(h, pipe, kt.key_code.key_r, "\x1b[27;5;114~");
    pipe.negotiate("\x1b[>4;0m");

    // Kitty disambiguation: text plus Ctrl, and Ctrl is not consumed.
    pipe.negotiate("\x1b[>1u");
    try expectCtrlSequence(h, pipe, kt.key_code.key_l, "\x1b[108;5u");
    try expectCtrlSequence(h, pipe, kt.key_code.key_r, "\x1b[114;5u");
}

test "keyboard: consumed modifiers keep text out of shortcut encoding (A3)" {
    const h = try Harness.init(.{});
    defer h.deinit();
    const pipe = try h.attachPipe();
    // Kitty disambiguation encodes every modified key as CSI u unless the
    // modifier was consumed producing the text.
    pipe.negotiate("\x1b[>1u");

    // Shift+A: text "A" with Shift consumed -> plain "A" (not CSI 97;2u).
    pipe.clear();
    h.fake.pushKey(kt.key_code.key_leftshift, true);
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqualStrings("A", pipe.out.items);

    // Shift+2 (US): text "@" with Shift consumed -> plain "@" (not 50;2u).
    pipe.clear();
    h.fake.pushKey(kt.key_code.key_2, true);
    try h.input.dispatch();
    try testing.expectEqualStrings("@", pipe.out.items);

    h.fake.pushKey(kt.key_code.key_2, false);
    h.fake.pushKey(kt.key_code.key_a, false);
    h.fake.pushKey(kt.key_code.key_leftshift, false);
    try h.input.dispatch();

    // Caps Lock is consumed by the letter too: "A" stays text.
    pipe.clear();
    h.fake.pushKey(kt.key_code.key_capslock, true);
    h.fake.pushKey(kt.key_code.key_capslock, false);
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqualStrings("A", pipe.out.items);
    h.fake.pushKey(kt.key_code.key_a, false);
    h.fake.pushKey(kt.key_code.key_capslock, true);
    h.fake.pushKey(kt.key_code.key_capslock, false);
    try h.input.dispatch();

    // A shortcut that really is a shortcut still encodes as one. Ctrl+Up
    // (Shift+Up is the default scroll grab and would never reach here)
    // encodes with the Ctrl modifier.
    pipe.clear();
    h.fake.pushKey(kt.key_code.key_leftctrl, true);
    h.fake.pushKey(kt.key_code.key_up, true);
    try h.input.dispatch();
    try testing.expectEqualStrings("\x1b[1;5A", pipe.out.items);
    h.fake.pushKey(kt.key_code.key_up, false);
    h.fake.pushKey(kt.key_code.key_leftctrl, false);
}

test "keyboard: AltGr text and a non-US layout reach the encoder (A3)" {
    const h = try Harness.init(.{ .km = .{ .layout = "de" } });
    defer h.deinit();
    const pipe = try h.attachPipe();
    pipe.negotiate("\x1b[>1u");

    // AltGr+q on German is '@'. AltGr is not a Ghostty modifier (kmscon
    // parity), so only the layout text reaches the encoder.
    pipe.clear();
    h.fake.pushKey(kt.key_code.key_rightalt, true);
    h.fake.pushKey(kt.key_code.key_q, true);
    try h.input.dispatch();
    try testing.expectEqualStrings("@", pipe.out.items);
    h.fake.pushKey(kt.key_code.key_q, false);
    h.fake.pushKey(kt.key_code.key_rightalt, false);
    try h.input.dispatch();

    // The active layout decides the text: evdev y is 'z' on de.
    pipe.clear();
    h.fake.pushKey(kt.key_code.key_y, true);
    try h.input.dispatch();
    try testing.expectEqualStrings("z", pipe.out.items);
}

test "keyboard: composed text is delivered, not the dead key (A3)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/Compose", .{tmp.sub_path[0..]});
    defer testing.allocator.free(path);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "Compose",
        .data = "<dead_acute> <a> : \"á\" aacute\n",
    });

    // us(intl) puts dead_acute on the apostrophe key (evdev 40).
    const h = try Harness.init(.{ .km = .{ .layout = "us", .variant = "intl" }, .compose_file = path });
    defer h.deinit();
    const pipe = try h.attachPipe();

    h.fake.pushKey(kt.key_code.key_apostrophe, true);
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqualStrings("á", pipe.out.items);
}

// ---------------------------------------------------------------------------
// Seat lifecycle: suspend/resume tie input delivery to seat ownership
// ---------------------------------------------------------------------------

test "suspend: no events delivered while the seat is inactive" {
    const h = try Harness.init(.{});
    defer h.deinit();

    // Events queued before the switch are dropped by suspend, not delivered.
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.suspend_();
    try testing.expectEqual(@as(usize, 0), h.rec.entries.items.len);

    // Even with events queued, dispatch is a no-op while suspended: nothing
    // reaches the sink while another session owns the seat.
    h.fake.pushKey(kt.key_code.key_b, true);
    h.fake.pushMotion(1.0, 2.0);
    h.fake.pushButton(0x110, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 0), h.rec.entries.items.len);
    try testing.expectEqual(@as(usize, 1), h.fake.suspend_calls);
}

test "suspend/resume: disarms repeat, stops delivery, resume restarts it" {
    const h = try Harness.init(.{});
    defer h.deinit();
    var timer = FakeTimer{};
    defer timer.deinit();
    h.input.attachRepeatTimer(timer.ops());

    // A repeatable press arms the timer and delivers the press.
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), h.rec.entries.items.len);
    try testing.expectEqual(@as(usize, 1), timer.arms.items.len);

    // Suspend disarms repeat: a held key stops repeating into the session.
    try h.input.suspend_();
    try testing.expectEqual(@as(usize, 1), timer.disarms);
    h.input.repeatExpired(3);
    try testing.expectEqual(@as(usize, 1), h.rec.entries.items.len);
    try testing.expectEqual(@as(usize, 0), h.rec.countAction(2));

    // Resume: the disarmed repeat stays gone, and delivery restarts.
    try h.input.resume_();
    try testing.expectEqual(@as(usize, 1), h.fake.resume_calls);
    h.input.repeatExpired(2);
    try testing.expectEqual(@as(usize, 0), h.rec.countAction(2));
    h.fake.pushKey(kt.key_code.key_c, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 2), h.rec.entries.items.len);
    try expectKey(h.rec.last(), .c, 1, "c");
}

test "suspend/resume: devices removed on suspend, re-added on resume" {
    const h = try Harness.init(.{});
    defer h.deinit();
    var kbd = FakeDevice{ .name = "testkbd", .caps = 1 };
    h.fake.pushDevice(libinput.event.device_added, &kbd);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), h.input.deviceList().len);
    try testing.expectEqual(@as(usize, 1), kbd.refs);

    // Suspend drains the DEVICE_REMOVED: device untracked, ref released.
    try h.input.suspend_();
    try testing.expectEqual(@as(usize, 0), h.input.deviceList().len);
    try testing.expectEqual(@as(usize, 0), kbd.refs);

    // Resume drains the DEVICE_ADDED: device re-tracked, ref re-taken.
    try h.input.resume_();
    try testing.expectEqual(@as(usize, 1), h.input.deviceList().len);
    try testing.expectEqualStrings("testkbd", h.input.deviceList()[0].name);
    try testing.expectEqual(@as(usize, 1), kbd.refs);
}

test "resume: failure keeps the input suspended (no delivery)" {
    const h = try Harness.init(.{});
    defer h.deinit();
    try h.input.suspend_();
    h.fake.resume_fails = true;
    try testing.expectError(error.ResumeFailed, h.input.resume_());

    // Still suspended: dispatch delivers nothing.
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 0), h.rec.entries.items.len);
}

test "suspend/resume: idempotent; resume without suspend is a no-op" {
    const h = try Harness.init(.{});
    defer h.deinit();
    // Resume before any suspend does nothing (input already active).
    try h.input.resume_();
    try testing.expectEqual(@as(usize, 0), h.fake.resume_calls);
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), h.rec.entries.items.len);

    // Double suspend only suspends once; double resume only resumes once.
    try h.input.suspend_();
    try h.input.suspend_();
    try testing.expectEqual(@as(usize, 1), h.fake.suspend_calls);
    try h.input.resume_();
    try h.input.resume_();
    try testing.expectEqual(@as(usize, 1), h.fake.resume_calls);
}

test "suspend/resume: dropped VT-switch modifier releases are cleared on resume" {
    // Regression (nix/tests/vt-input-leak.nix "input still works after
    // returning"): the VT-switch chord's Ctrl/Alt releases arrive after the
    // seat deactivates, so suspend_ never reads them and the xkb state keeps
    // Ctrl+Alt depressed. resume_ must clear the stale modifiers, or every
    // key typed after the switch is encoded with Ctrl+Alt and never reaches
    // the shell as text.
    const h = try Harness.init(.{});
    defer h.deinit();

    // The chord: Ctrl and Alt go down and are processed, so the xkb state
    // holds them depressed. (The Fn press that triggers the switch is not a
    // modifier and is omitted.)
    h.fake.pushKey(kt.key_code.key_leftctrl, true);
    h.fake.pushKey(kt.key_code.key_leftalt, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 2), h.rec.entries.items.len);

    // The seat deactivates before the chord's releases arrive; libinput closes
    // the evdev fds, so those releases are never read (never pushed here).
    try h.input.suspend_();
    try h.input.resume_();

    // The first key typed after the switch must be a plain 'a', not Ctrl+Alt+a.
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 3), h.rec.entries.items.len);
    const e = h.rec.last();
    try expectKey(e, .a, 1, "a");
    try testing.expect(e.key.mods == 0);
}

test "suspend/resume: physically held modifiers survive the re-sync (VT-switch chord)" {
    // Regression (nix/tests/vt-input-leak.nix "held Ctrl+Alt switch chord
    // survives"): the user switches TO kmshaunt with Ctrl+Alt+F1 and keeps
    // holding Ctrl+Alt. Those presses happened while the seat was inactive
    // (never seen as events); resume_ must re-sync them from the physical
    // key state so the next Ctrl+Alt+Fn switches away again. A blind
    // reset-to-zero drops them and traps the user on the VT.
    const h = try Harness.init(.{});
    defer h.deinit();

    // Ctrl+Alt go down while the seat is active, then the seat deactivates
    // with the chord still physically held (no releases ever arrive).
    h.fake.pushKey(kt.key_code.key_leftctrl, true);
    h.fake.pushKey(kt.key_code.key_leftalt, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 2), h.rec.entries.items.len);
    try h.input.suspend_();

    // The device reports the chord still held across the resume.
    fake_physical_keys = &.{ kt.key_code.key_leftctrl, kt.key_code.key_leftalt };
    defer fake_physical_keys = &.{};
    h.input.physical_keys = fakePhysicalKeys;
    try h.input.resume_();

    // The re-sync emits no key events of its own.
    try testing.expectEqual(@as(usize, 2), h.rec.entries.items.len);

    // F2 tapped with the chord held carries Ctrl+Alt — exactly what
    // Console.onInput matches to call switchVt.
    h.fake.pushKey(kt.key_code.key_f2, true);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 3), h.rec.entries.items.len);
    const e = h.rec.last();
    try expectKey(e, .f2, 1, null);
    try testing.expect(e.key.mods & (kt.mod_ctrl | kt.mod_alt) == (kt.mod_ctrl | kt.mod_alt));

    // Releasing the chord clears the modifiers again (no stuck state).
    h.fake.pushKey(kt.key_code.key_leftctrl, false);
    h.fake.pushKey(kt.key_code.key_leftalt, false);
    try h.input.dispatch();
    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    const a = h.rec.last();
    try expectKey(a, .a, 1, "a");
    try testing.expect(a.key.mods == 0);
}

test "suspend/resume: re-sync clears released keys and keeps held ones" {
    // The physical key state is authoritative in BOTH directions: keys
    // released while the seat was away must go, keys still held must stay.
    const h = try Harness.init(.{});
    defer h.deinit();

    // xkb state: Ctrl+Alt+Shift depressed.
    h.fake.pushKey(kt.key_code.key_leftctrl, true);
    h.fake.pushKey(kt.key_code.key_leftalt, true);
    h.fake.pushKey(kt.key_code.key_leftshift, true);
    try h.input.dispatch();
    try h.input.suspend_();

    // Physical truth on resume: only Alt is still held (Ctrl and Shift
    // were released while the seat was away; those releases were dropped).
    fake_physical_keys = &.{kt.key_code.key_leftalt};
    defer fake_physical_keys = &.{};
    h.input.physical_keys = fakePhysicalKeys;
    try h.input.resume_();

    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    const e = h.rec.last();
    try testing.expect(e == .key);
    try testing.expect(e.key.mods & kt.mod_alt != 0);
    try testing.expect(e.key.mods & (kt.mod_ctrl | kt.mod_shift) == 0);
}

test "suspend/resume: re-sync rebuilds right-modifier side bits" {
    const h = try Harness.init(.{});
    defer h.deinit();
    try h.input.suspend_();

    // Right Ctrl held across the switch: the side bit must come back too
    // (updateMask-style clears lose the physical right-key tracking).
    fake_physical_keys = &.{kt.key_code.key_rightctrl};
    defer fake_physical_keys = &.{};
    h.input.physical_keys = fakePhysicalKeys;
    try h.input.resume_();

    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    const e = h.rec.last();
    try testing.expect(e == .key);
    try testing.expect(e.key.mods & kt.mod_ctrl != 0);
    try testing.expect(e.key.mods & kt.mod_ctrl_side != 0);
}

test "suspend/resume: re-sync preserves Caps Lock" {
    // Locks are not physical key state: Caps Lock stays locked across the
    // switch even though no key is held.
    const h = try Harness.init(.{});
    defer h.deinit();
    h.fake.pushKey(kt.key_code.key_capslock, true);
    h.fake.pushKey(kt.key_code.key_capslock, false);
    try h.input.dispatch();
    try h.input.suspend_();

    fake_physical_keys = &.{};
    defer fake_physical_keys = &.{};
    h.input.physical_keys = fakePhysicalKeys;
    try h.input.resume_();

    h.fake.pushKey(kt.key_code.key_a, true);
    try h.input.dispatch();
    const e = h.rec.last();
    try expectKey(e, .a, 1, "A");
    try testing.expect(e.key.mods & kt.mod_caps_lock != 0);
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

test "pointer: setScreenSize transforms absolute coords to pixels" {
    const h = try Harness.init(.{});
    defer h.deinit();
    h.input.setScreenSize(1000, 1000);
    h.fake.pushAbsolute(500.0, 250.0);
    try h.input.dispatch();
    const m = h.rec.last().pointer_motion;
    try testing.expect(m.absolute);
    try testing.expectEqual(@as(f64, 500.0), m.x);
    try testing.expectEqual(@as(f64, 250.0), m.y);
}

test "pointer: relative motion clamps to the canvas; no edge drift" {
    const h = try Harness.init(.{});
    defer h.deinit();
    h.input.setScreenSize(100, 80);

    // Accumulate toward the bottom-right; the position clamps to (99,79).
    h.fake.pushMotion(200.0, 150.0);
    try h.input.dispatch();
    const m1 = h.rec.last().pointer_motion;
    try testing.expect(!m1.absolute);
    try testing.expectEqual(@as(f64, 99.0), m1.x);
    try testing.expectEqual(@as(f64, 79.0), m1.y);

    // A small reverse move responds immediately: the accumulator did not drift
    // past the edge, so there is no excess motion to undo first.
    h.fake.pushMotion(-10.0, -5.0);
    try h.input.dispatch();
    const m2 = h.rec.last().pointer_motion;
    try testing.expectEqual(@as(f64, 89.0), m2.x);
    try testing.expectEqual(@as(f64, 74.0), m2.y);
    try testing.expectEqual(@as(f64, -10.0), m2.dx);
    try testing.expectEqual(@as(f64, -5.0), m2.dy);

    // Clamp at the top-left too.
    h.fake.pushMotion(-500.0, -500.0);
    try h.input.dispatch();
    const m3 = h.rec.last().pointer_motion;
    try testing.expectEqual(@as(f64, 0.0), m3.x);
    try testing.expectEqual(@as(f64, 0.0), m3.y);
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

test "pointer: hostile axis values are clamped, NaN parks at zero" {
    const h = try Harness.init(.{});
    defer h.deinit();

    // A malicious evdev device can report arbitrary deltas; the session
    // converts accumulated scroll into an integer line count, so the
    // input layer must bound them (crash vector otherwise).
    h.fake.pushScroll(libinput.event.pointer_scroll_wheel, 1e300, -1e300);
    try h.input.dispatch();
    try testing.expectEqual(@as(f64, 1000.0), h.rec.last().pointer_axis.dy);
    try testing.expectEqual(@as(f64, -1000.0), h.rec.last().pointer_axis.dx);

    // NaN on one axis parks at zero; the other axis still reports.
    h.fake.pushScroll(libinput.event.pointer_scroll_finger, std.math.nan(f64), 5.0);
    try h.input.dispatch();
    try testing.expectEqual(@as(f64, 0.0), h.rec.last().pointer_axis.dy);
    try testing.expectEqual(@as(f64, 5.0), h.rec.last().pointer_axis.dx);
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
    try testing.expect(@intFromPtr(ops.suspend_) != 0);
    try testing.expect(@intFromPtr(ops.resume_) != 0);
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

// ---------------------------------------------------------------------------
// Teardown: interface lifetime, refcount balance, idempotent deinit
// ---------------------------------------------------------------------------

/// Overwrite the stack region a dangling interface pointer would occupy.
/// noinline + an explicit memset so the write survives every optimize mode
/// (ReleaseFast does not fill `undefined`).
noinline fn scribbleStack() u8 {
    var buf: [8192]u8 = undefined;
    @memset(&buf, 0xaa);
    return buf[4096];
}

test "deinit: idempotent; libinput and udev unreffed exactly once" {
    const h = try Harness.init(.{});
    defer h.deinit(); // a third deinit: still a no-op
    h.input.deinit();
    h.input.deinit();
    try testing.expectEqual(@as(usize, 1), h.fake.unref_calls);
    try testing.expectEqual(@as(usize, 1), h.fake.udev_unref_calls);
}

test "deinit: tracked device references released exactly once" {
    const h = try Harness.init(.{});
    defer h.deinit();
    var kbd = FakeDevice{ .name = "testkbd", .caps = 1 };
    h.fake.pushDevice(libinput.event.device_added, &kbd);
    try h.input.dispatch();
    try testing.expectEqual(@as(usize, 1), kbd.refs);
    h.input.deinit();
    try testing.expectEqual(@as(usize, 0), kbd.refs);
    h.input.deinit(); // idempotent: a double unref would underflow refs
    try testing.expectEqual(@as(usize, 0), kbd.refs);
}

test "interface: pointer passed to udev_create_context survives stack reuse until unref" {
    const h = try Harness.init(.{});
    defer h.deinit();
    // libinput stores the interface by pointer and calls close_restricted
    // through it during unref. Give the fake a real fd to close, then reuse
    // the stack between init and deinit: a stack-local interface copy would
    // now jump through 0xaa garbage (the graceful-shutdown segfault).
    const rc = linux.openat(linux.AT.FDCWD, "/dev/null", .{}, 0);
    try testing.expect(linux.errno(rc) == .SUCCESS);
    h.fake.device_fd = @intCast(rc);
    try testing.expectEqual(@as(u8, 0xaa), scribbleStack());
    try testing.expectEqual(@as(u8, 0xaa), scribbleStack());
    h.input.deinit();
    // close_restricted ran through the stored pointer: the fd is closed.
    const probe = linux.fcntl(@intCast(rc), linux.F.GETFD, 0);
    try testing.expect(linux.errno(probe) == .BADF);
    try testing.expectEqual(@as(usize, 1), h.fake.unref_calls);
}

test "real: udev context create/unref cycle through LibinputOps.real (headless)" {
    // Exercises the Real.udevCreateContext pointer pass-through against the
    // linked libinput. No seat is assigned, so no device is opened; the
    // static interface must simply survive the create/unref cycle.
    const ops = libinput.LibinputOps.real;
    const udev = ops.udev_new() orelse return error.SkipZigTest;
    defer _ = ops.udev_unref(udev);
    const li = ops.udev_create_context(&libinput.interface, null, udev) orelse
        return error.SkipZigTest;
    try testing.expectEqual(@as(u8, 0xaa), scribbleStack());
    _ = ops.unref(li);
}

// Real libinput, path backend: proves libinput stores the interface by
// pointer and calls open_restricted through it later (after stack reuse),
// and that `Interface` is ABI-compatible with struct libinput_interface.
// The callback refuses to open anything (-ENOENT), so no device is touched.
var path_open_calls: usize = 0;
var path_open_matched: bool = false;
const path_probe_node = "/dev/null";

fn pathProbeOpen(path: [*c]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = flags;
    _ = user_data;
    path_open_calls += 1;
    const s: [*:0]const u8 = @ptrCast(path);
    path_open_matched = std.mem.eql(u8, std.mem.span(s), path_probe_node);
    return -2; // -ENOENT
}

fn pathProbeClose(fd: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = fd;
    _ = user_data;
}

const path_probe_interface = libinput.Interface{
    .open_restricted = pathProbeOpen,
    .close_restricted = pathProbeClose,
};

test "real: libinput calls the stored interface after stack reuse (path backend)" {
    const c = @import("libinput-c");
    const li = c.libinput_path_create_context(@ptrCast(&path_probe_interface), null) orelse
        return error.SkipZigTest;
    defer _ = c.libinput_unref(li);
    try testing.expectEqual(@as(u8, 0xaa), scribbleStack());
    path_open_calls = 0;
    path_open_matched = false;
    // add_device stats the node, then opens it through the stored interface
    // pointer. /dev/null always exists; the open callback refuses it, so
    // add_device fails cleanly after the callback ran.
    const dev = c.libinput_path_add_device(li, path_probe_node);
    // No udev database (minimal container): the node never resolves and the
    // interface is not reached — nothing to assert in that environment.
    if (path_open_calls == 0) return error.SkipZigTest;
    try testing.expect(dev == null);
    try testing.expectEqual(@as(usize, 1), path_open_calls);
    try testing.expect(path_open_matched);
}
