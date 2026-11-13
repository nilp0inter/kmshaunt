//! src/test_locale1.zig -- hermetic tests for the locale1 sd-bus reader.
//!
//!     nix run nixpkgs#zig -- test src/test_locale1.zig
//!
//! `src/misc/locale1.zig` only imports `std`; its production ops table
//! (`Locale1.real`) lazily imports the translate-c module `sd-bus-c`, and
//! these tests never reference it. So no systemd headers, no libsystemd, no
//! bus socket and no localed are needed -- every sd-bus call goes through
//! the fake `SdBusOps` table installed below.
//!
//! The fake bus mirrors the protocol facts the reader relies on:
//! `sd_bus_add_match` completes synchronously and returns a slot,
//! `sd_bus_get_property_string` hands back a malloc'd copy the caller must
//! free, `sd_bus_process` returns one queued message per call and then 0,
//! and `PropertiesChanged` is `s a{sv} as` with sd-bus container semantics
//! (`enter_container` returns 1 entered / 0 empty / negative type mismatch,
//! and a mismatch leaves the cursor in front of the variant for `skip`).

test {
    _ = @import("misc/locale1.zig");
}

const std = @import("std");
const locale1 = @import("misc/locale1.zig");

const Locale1 = locale1.Locale1;
const SdBusOps = locale1.SdBusOps;
const Message = locale1.Message;
const property_count = 4;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

// ---------------------------------------------------------------------------
// Fake sd-bus
// ---------------------------------------------------------------------------

const Call = enum {
    default_system,
    add_match,
    get_property,
    get_fd,
    get_events,
    get_timeout,
    process,
    slot_unref,
    unref,
};

const FakeMessage = struct {
    iface: []const u8 = locale1.interface,
    changed: []const Change = &.{},
    invalidated: []const []const u8 = &.{},

    iface_read: bool = false,
    dict_entered: bool = false,
    entry_entered: bool = false,
    entry_name_read: bool = false,
    variant_entered: bool = false,
    variant_mismatch: bool = false,
    dict_index: usize = 0,
    invalidated_entered: bool = false,
    invalidated_index: usize = 0,

    const Change = struct {
        name: []const u8,
        value: []const u8 = "",
        non_string: bool = false,
    };

    fn readString(self: *FakeMessage, ret: *?[]const u8) c_int {
        if (!self.iface_read) {
            self.iface_read = true;
            ret.* = self.iface;
            return 1;
        }
        if (self.variant_entered) {
            ret.* = self.changed[self.dict_index].value;
            return 1;
        }
        if (self.entry_entered and !self.entry_name_read) {
            self.entry_name_read = true;
            ret.* = self.changed[self.dict_index].name;
            return 1;
        }
        if (self.invalidated_entered) {
            if (self.invalidated_index < self.invalidated.len) {
                ret.* = self.invalidated[self.invalidated_index];
                self.invalidated_index += 1;
                return 1;
            }
            return 0;
        }
        @panic("fake message: unexpected read_string");
    }

    fn enter(self: *FakeMessage, typ: u8, contents: ?[*:0]const u8) c_int {
        const text = if (contents) |ptr| std.mem.span(ptr) else "";
        if (typ == 'a' and std.mem.eql(u8, text, "{sv}")) {
            self.dict_entered = self.changed.len > 0;
            return if (self.dict_entered) 1 else 0;
        }
        if (typ == 'e') {
            if (!self.dict_entered) @panic("fake message: entry outside array");
            if (self.dict_index >= self.changed.len) return 0;
            self.entry_entered = true;
            self.entry_name_read = false;
            return 1;
        }
        if (typ == 'v') {
            if (!self.entry_entered or !self.entry_name_read)
                @panic("fake message: variant outside entry");
            if (self.changed[self.dict_index].non_string) {
                self.variant_mismatch = true;
                return -22; // EINVAL: variant does not hold a string
            }
            self.variant_entered = true;
            return 1;
        }
        if (typ == 'a' and std.mem.eql(u8, text, "s")) {
            self.invalidated_entered = self.invalidated.len > 0;
            return if (self.invalidated_entered) 1 else 0;
        }
        @panic("fake message: unexpected enter_container");
    }

    fn exit(self: *FakeMessage) c_int {
        if (self.variant_entered) {
            self.variant_entered = false;
            return 1;
        }
        if (self.entry_entered) {
            self.entry_entered = false;
            self.entry_name_read = false;
            self.dict_index += 1;
            return 1;
        }
        if (self.dict_entered) {
            self.dict_entered = false;
            return 1;
        }
        if (self.invalidated_entered) {
            self.invalidated_entered = false;
            return 1;
        }
        @panic("fake message: unexpected exit_container");
    }

    fn skip(self: *FakeMessage, types: ?[*:0]const u8) c_int {
        const text = if (types) |ptr| std.mem.span(ptr) else "";
        if (!self.variant_mismatch or !std.mem.eql(u8, text, "v"))
            @panic("fake message: unexpected skip");
        self.variant_mismatch = false;
        return 1;
    }
};

