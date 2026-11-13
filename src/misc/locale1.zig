//! src/misc/locale1.zig -- org.freedesktop.locale1 X11 keymap reader and
//! live follower (ROADMAP M6.5).
//!
//! systemd-localed exports four string properties that map directly onto
//! xkbcommon's RMLVO model/layout/variant/options:
//!
//!     org.freedesktop.locale1  /org/freedesktop/locale1
//!         X11Model    s
//!         X11Layout   s
//!         X11Variant  s
//!         X11Options  s
//!
//! All four are read from the **system** bus
//! (`org.freedesktop.locale1`, `locale/localed.c:557-600`). An unset value
//! is the empty string, not an error (`property_get_xkb`,
//! `localed.c:91-126`), so `keymapOptions()` reports `""` for unset and
//! `KeymapOptions.toXkb` turns that back into `null` ("xkbcommon default")
//! when feeding `xkb.Keymap.reload`.
//!
//! The module is a thin sd-bus client, not a bus daemon: it opens the
//! per-thread default system connection, installs one match, reads the four
//! properties, and afterwards reports changes through `process`. It never
//! calls `Set*` (those need polkit; kmshaunt only reads).
//!
//! # Call sequence
//!
//! 1. `sd_bus_default_system`
//! 2. `sd_bus_add_match` with the exact rule below (installed
//!    synchronously: it returns after the broker confirmed it)
//! 3. four `sd_bus_get_property_string` calls
//!
//! The match is installed *before* the initial read on purpose: a change
//! that lands between the read and the match installation would otherwise
//! be lost. sd-bus queues matching signals until `process` is called, so a
//! signal racing the initial read is delivered with the new value later.
//!
//! # Exact match rule
//!
//!     type='signal',sender='org.freedesktop.locale1',
//!     path='/org/freedesktop/locale1',
//!     interface='org.freedesktop.DBus.Properties',
//!     member='PropertiesChanged',
//!     arg0='org.freedesktop.locale1'
//!
//! `arg0` filters on the changed interface, so signals about `Locale` or
//! `VConsoleKeymap` on the same object path never reach the callback
//! (`docs/reference/libseat-sdlogin.md` §5.3). The callback still checks
//! `arg0` itself because the local match filtering is a brokered feature and
//! a fake/test bus may deliver more than the rule asks.
//!
//! `PropertiesChanged` has signature `s a{sv} as`: interface, changed
//! values, invalidated names. A changed name we care about is stored
//! immediately; *invalidated* names carry no value and are re-read with
//! `sd_bus_get_property_string` after the `sd_bus_process` loop drains
//! (`§5.4`). Re-reading after the loop instead of inside the callback keeps
//! blocking round trips out of a message handler.
//!
//! # Epoll integration
//!
//! `src/loop.zig` owns the event loop, so this module exposes the sd-bus fd
//! trio instead of attaching an sd-event loop (`§5.5`):
//!
//! * `fd()` -- pollable descriptor (may be sd-bus's internal inotify fd).
//! * `events()` -- current `POLLIN`/`POLLOUT` mask; re-read every iteration
//!   because the write queue drains.
//! * `timeoutMs(now_us)` -- `sd_bus_get_timeout` returns an **absolute**
//!   CLOCK_MONOTONIC deadline in microseconds (`UINT64_MAX` = infinite).
//!   The remaining time is rounded *up* to milliseconds; `null` means -1.
//!   Never pass the raw absolute value to `epoll_wait`.
//!
//! Call `process()` when the fd fires (or the timeout expires). It drains
//! `sd_bus_process` down to 0 and returns a `KeymapChange` only when one of
//! the four X11 values actually changed.
//!
//! # Lifetimes and errors
//!
//! Strings returned by `keymapOptions`/`process` are owned by the `Locale1`
//! and stay valid until the next `process`/`init`/`deinit` on the same
//! instance. The `Locale1` value owns a small heap `CallbackState`; the
//! match callback's `userdata` points at that allocation, so returning the
//! `Locale1` by value from `init` is safe.
//!
//! A missing localed is not an init failure: property reads that fail (e.g.
//! `ServiceUnknown`/`NameHasNoOwner` on containers) leave the value unset,
//! i.e. `""`, and the caller falls back to the `XKB_DEFAULT_*` environment
//! or its own config. Only `sd_bus_default_system`, `sd_bus_add_match` and
//! allocation failures abort `init` (`§5.6`). The bus connection is
//! per-thread and shared; `deinit` removes the match slot and drops the
//! reference (`sd_bus_slot_unref` then `sd_bus_unref`).
//!
//! # Startup one-shot read
//!
//! `Locale1.readCurrent(allocator, ops)` performs the same four property
//! reads *without* installing a match and *without* keeping the bus
//! reference: it returns an owned `CurrentKeymap` for callers that need
//! locale1's current layout before the live follower exists (e.g. to seed
//! the initial keymap, kmscon parity). `CurrentKeymap.options()` borrows the
//! values until `deinit`. A missing localed or a failed read surfaces as
//! `""`, exactly like `init`; only bus-open and allocation failures are
//! returned as errors.
//!
//! All C access goes through the `SdBusOps` function-pointer seam. The
//! production table `real` is the only user of the translate-c module
//! `sd-bus-c`; it is analyzed lazily, so the hermetic tests below compile
//! and run without systemd, without a bus and without `-lsystemd`.
//!
//! # Standalone tests (hermetic, fake bus)
//!
//!     nix run nixpkgs#zig -- test src/test_locale1.zig
//!
//! # Optional real-bus probe (requires a running system bus with localed)
//!
//!     nix build nixpkgs#systemd.dev nixpkgs#systemd --print-out-paths --no-link
//!     # /tmp/sd_bus_shim.c contains only: #include <systemd/sd-bus.h>
//!     nix run nixpkgs#zig -- translate-c -lc \
//!         -I<systemd-dev>/include /tmp/sd_bus_shim.c > /tmp/sd_bus_c.zig
//!     # create src/locale1_probe.zig (temporary) with a main() that does
//!     # `@import("misc/locale1.zig")`, `Locale1.init(allocator, locale1.real)`
//!     # and prints keymapOptions(); then:
//!     LD_LIBRARY_PATH=<systemd>/lib nix run nixpkgs#zig -- run \
//!         --dep sd-bus-c -Mroot=src/locale1_probe.zig \
//!         -Msd-bus-c=/tmp/sd_bus_c.zig \
//!         -lc -L<systemd>/lib -lsystemd
//!
//! The probe prints the live RMLVO values (e.g. `model='pc104' layout='us'
//! variant='' options='terminate:ctrl_alt_bksp'`), the sd-bus fd/events and
//! a quiet `process()` result of `null`. Delete the probe afterwards.
//!
//! The `sd-bus-c` module is what `build.zig` wires from `b.addTranslateC`
//! over `#include <systemd/sd-bus.h>` (`sd-bus.h` needs libc headers, so
//! translate-c needs `-lc`).

const std = @import("std");

// ---------------------------------------------------------------------------
// Opaque sd-bus handles
// ---------------------------------------------------------------------------

/// `sd_bus *`.
pub const Bus = opaque {};
/// `sd_bus_slot *` (the match slot; unref'd in `deinit`).
pub const Slot = opaque {};
/// `sd_bus_message *` (only valid inside the match callback).
pub const Message = opaque {};

/// `sd_bus_message_handler_t`. The third argument is `sd_bus_error *`; it is
/// opaque here because this module never sets or reads an error object (all
/// calls pass/accept NULL).
pub const MatchCallback = *const fn (
    m: ?*Message,
    userdata: ?*anyopaque,
    ret_error: ?*anyopaque,
) callconv(.c) c_int;

const property_count = 4;

/// `X11Model`, `X11Layout`, `X11Variant`, `X11Options` -- the order is the
/// storage order used by `CallbackState.values` and the enum tag order.
const Property = enum(u2) { model, layout, variant, options };

const property_names = [property_count][:0]const u8{
    "X11Model",
    "X11Layout",
    "X11Variant",
    "X11Options",
};

/// Well-known name, object path and interface (`locale/localed.c:557-590`).
pub const service = "org.freedesktop.locale1";
pub const object_path = "/org/freedesktop/locale1";
pub const interface = "org.freedesktop.locale1";
pub const properties_interface = "org.freedesktop.DBus.Properties";