const ScriptEvent = union(enum) {
    signal: *FakeMessage,
};

const Fake = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayListUnmanaged(Call) = .empty,
    script: std.ArrayListUnmanaged(ScriptEvent) = .empty,
    script_pos: usize = 0,

    prop_values: [property_count]?[]const u8 = .{ "pc105", "us", "", "" },
    prop_reads: [property_count]usize = @splat(0),

    match_string: ?[]u8 = null,
    match_cb: ?locale1.MatchCallback = null,
    match_userdata: ?*anyopaque = null,

    default_system_rc: c_int = 0,
    add_match_rc: c_int = 0,
    fd_value: c_int = 42,
    events_value: c_int = 1,
    timeout_rc: c_int = 1,
    timeout_deadline: u64 = 0,
    process_error: ?c_int = null,

    slot_node: SlotNode = undefined,

    const SlotNode = struct { fake: *Fake };

    fn create(allocator: std.mem.Allocator) !*Fake {
        const fake = try allocator.create(Fake);
        fake.* = .{ .allocator = allocator };
        fake.slot_node.fake = fake;
        return fake;
    }

    fn destroy(self: *Fake) void {
        if (self.match_string) |text| self.allocator.free(text);
        self.calls.deinit(self.allocator);
        self.script.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn record(self: *Fake, call: Call) void {
        self.calls.append(self.allocator, call) catch @panic("fake: out of memory");
    }

    fn pushSignal(self: *Fake, msg: *FakeMessage) !void {
        try self.script.append(self.allocator, .{ .signal = msg });
    }

    fn busPtr(self: *Fake) *locale1.Bus {
        return @ptrCast(self);
    }

    fn slotPtr(self: *Fake) *locale1.Slot {
        return @ptrCast(&self.slot_node);
    }

    fn ops(self: *Fake) SdBusOps {
        _ = self;
        return .{
            .default_system = fakeDefaultSystem,
            .add_match = fakeAddMatch,
            .slot_unref = fakeSlotUnref,
            .unref = fakeUnref,
            .get_property_string = fakeGetPropertyString,
            .free_string = fakeFreeString,
            .get_fd = fakeGetFd,
            .get_events = fakeGetEvents,
            .get_timeout = fakeGetTimeout,
            .process = fakeProcess,
            .message_read_string = fakeMessageReadString,
            .message_enter_container = fakeMessageEnterContainer,
            .message_exit_container = fakeMessageExitContainer,
            .message_skip = fakeMessageSkip,
        };
    }
};

fn fakeFromBus(bus: *locale1.Bus) *Fake {
    return @ptrCast(@alignCast(bus));
}

fn fakeFromMsg(msg: *Message) *FakeMessage {
    return @ptrCast(@alignCast(msg));
}

/// `sd_bus_default_system` hands back the bus handle with no userdata
/// argument. The test ops table is stateless, so each test points
/// `current_fake` at its fake before calling `Locale1.init`; that is the
/// one call that discovers the connection.
var current_fake: ?*Fake = null;

fn fakeDefaultSystem(ret: *?*locale1.Bus) c_int {
    const fake = current_fake orelse @panic("fake: current_fake not set");
    fake.record(.default_system);
    if (fake.default_system_rc < 0) return fake.default_system_rc;
    ret.* = fake.busPtr();
    return 0;
}

fn fakeAddMatch(
    bus: *locale1.Bus,
    ret_slot: ?*?*locale1.Slot,
    match: [*:0]const u8,
    callback: locale1.MatchCallback,
    userdata: ?*anyopaque,
) c_int {
    const fake = fakeFromBus(bus);
    fake.record(.add_match);
    if (fake.add_match_rc < 0) return fake.add_match_rc;
    if (fake.match_string) |text| fake.allocator.free(text);
    fake.match_string = fake.allocator.dupe(u8, std.mem.span(match)) catch return -12;
    fake.match_cb = callback;
    fake.match_userdata = userdata;
    if (ret_slot) |out| out.* = fake.slotPtr();
    return 0;
}

fn fakeSlotUnref(slot: *locale1.Slot) void {
    const node: *Fake.SlotNode = @ptrCast(@alignCast(slot));
    node.fake.record(.slot_unref);
}

fn fakeUnref(bus: *locale1.Bus) void {
    fakeFromBus(bus).record(.unref);
}

fn fakePropIndex(name: []const u8) ?usize {
    const names = [property_count][]const u8{
        "X11Model",
        "X11Layout",
        "X11Variant",
        "X11Options",
    };
    for (names, 0..) |candidate, i| {
        if (std.mem.eql(u8, name, candidate)) return i;
    }
    return null;
}

fn fakeGetPropertyString(
    bus: *locale1.Bus,
    destination: [*:0]const u8,
    path: [*:0]const u8,
    interface_name: [*:0]const u8,
    member: [*:0]const u8,
    ret: *?[*:0]u8,
) c_int {
    const fake = fakeFromBus(bus);
    fake.record(.get_property);
    if (!std.mem.eql(u8, std.mem.span(destination), locale1.service)) return -22;
    if (!std.mem.eql(u8, std.mem.span(path), locale1.object_path)) return -22;
    if (!std.mem.eql(u8, std.mem.span(interface_name), locale1.interface)) return -22;
    const index = fakePropIndex(std.mem.span(member)) orelse return -22;
    fake.prop_reads[index] += 1;
    const value = fake.prop_values[index] orelse return -6; // ENXIO
    const owned = std.testing.allocator.dupeSentinel(u8, value, 0) catch return -12;
    ret.* = owned.ptr;
    return 1;
}

fn fakeFreeString(value: [*:0]u8) void {
    const len = std.mem.len(value);
    std.testing.allocator.free(value[0 .. len + 1]);
}

fn fakeGetFd(bus: *locale1.Bus) c_int {
    const fake = fakeFromBus(bus);
    fake.record(.get_fd);
    return fake.fd_value;
}

fn fakeGetEvents(bus: *locale1.Bus) c_int {
    const fake = fakeFromBus(bus);
    fake.record(.get_events);
    return fake.events_value;
}

fn fakeGetTimeout(bus: *locale1.Bus, ret: *u64) c_int {
    const fake = fakeFromBus(bus);
    fake.record(.get_timeout);
    ret.* = fake.timeout_deadline;
    return fake.timeout_rc;
}

fn fakeProcess(bus: *locale1.Bus, ret: ?*?*Message) c_int {
    _ = ret;
    const fake = fakeFromBus(bus);
    fake.record(.process);
    if (fake.process_error) |rc| {
        fake.process_error = null;
        return rc;
    }
    if (fake.script_pos >= fake.script.items.len) return 0;
    const event = fake.script.items[fake.script_pos];
    fake.script_pos += 1;
    switch (event) {
        .signal => |msg| {
            const callback = fake.match_cb orelse @panic("fake: no match callback");
            const rc = callback(@ptrCast(msg), fake.match_userdata, null);
            if (rc < 0) return rc;
            return 1;
        },
    }
}

fn fakeMessageReadString(msg: *Message, ret: *?[]const u8) c_int {
    return fakeFromMsg(msg).readString(ret);
}

fn fakeMessageEnterContainer(msg: *Message, typ: u8, contents: ?[*:0]const u8) c_int {
    return fakeFromMsg(msg).enter(typ, contents);
}

fn fakeMessageExitContainer(msg: *Message) c_int {
    return fakeFromMsg(msg).exit();
}