/// The exact `PropertiesChanged` match rule (`libseat-sdlogin.md` §5.3).
pub const match_rule =
    "type='signal',sender='org.freedesktop.locale1'," ++
    "path='/org/freedesktop/locale1'," ++
    "interface='org.freedesktop.DBus.Properties'," ++
    "member='PropertiesChanged'," ++
    "arg0='org.freedesktop.locale1'";

/// `sd_bus_get_timeout`'s "no deadline" value (`UINT64_MAX`).
pub const infinite_timeout: u64 = std.math.maxInt(u64);

/// Errno values mirrored from `<errno.h>`; sd-bus returns negative errno and
/// never uses `errno` as a side channel.
const enomem: c_int = 12;
const eproto: c_int = 71;

// ---------------------------------------------------------------------------
// Injectable seam
// ---------------------------------------------------------------------------

/// Injectable seam over every sd-bus call the reader makes. Tests install a
/// fake implementation; production uses `real`.
///
/// Signatures follow the `<systemd/sd-bus.h>` prototypes with the ownership
/// rules made explicit:
///
/// * `add_match` returns only after the broker installed the rule
///   synchronously and writes the slot used to remove it again.
/// * `get_property_string` returns a libc-malloc'd, NUL-terminated string in
///   `ret` on success; release it with `free_string`.
/// * `message_read_string` borrows from the message (valid until the next
///   message operation); the callback copies what it keeps.
/// * `message_enter_container` returns 1 entered, 0 empty, negative error
///   (a variant type mismatch is negative and leaves the cursor outside, so
///   the caller falls back to `message_skip`).
pub const SdBusOps = struct {
    default_system: *const fn (ret: *?*Bus) c_int,
    add_match: *const fn (
        bus: *Bus,
        ret_slot: ?*?*Slot,
        match: [*:0]const u8,
        callback: MatchCallback,
        userdata: ?*anyopaque,
    ) c_int,
    slot_unref: *const fn (slot: *Slot) void,
    unref: *const fn (bus: *Bus) void,
    get_property_string: *const fn (
        bus: *Bus,
        destination: [*:0]const u8,
        path: [*:0]const u8,
        interface: [*:0]const u8,
        member: [*:0]const u8,
        ret: *?[*:0]u8,
    ) c_int,
    free_string: *const fn (s: [*:0]u8) void,
    get_fd: *const fn (bus: *Bus) c_int,
    get_events: *const fn (bus: *Bus) c_int,
    get_timeout: *const fn (bus: *Bus, ret: *u64) c_int,
    process: *const fn (bus: *Bus, ret: ?*?*Message) c_int,
    message_read_string: *const fn (msg: *Message, ret: *?[]const u8) c_int,
    message_enter_container: *const fn (msg: *Message, typ: u8, contents: ?[*:0]const u8) c_int,
    message_exit_container: *const fn (msg: *Message) c_int,
    message_skip: *const fn (msg: *Message, types: [*:0]const u8) c_int,
};

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

/// RMLVO values as reported by locale1. Each field is a borrowed slice;
/// `""` means "locale1 has no value" and callers fall back to their default.
/// Field names and meaning match `xkb.Keymap.Options`, but the optional
/// distinction is made by `toXkb`.
pub const KeymapOptions = struct {
    model: []const u8 = "",
    layout: []const u8 = "",
    variant: []const u8 = "",
    options: []const u8 = "",

    /// Convert to a struct with the same four field names but nullable
    /// values (e.g. `xkb.Keymap.Options`), mapping `""` to `null`, which
    /// xkbcommon reads as "use the default":
    ///
    ///     keymap.reload(locale.keymapOptions().toXkb(xkb.Keymap.Options));
    pub fn toXkb(self: KeymapOptions, comptime T: type) T {
        return .{
            .model = optionalSlice(self.model),
            .layout = optionalSlice(self.layout),
            .variant = optionalSlice(self.variant),
            .options = optionalSlice(self.options),
        };
    }

    fn optionalSlice(value: []const u8) ?[]const u8 {
        return if (value.len == 0) null else value;
    }

    /// Overlay these locale1 values onto an explicit RMLVO config `cfg`
    /// (kmscon `useXkbConfig` parity): a config field that is set (non-null
    /// and non-empty) always wins; an unset field takes the locale1 value
    /// when it is non-empty, and stays unset otherwise. `T` must expose the
    /// four nullable fields `model`/`layout`/`variant`/`options` (e.g.
    /// `xkb.Keymap.Options`); any other field (such as `keymap_file`) is
    /// carried through unchanged.
    pub fn overlay(self: KeymapOptions, comptime T: type, cfg: T) T {
        var result = cfg;
        inline for (.{ "model", "layout", "variant", "options" }) |name| {
            const locale_value = @field(self, name);
            const config_value = @field(result, name);
            const config_unset = if (config_value) |v| v.len == 0 else true;
            if (config_unset and locale_value.len > 0) {
                @field(result, name) = locale_value;
            }
        }
        return result;
    }
};

/// Result of `process`: one or more of the four values changed (or were
/// invalidated and re-read into a different value). `options` borrows from
/// the `Locale1`; it is valid until the next `process`/`deinit`.
pub const KeymapChange = struct {
    options: KeymapOptions,
};

/// Owned snapshot of locale1's current X11 properties, produced by
/// `Locale1.readCurrent` for the startup read. The strings live until
/// `deinit`; `options()` borrows them. Unlike a live `Locale1`, no match is
/// installed and no bus reference is kept after the read.
pub const CurrentKeymap = struct {
    allocator: std.mem.Allocator,
    values: [property_count]?[]u8 = @splat(null),

    pub fn deinit(self: *CurrentKeymap) void {
        for (self.values) |value| {
            if (value) |owned| self.allocator.free(owned);
        }
        self.* = undefined;
    }

    /// Borrowed RMLVO view; `""` means unset (fall back to config/default).
    pub fn options(self: *const CurrentKeymap) KeymapOptions {
        return .{
            .model = self.values[@intFromEnum(Property.model)] orelse "",
            .layout = self.values[@intFromEnum(Property.layout)] orelse "",
            .variant = self.values[@intFromEnum(Property.variant)] orelse "",
            .options = self.values[@intFromEnum(Property.options)] orelse "",
        };
    }
};

// ---------------------------------------------------------------------------
// Callback state
// ---------------------------------------------------------------------------