fn fakeMessageSkip(msg: *Message, types: [*:0]const u8) c_int {
    return fakeFromMsg(msg).skip(types);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "init installs the match, then reads the four properties" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    fake.prop_values = .{ "pc105", "de", "nodeadkeys", "ctrl:nocaps" };
    current_fake = fake;

    var locale = try Locale1.init(std.testing.allocator, fake.ops());
    defer locale.deinit();

    const opts = locale.keymapOptions();
    try expectEqualStrings("pc105", opts.model);
    try expectEqualStrings("de", opts.layout);
    try expectEqualStrings("nodeadkeys", opts.variant);
    try expectEqualStrings("ctrl:nocaps", opts.options);

    // Production order: connect, install match, then read. Nothing else.
    try expectEqual(@as(usize, 6), fake.calls.items.len);
    try expectEqual(Call.default_system, fake.calls.items[0]);
    try expectEqual(Call.add_match, fake.calls.items[1]);
    for (fake.calls.items[2..6]) |call| try expectEqual(Call.get_property, call);
    for (fake.prop_reads) |count| try expectEqual(@as(usize, 1), count);

    // The match rule is the exact arg0-filtered one from the reference.
    const expected_match =
        "type='signal',sender='org.freedesktop.locale1'," ++
        "path='/org/freedesktop/locale1'," ++
        "interface='org.freedesktop.DBus.Properties'," ++
        "member='PropertiesChanged',arg0='org.freedesktop.locale1'";
    try expectEqualStrings(expected_match, fake.match_string.?);
    try expectEqualStrings(expected_match, locale1.match_rule);
    try expect(fake.match_cb != null);
    try expect(fake.match_userdata != null);
}

test "unset and empty properties surface as empty strings" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    fake.prop_values = .{ "", "", "", "" };
    current_fake = fake;

    var locale = try Locale1.init(std.testing.allocator, fake.ops());
    defer locale.deinit();

    const opts = locale.keymapOptions();
    try expectEqual(@as(usize, 0), opts.model.len);
    try expectEqual(@as(usize, 0), opts.layout.len);
    try expectEqual(@as(usize, 0), opts.variant.len);
    try expectEqual(@as(usize, 0), opts.options.len);

    // "" maps to null ("xkbcommon default") for xkb.Keymap.reload.
    const XkbOptions = struct {
        model: ?[]const u8 = null,
        layout: ?[]const u8 = null,
        variant: ?[]const u8 = null,
        options: ?[]const u8 = null,
        keymap_file: ?[]const u8 = null,
    };
    const converted = opts.toXkb(XkbOptions);
    try expectEqual(@as(?[]const u8, null), converted.model);
    try expectEqual(@as(?[]const u8, null), converted.layout);
    try expectEqual(@as(?[]const u8, null), converted.variant);
    try expectEqual(@as(?[]const u8, null), converted.options);
    try expectEqual(@as(?[]const u8, null), converted.keymap_file);
}

test "failed property reads leave the value unset instead of failing init" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    // null = the property read fails (e.g. localed not running).
    fake.prop_values = .{ null, "de", null, "ctrl:nocaps" };
    current_fake = fake;

    var locale = try Locale1.init(std.testing.allocator, fake.ops());
    defer locale.deinit();

    const opts = locale.keymapOptions();
    try expectEqualStrings("", opts.model);
    try expectEqualStrings("de", opts.layout);
    try expectEqualStrings("", opts.variant);
    try expectEqualStrings("ctrl:nocaps", opts.options);
}

test "PropertiesChanged returns the new options exactly once" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    fake.prop_values = .{ "pc105", "de", "", "" };
    current_fake = fake;

    var locale = try Locale1.init(std.testing.allocator, fake.ops());
    defer locale.deinit();

    var signal = FakeMessage{ .changed = &.{
        .{ .name = "X11Layout", .value = "us" },
        .{ .name = "X11Variant", .value = "intl" },
        .{ .name = "VConsoleKeymap", .value = "de-latin1" }, // not ours
    } };
    try fake.pushSignal(&signal);

    const first = try locale.process();
    try expect(first != null);
    const opts = first.?.options;
    try expectEqualStrings("pc105", opts.model);
    try expectEqualStrings("us", opts.layout);
    try expectEqualStrings("intl", opts.variant);
    try expectEqualStrings("", opts.options);

    // Nothing changed since: null (and no extra property reads).
    const reads_before = fake.prop_reads;
    try expectEqual(@as(?locale1.KeymapChange, null), try locale.process());
    try expectEqual(reads_before, fake.prop_reads);
}