/// The mutable state the sd-bus match callback touches. It lives in one heap
/// allocation owned by `Locale1` so the callback's `userdata` stays valid
/// when `init` returns the `Locale1` by value.
pub const CallbackState = struct {
    allocator: std.mem.Allocator,
    ops: SdBusOps,
    /// Owned values; `null` = unset (reported as `""`).
    values: [property_count]?[]u8 = @splat(null),
    /// Set when one of the four values changed; cleared by `process`.
    dirty: bool = false,
    /// Properties named in `PropertiesChanged`'s invalidated array; re-read
    /// after the sd-bus message loop drains.
    invalidated: [property_count]bool = @splat(false),

    fn deinit(self: *CallbackState) void {
        for (self.values) |value| {
            if (value) |owned| self.allocator.free(owned);
        }
    }

    const PropertyRead = union(enum) {
        /// Owned string; empty is normalized to `.unset` by `read`.
        value: []u8,
        unset,
        failed,
    };

    /// One `sd_bus_get_property_string`. Read errors are not fatal: localed
    /// may be absent, and the caller keeps the current value.
    fn read(self: *CallbackState, bus: *Bus, prop: Property) !PropertyRead {
        var raw: ?[*:0]u8 = null;
        const rc = self.ops.get_property_string(
            bus,
            service,
            object_path,
            interface,
            property_names[@intFromEnum(prop)],
            &raw,
        );
        if (rc < 0) return .failed;
        const ptr = raw orelse return error.BadPropertyReturn;
        defer self.ops.free_string(ptr);
        const value = std.mem.span(ptr);
        if (value.len == 0) return .unset;
        return .{ .value = try self.allocator.dupe(u8, value) };
    }

    /// Re-read one property and record whether it differs from the stored
    /// value. Read failures leave the stored value alone.
    fn refresh(self: *CallbackState, bus: *Bus, prop: Property) !void {
        switch (try self.read(bus, prop)) {
            .value => |owned| {
                if (self.adopt(prop, owned)) self.dirty = true;
            },
            .unset => {
                if (self.adopt(prop, null)) self.dirty = true;
            },
            .failed => {},
        }
    }

    fn refreshAll(self: *CallbackState, bus: *Bus) !void {
        for (0..property_count) |i| try self.refresh(bus, @enumFromInt(i));
    }

    /// Store a newly allocated value (ownership transferred), freeing the
    /// previous one. Returns whether the visible value changed.
    fn adopt(self: *CallbackState, prop: Property, owned: ?[]u8) bool {
        const index = @intFromEnum(prop);
        const old = self.values[index] orelse "";
        const new = owned orelse "";
        if (std.mem.eql(u8, old, new)) {
            if (owned) |value| self.allocator.free(value);
            return false;
        }
        if (self.values[index]) |value| self.allocator.free(value);
        self.values[index] = owned;
        return true;
    }

    /// Copy-and-store a borrowed value, normalizing `""` to unset.
    fn replace(self: *CallbackState, prop: Property, value: []const u8) !bool {
        const owned: ?[]u8 = if (value.len == 0) null else try self.allocator.dupe(u8, value);
        return self.adopt(prop, owned);
    }

    fn handlePropertiesChanged(self: *CallbackState, msg: *Message) c_int {
        var iface: ?[]const u8 = null;
        var rc = self.ops.message_read_string(msg, &iface);
        if (rc < 0) return rc;
        if (rc == 0) return 0;
        if (!std.mem.eql(u8, iface orelse "", interface)) return 0;

        // s a{sv} as -- changed values first.
        rc = self.ops.message_enter_container(msg, 'a', "{sv}");
        if (rc < 0) return rc;
        if (rc > 0) {
            while (true) {
                rc = self.ops.message_enter_container(msg, 'e', "sv");
                if (rc < 0) return rc;
                if (rc == 0) break;

                var name: ?[]const u8 = null;
                rc = self.ops.message_read_string(msg, &name);
                if (rc < 0) return rc;
                if (rc == 0) return -eproto;
                const changed = name orelse "";

                // The variant may hold anything; only strings are ours.
                // A type mismatch on enter leaves the cursor in front of the
                // variant, exactly where skip expects it.
                rc = self.ops.message_enter_container(msg, 'v', "s");
                if (rc > 0) {
                    var value: ?[]const u8 = null;
                    const vrc = self.ops.message_read_string(msg, &value);
                    if (vrc < 0) return vrc;
                    if (vrc > 0) {
                        if (propertyFromName(changed)) |prop| {
                            if (self.replace(prop, value orelse "") catch return -enomem) {
                                self.dirty = true;
                            }
                        }
                    }
                    rc = self.ops.message_exit_container(msg);
                    if (rc < 0) return rc;
                } else {
                    rc = self.ops.message_skip(msg, "v");
                    if (rc < 0) return rc;
                }

                rc = self.ops.message_exit_container(msg);
                if (rc < 0) return rc;
            }
            rc = self.ops.message_exit_container(msg);
            if (rc < 0) return rc;
        }

        // as -- invalidated names carry no value; re-read them later.
        rc = self.ops.message_enter_container(msg, 'a', "s");
        if (rc < 0) return rc;
        if (rc > 0) {
            while (true) {
                var name: ?[]const u8 = null;
                rc = self.ops.message_read_string(msg, &name);
                if (rc < 0) return rc;
                if (rc == 0) break;
                if (propertyFromName(name orelse "")) |prop| {
                    self.invalidated[@intFromEnum(prop)] = true;
                }
            }
            rc = self.ops.message_exit_container(msg);
            if (rc < 0) return rc;
        }

        return 0;
    }
};

fn propertyFromName(name: []const u8) ?Property {
    inline for (property_names, 0..) |candidate, i| {
        if (std.mem.eql(u8, name, candidate)) return @enumFromInt(i);
    }
    return null;
}

/// C entry point handed to `sd_bus_add_match`.
fn propertiesChanged(
    msg: ?*Message,
    userdata: ?*anyopaque,
    ret_error: ?*anyopaque,
) callconv(.c) c_int {
    _ = ret_error;
    const m = msg orelse return 0;
    const state_ptr = userdata orelse return 0;
    const state: *CallbackState = @ptrCast(@alignCast(state_ptr));
    return state.handlePropertiesChanged(m);
}

// ---------------------------------------------------------------------------
// Locale1
// ---------------------------------------------------------------------------

pub const Locale1 = struct {
    allocator: std.mem.Allocator,
    ops: SdBusOps,
    bus: *Bus,
    /// Match slot; `deinit` unrefs it so the shared per-thread connection
    /// does not keep delivering after this reader is gone.
    slot: ?*Slot,
    /// Heap-allocated callback target; also holds the owned strings.
    state: *CallbackState,

    /// Open the default system bus, install the match, then read the four
    /// X11 properties. Property reads that fail (no localed) are tolerated
    /// and reported as unset. See the module header for the ordering
    /// rationale.
    pub fn init(allocator: std.mem.Allocator, ops: SdBusOps) !Locale1 {
        const state = try allocator.create(CallbackState);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .ops = ops };

        var bus: ?*Bus = null;
        const rc = ops.default_system(&bus);
        if (rc < 0) return error.BusUnavailable;
        const connection = bus orelse return error.BusUnavailable;
        errdefer ops.unref(connection);

        // Match first, initial read second: a change in between is queued by
        // sd-bus instead of being lost.
        var slot: ?*Slot = null;
        const match_rc = ops.add_match(connection, &slot, match_rule, propertiesChanged, state);
        if (match_rc < 0) return error.MatchFailed;

        const self: Locale1 = .{
            .allocator = allocator,
            .ops = ops,
            .bus = connection,
            .slot = slot,
            .state = state,
        };
        errdefer {
            if (self.slot) |owned| ops.slot_unref(owned);
            state.deinit();
        }
        try state.refreshAll(connection);
        // The initial snapshot is the baseline, not a change.
        state.dirty = false;
        return self;
    }

    /// One-shot startup read (kmscon parity, `libseat-sdlogin.md` §5.2):
    /// open the default system bus, read the four X11 properties, drop the
    /// bus reference. No match is installed, so this can run before (or
    /// without) the live follower and never leaves a subscription behind.
    ///
    /// A missing localed or a failed property read is not an error: the
    /// affected field is `""` and the caller falls back to its config. Only
    /// `sd_bus_default_system` and allocation failures are returned
    /// (`error.BusUnavailable`, `error.OutOfMemory`); the caller treats them
    /// as "no locale1" too.
    pub fn readCurrent(allocator: std.mem.Allocator, ops: SdBusOps) !CurrentKeymap {
        var bus: ?*Bus = null;
        const rc = ops.default_system(&bus);
        if (rc < 0) return error.BusUnavailable;
        const connection = bus orelse return error.BusUnavailable;
        defer ops.unref(connection);

        var state: CallbackState = .{ .allocator = allocator, .ops = ops };
        defer state.deinit();
        try state.refreshAll(connection);

        var result: CurrentKeymap = .{ .allocator = allocator };
        result.values = state.values;
        state.values = @splat(null); // ownership moved to the result
        return result;
    }

    /// Remove the match and drop the shared bus reference, then free all
    /// owned strings.
    pub fn deinit(self: *Locale1) void {
        if (self.slot) |slot| self.ops.slot_unref(slot);
        self.ops.unref(self.bus);
        self.state.deinit();
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    /// Current RMLVO values; borrowed until the next `process`/`deinit`.
    pub fn keymapOptions(self: *const Locale1) KeymapOptions {
        return .{
            .model = self.state.values[@intFromEnum(Property.model)] orelse "",
            .layout = self.state.values[@intFromEnum(Property.layout)] orelse "",
            .variant = self.state.values[@intFromEnum(Property.variant)] orelse "",
            .options = self.state.values[@intFromEnum(Property.options)] orelse "",
        };
    }

    /// Drain sd-bus (`sd_bus_process` until it returns 0), re-read any
    /// invalidated X11 property, and return the new options when one of the
    /// four values actually changed. `null` means "nothing we care about".
    ///
    /// Returns `error.OutOfMemory` when a changed value could not be copied,
    /// `error.BusProcessFailed` on any other sd-bus error.
    pub fn process(self: *Locale1) !?KeymapChange {
        while (true) {
            const rc = self.ops.process(self.bus, null);
            if (rc < 0) return processError(rc);
            if (rc == 0) break;
        }

        const state = self.state;
        for (0..property_count) |i| {
            if (!state.invalidated[i]) continue;
            state.invalidated[i] = false;
            try state.refresh(self.bus, @enumFromInt(i));
        }

        if (!state.dirty) return null;
        state.dirty = false;
        return .{ .options = self.keymapOptions() };
    }

    /// sd-bus's pollable fd. Register it with epoll after `init`; the value
    /// is stable for the lifetime of the connection.
    pub fn fd(self: *const Locale1) !c_int {
        const value = self.ops.get_fd(self.bus);
        if (value < 0) return error.BusFdUnavailable;
        return value;
    }

    /// Current `POLLIN`/`POLLOUT` interest mask. Re-read every loop
    /// iteration: the write queue may drain and change it.
    pub fn events(self: *const Locale1) !c_int {
        const value = self.ops.get_events(self.bus);
        if (value < 0) return error.BusEventsUnavailable;
        return value;
    }

    /// Microseconds left until sd-bus's next deadline; `null` = no deadline
    /// (use an infinite epoll timeout). `sd_bus_get_timeout` returns an
    /// absolute CLOCK_MONOTONIC deadline in microseconds, which this
    /// converts against `now_us` from the same clock.
    pub fn timeout(self: *const Locale1, now_us: u64) !?u64 {
        var deadline: u64 = 0;
        const rc = self.ops.get_timeout(self.bus, &deadline);
        if (rc < 0) return error.BusTimeoutUnavailable;
        if (rc == 0 or deadline == infinite_timeout) return null;
        return remainingUs(deadline, now_us);
    }

    /// Like `timeout`, in milliseconds rounded up for `epoll_wait`; `null`
    /// means -1. The caller clamps to `c_int` (epoll's timeout width).
    pub fn timeoutMs(self: *const Locale1, now_us: u64) !?u64 {
        const remaining = try self.timeout(now_us);
        return if (remaining) |us| (us +| 999) / 1000 else null;
    }
};