test "invalidated properties are re-read after the process loop" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    fake.prop_values = .{ "pc105", "de", "", "" };
    current_fake = fake;

    var locale = try Locale1.init(std.testing.allocator, fake.ops());
    defer locale.deinit();
    try expectEqual(@as(usize, 1), fake.prop_reads[1]);

    // localed changed the layout without shipping a value.
    fake.prop_values[1] = "us";
    var signal = FakeMessage{ .invalidated = &.{"X11Layout"} };
    try fake.pushSignal(&signal);

    const change = try locale.process();
    try expect(change != null);
    try expectEqualStrings("us", change.?.options.layout);
    try expectEqualStrings("pc105", change.?.options.model);
    try expectEqual(@as(usize, 2), fake.prop_reads[1]);
    // Only the invalidated name was re-read.
    try expectEqual(@as(usize, 1), fake.prop_reads[0]);
    try expectEqual(@as(usize, 1), fake.prop_reads[2]);
    try expectEqual(@as(usize, 1), fake.prop_reads[3]);
}

test "unchanged values, unknown properties and invalidated non-X11 names yield null" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    fake.prop_values = .{ "pc105", "de", "", "" };
    current_fake = fake;

    var locale = try Locale1.init(std.testing.allocator, fake.ops());
    defer locale.deinit();

    // Same value as the snapshot.
    var equal_signal = FakeMessage{ .changed = &.{
        .{ .name = "X11Layout", .value = "de" },
    } };
    try fake.pushSignal(&equal_signal);
    try expectEqual(@as(?locale1.KeymapChange, null), try locale.process());

    // Properties we do not track, both changed and invalidated.
    var other_signal = FakeMessage{
        .changed = &.{
            .{ .name = "Locale", .value = "de_DE.UTF-8" },
        },
        .invalidated = &.{ "VConsoleKeymap", "VConsoleKeymapToggle" },
    };
    try fake.pushSignal(&other_signal);
    const reads_before = fake.prop_reads;
    try expectEqual(@as(?locale1.KeymapChange, null), try locale.process());
    try expectEqual(reads_before, fake.prop_reads);
}

test "PropertiesChanged for another interface is ignored" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    fake.prop_values = .{ "pc105", "de", "", "" };
    current_fake = fake;

    var locale = try Locale1.init(std.testing.allocator, fake.ops());
    defer locale.deinit();

    var signal = FakeMessage{
        .iface = "org.freedesktop.login1",
        .changed = &.{
            .{ .name = "X11Layout", .value = "us" },
        },
        .invalidated = &.{"X11Layout"},
    };
    try fake.pushSignal(&signal);

    try expectEqual(@as(?locale1.KeymapChange, null), try locale.process());
    try expectEqualStrings("de", locale.keymapOptions().layout);
    try expectEqual(@as(usize, 1), fake.prop_reads[1]);
}

test "non-string variants are skipped, not misparsed" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    current_fake = fake;

    var locale = try Locale1.init(std.testing.allocator, fake.ops());
    defer locale.deinit();

    var signal = FakeMessage{
        .changed = &.{
            .{ .name = "VConsoleKeymap", .non_string = true },
            .{ .name = "X11Model", .value = "pc104" },
        },
    };
    try fake.pushSignal(&signal);

    const change = try locale.process();
    try expect(change != null);
    try expectEqualStrings("pc104", change.?.options.model);
}

test "timeout converts the absolute monotonic deadline to remaining time" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    current_fake = fake;

    var locale = try Locale1.init(std.testing.allocator, fake.ops());
    defer locale.deinit();

    fake.timeout_deadline = 1_000_500;
    try expectEqual(@as(?u64, 500), try locale.timeout(1_000_000));
    try expectEqual(@as(?u64, 1), try locale.timeoutMs(1_000_000));

    // Deadline already passed: no wait.
    fake.timeout_deadline = 999_999;
    try expectEqual(@as(?u64, 0), try locale.timeout(1_000_000));
    try expectEqual(@as(?u64, 0), try locale.timeoutMs(1_000_000));

    // UINT64_MAX and "no timeout set" both mean infinite.
    fake.timeout_deadline = locale1.infinite_timeout;
    try expectEqual(@as(?u64, null), try locale.timeout(1_000_000));
    fake.timeout_rc = 0;
    fake.timeout_deadline = 5;
    try expectEqual(@as(?u64, null), try locale.timeout(1_000_000));

    fake.timeout_rc = -5;
    try expectError(error.BusTimeoutUnavailable, locale.timeout(1_000_000));
}

test "fd and events pass through sd-bus and reject negative values" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    current_fake = fake;

    var locale = try Locale1.init(std.testing.allocator, fake.ops());
    defer locale.deinit();

    try expectEqual(@as(c_int, 42), try locale.fd());
    try expectEqual(@as(c_int, 1), try locale.events());

    fake.fd_value = -9;
    fake.events_value = -9;
    try expectError(error.BusFdUnavailable, locale.fd());
    try expectError(error.BusEventsUnavailable, locale.events());
}

test "process propagates sd_bus_process errors" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    current_fake = fake;

    var locale = try Locale1.init(std.testing.allocator, fake.ops());
    defer locale.deinit();

    fake.process_error = -5;
    try expectError(error.BusProcessFailed, locale.process());
}

test "deinit drops the match before the bus reference" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    current_fake = fake;

    var locale = try Locale1.init(std.testing.allocator, fake.ops());
    locale.deinit();

    const calls = fake.calls.items;
    try expectEqual(Call.slot_unref, calls[calls.len - 2]);
    try expectEqual(Call.unref, calls[calls.len - 1]);
}

test "init failure paths clean up" {
    // sd_bus_default_system fails: nothing to unref.
    {
        const fake = try Fake.create(std.testing.allocator);
        defer fake.destroy();
        fake.default_system_rc = -1;
        current_fake = fake;

        try expectError(error.BusUnavailable, Locale1.init(std.testing.allocator, fake.ops()));
        try expectEqual(@as(usize, 1), fake.calls.items.len);
        try expectEqual(Call.default_system, fake.calls.items[0]);
    }

    // Match installation fails: the bus reference is dropped, the slot is
    // never created.
    {
        const fake = try Fake.create(std.testing.allocator);
        defer fake.destroy();
        fake.add_match_rc = -5;
        current_fake = fake;

        try expectError(error.MatchFailed, Locale1.init(std.testing.allocator, fake.ops()));
        try expectEqual(@as(usize, 3), fake.calls.items.len);
        try expectEqual(Call.default_system, fake.calls.items[0]);
        try expectEqual(Call.add_match, fake.calls.items[1]);
        try expectEqual(Call.unref, fake.calls.items[2]);
    }
}

// ---------------------------------------------------------------------------
// Startup one-shot read (Locale1.readCurrent) and config overlay
// ---------------------------------------------------------------------------

test "readCurrent returns the current properties without installing a match" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    fake.prop_values = .{ "pc105", "de", "nodeadkeys", "ctrl:nocaps" };
    current_fake = fake;

    var current = try Locale1.readCurrent(std.testing.allocator, fake.ops());
    defer current.deinit();

    const opts = current.options();
    try expectEqualStrings("pc105", opts.model);
    try expectEqualStrings("de", opts.layout);
    try expectEqualStrings("nodeadkeys", opts.variant);
    try expectEqualStrings("ctrl:nocaps", opts.options);

    // One-shot: connect, read the four properties, drop the bus. No match.
    try expectEqual(@as(usize, 6), fake.calls.items.len);
    try expectEqual(Call.default_system, fake.calls.items[0]);
    for (fake.calls.items[1..5]) |call| try expectEqual(Call.get_property, call);
    try expectEqual(Call.unref, fake.calls.items[5]);
    try expect(fake.match_cb == null);
    try expect(fake.match_string == null);
    for (fake.prop_reads) |count| try expectEqual(@as(usize, 1), count);
}

test "readCurrent: absent localed yields empty options, not an error" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    // null = every property read fails (e.g. localed not running).
    fake.prop_values = .{ null, null, null, null };
    current_fake = fake;

    var current = try Locale1.readCurrent(std.testing.allocator, fake.ops());
    defer current.deinit();

    const opts = current.options();
    try expectEqual(@as(usize, 0), opts.model.len);
    try expectEqual(@as(usize, 0), opts.layout.len);
    try expectEqual(@as(usize, 0), opts.variant.len);
    try expectEqual(@as(usize, 0), opts.options.len);
    // Still a clean one-shot: the bus reference is dropped.
    try expectEqual(Call.unref, fake.calls.items[fake.calls.items.len - 1]);
}