/// Remaining microseconds until an absolute monotonic deadline; a deadline
/// in the past becomes 0.
pub fn remainingUs(deadline_us: u64, now_us: u64) u64 {
    return if (deadline_us > now_us) deadline_us - now_us else 0;
}

fn processError(rc: c_int) anyerror {
    return switch (rc) {
        -enomem => error.OutOfMemory,
        else => error.BusProcessFailed,
    };
}

// ---------------------------------------------------------------------------
// Production ops (translate-c `sd-bus-c`)
// ---------------------------------------------------------------------------

/// Production implementation. Every function lazily imports the translate-c
/// output of `#include <systemd/sd-bus.h>` (module `sd-bus-c`); the hermetic
/// tests never reference this table, so they need no systemd module and no
/// `-lsystemd`.
pub const real: SdBusOps = .{
    .default_system = c_api.defaultSystem,
    .add_match = c_api.addMatch,
    .slot_unref = c_api.slotUnref,
    .unref = c_api.unref,
    .get_property_string = c_api.getPropertyString,
    .free_string = c_api.freeString,
    .get_fd = c_api.getFd,
    .get_events = c_api.getEvents,
    .get_timeout = c_api.getTimeout,
    .process = c_api.process,
    .message_read_string = c_api.messageReadString,
    .message_enter_container = c_api.messageEnterContainer,
    .message_exit_container = c_api.messageExitContainer,
    .message_skip = c_api.messageSkip,
};