test "readCurrent: empty properties yield empty options" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    fake.prop_values = .{ "", "", "", "" };
    current_fake = fake;

    var current = try Locale1.readCurrent(std.testing.allocator, fake.ops());
    defer current.deinit();

    const opts = current.options();
    try expectEqual(@as(usize, 0), opts.model.len);
    try expectEqual(@as(usize, 0), opts.layout.len);
    try expectEqual(@as(usize, 0), opts.variant.len);
    try expectEqual(@as(usize, 0), opts.options.len);
}

test "readCurrent: partial properties keep unset fields empty" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    fake.prop_values = .{ null, "de", "", "ctrl:nocaps" };
    current_fake = fake;

    var current = try Locale1.readCurrent(std.testing.allocator, fake.ops());
    defer current.deinit();

    const opts = current.options();
    try expectEqualStrings("", opts.model);
    try expectEqualStrings("de", opts.layout);
    try expectEqualStrings("", opts.variant);
    try expectEqualStrings("ctrl:nocaps", opts.options);
}

test "readCurrent: bus unavailable is an error and installs nothing" {
    const fake = try Fake.create(std.testing.allocator);
    defer fake.destroy();
    fake.default_system_rc = -1;
    current_fake = fake;

    try expectError(error.BusUnavailable, Locale1.readCurrent(std.testing.allocator, fake.ops()));
    try expectEqual(@as(usize, 1), fake.calls.items.len);
    try expectEqual(Call.default_system, fake.calls.items[0]);
    try expect(fake.match_cb == null);
}

test "overlay: explicit config wins, unset fields take locale1, keymap_file preserved" {
    const TestOptions = struct {
        model: ?[]const u8 = null,
        layout: ?[]const u8 = null,
        variant: ?[]const u8 = null,
        options: ?[]const u8 = null,
        keymap_file: ?[]const u8 = null,
    };
    const loc = locale1.KeymapOptions{
        .model = "pc105",
        .layout = "de",
        .variant = "nodeadkeys",
        .options = "ctrl:nocaps",
    };

    // All-unset config: every field takes locale1; keymap_file carried through.
    const filled = loc.overlay(TestOptions, .{ .keymap_file = "/path/keymap.xkb" });
    try expectEqualStrings("pc105", filled.model.?);
    try expectEqualStrings("de", filled.layout.?);
    try expectEqualStrings("nodeadkeys", filled.variant.?);
    try expectEqualStrings("ctrl:nocaps", filled.options.?);
    try expectEqualStrings("/path/keymap.xkb", filled.keymap_file.?);

    // Explicit config wins over locale1.
    const explicit = loc.overlay(TestOptions, .{ .layout = "us", .options = "terminate:ctrl_alt_bksp" });
    try expectEqualStrings("pc105", explicit.model.?);
    try expectEqualStrings("us", explicit.layout.?);
    try expectEqualStrings("nodeadkeys", explicit.variant.?);
    try expectEqualStrings("terminate:ctrl_alt_bksp", explicit.options.?);

    // Empty-string config counts as unset and is filled from locale1.
    const empty_cfg = loc.overlay(TestOptions, .{ .layout = "" });
    try expectEqualStrings("de", empty_cfg.layout.?);

    // Empty locale1 fields leave an unset config unset (xkbcommon default).
    const empty_loc = locale1.KeymapOptions{};
    const untouched = empty_loc.overlay(TestOptions, .{});
    try expectEqual(@as(?[]const u8, null), untouched.model);
    try expectEqual(@as(?[]const u8, null), untouched.layout);
    try expectEqual(@as(?[]const u8, null), untouched.variant);
    try expectEqual(@as(?[]const u8, null), untouched.options);

    // Partial locale1: only the set fields fill.
    const partial = locale1.KeymapOptions{ .layout = "fr" };
    const partial_cfg = partial.overlay(TestOptions, .{ .model = "pc104" });
    try expectEqualStrings("pc104", partial_cfg.model.?);
    try expectEqualStrings("fr", partial_cfg.layout.?);
    try expectEqual(@as(?[]const u8, null), partial_cfg.variant);
    try expectEqual(@as(?[]const u8, null), partial_cfg.options);
}