const c_api = struct {
    fn defaultSystem(ret: *?*Bus) c_int {
        const c = @import("sd-bus-c");
        var bus: ?*c.sd_bus = null;
        const rc = c.sd_bus_default_system(&bus);
        if (rc >= 0) ret.* = if (bus) |b| @ptrCast(b) else null;
        return rc;
    }

    fn addMatch(
        bus: *Bus,
        ret_slot: ?*?*Slot,
        match: [*:0]const u8,
        callback: MatchCallback,
        userdata: ?*anyopaque,
    ) c_int {
        const c = @import("sd-bus-c");
        var slot: ?*c.sd_bus_slot = null;
        const callback_ptr: c.sd_bus_message_handler_t = @ptrCast(callback);
        const rc = c.sd_bus_add_match(
            @ptrCast(@alignCast(bus)),
            &slot,
            match,
            callback_ptr,
            userdata,
        );
        if (rc < 0) return rc;
        if (ret_slot) |out| out.* = if (slot) |s| @ptrCast(s) else null;
        return rc;
    }

    fn slotUnref(slot: *Slot) void {
        const c = @import("sd-bus-c");
        _ = c.sd_bus_slot_unref(@ptrCast(@alignCast(slot)));
    }

    fn unref(bus: *Bus) void {
        const c = @import("sd-bus-c");
        _ = c.sd_bus_unref(@ptrCast(@alignCast(bus)));
    }

    fn getPropertyString(
        bus: *Bus,
        destination: [*:0]const u8,
        path: [*:0]const u8,
        interface_name: [*:0]const u8,
        member: [*:0]const u8,
        ret: *?[*:0]u8,
    ) c_int {
        const c = @import("sd-bus-c");
        var value: ?[*:0]u8 = null;
        const rc = c.sd_bus_get_property_string(
            @ptrCast(@alignCast(bus)),
            destination,
            path,
            interface_name,
            member,
            null,
            @ptrCast(&value),
        );
        if (rc < 0) return rc;
        ret.* = value;
        return rc;
    }

    fn freeString(value: [*:0]u8) void {
        std.c.free(@ptrCast(value));
    }

    fn getFd(bus: *Bus) c_int {
        const c = @import("sd-bus-c");
        return c.sd_bus_get_fd(@ptrCast(@alignCast(bus)));
    }

    fn getEvents(bus: *Bus) c_int {
        const c = @import("sd-bus-c");
        return c.sd_bus_get_events(@ptrCast(@alignCast(bus)));
    }

    fn getTimeout(bus: *Bus, ret: *u64) c_int {
        const c = @import("sd-bus-c");
        return c.sd_bus_get_timeout(@ptrCast(@alignCast(bus)), ret);
    }

    fn process(bus: *Bus, ret: ?*?*Message) c_int {
        const c = @import("sd-bus-c");
        var msg: ?*c.sd_bus_message = null;
        const rc = c.sd_bus_process(@ptrCast(@alignCast(bus)), &msg);
        if (ret) |out| out.* = if (msg) |m| @ptrCast(m) else null;
        return rc;
    }

    fn messageReadString(msg: *Message, ret: *?[]const u8) c_int {
        const c = @import("sd-bus-c");
        var value: ?[*:0]const u8 = null;
        const rc = c.sd_bus_message_read_basic(
            @ptrCast(@alignCast(msg)),
            's',
            @ptrCast(&value),
        );
        if (rc > 0) ret.* = if (value) |v| std.mem.span(v) else "";
        return rc;
    }

    fn messageEnterContainer(msg: *Message, typ: u8, contents: ?[*:0]const u8) c_int {
        const c = @import("sd-bus-c");
        return c.sd_bus_message_enter_container(
            @ptrCast(@alignCast(msg)),
            typ,
            contents,
        );
    }

    fn messageExitContainer(msg: *Message) c_int {
        const c = @import("sd-bus-c");
        return c.sd_bus_message_exit_container(@ptrCast(@alignCast(msg)));
    }

    fn messageSkip(msg: *Message, types: [*:0]const u8) c_int {
        const c = @import("sd-bus-c");
        return c.sd_bus_message_skip(@ptrCast(@alignCast(msg)), types);
    }
};