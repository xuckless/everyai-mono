//! Bring your own key. The app keeps the user's provider keys in the device
//! keychain and sends the one chosen for a call to the **bundled local
//! server only** (owner, 2026-11-08): the hosted server refuses any
//! `X-Provider-Key-*` header (400 `keys_not_accepted`, see `Refuse`). The
//! server uses a key for that request only and never stores or logs it.
//! Calls on the user's key are recorded in usage_events but not charged.
//!
//! The providers are `providers.json` (shared with the app, which mirrors
//! it and fails a test on drift). A provider is `connected` once its whole
//! path (streaming, tool calls, usage) was checked live; a `saved` one keeps
//! its key but no call is routed to it.
const std = @import("std");
const anole = @import("anole");

pub const Auth = enum { bearer, anthropic };
pub const Status = enum { connected, saved };

pub const Covers = union(enum) {
    /// Every catalog model (OpenRouter).
    all,
    /// OpenRouter ids whose vendor prefix is one of these.
    vendors: []const []const u8,
    /// The host has its own model ids (needs its own catalog source).
    own_ids,
};

pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    header: []const u8,
    auth: Auth,
    base_url: []const u8,
    covers: Covers,
    /// OpenRouter id (without the vendor prefix) → the provider's id.
    id_map: []const [2][]const u8,
    status: Status,

    pub fn coversModel(self: Provider, model: []const u8) bool {
        return switch (self.covers) {
            .all => true,
            .own_ids => false,
            .vendors => |vs| for (vs) |v| {
                if (model.len > v.len and std.mem.startsWith(u8, model, v) and model[v.len] == '/') break true;
            } else false,
        };
    }

    /// The id this provider knows `model` by: the vendor prefix stripped,
    /// then `id_map`.
    pub fn modelId(self: Provider, model: []const u8) []const u8 {
        const bare = if (self.covers == .all) model else if (std.mem.indexOfScalar(u8, model, '/')) |i| model[i + 1 ..] else model;
        for (self.id_map) |m| if (std.mem.eql(u8, m[0], bare)) return m[1];
        return bare;
    }
};

pub const max_providers = 32;

/// The table, parsed once at start (`load`; `prepare` calls it).
var loaded: ?[]const Provider = null;
var storage: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// Tests: route to `saved` providers too, so the adapter can be exercised.
pub var allow_saved = false;

pub fn load() !void {
    if (loaded != null) return;
    loaded = try parse(storage.allocator(), @embedFile("providers.json"));
}

pub fn table() []const Provider {
    return loaded orelse @panic("byok.load() not called");
}

pub fn byId(id: []const u8) ?Provider {
    for (table()) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

fn parse(a: std.mem.Allocator, json: []const u8) ![]const Provider {
    const Raw = struct {
        providers: []const struct {
            id: []const u8,
            name: []const u8,
            header: []const u8,
            auth: []const u8,
            base_url: []const u8,
            covers: std.json.Value,
            id_map: std.json.Value,
            status: []const u8,
        },
    };
    const raw = try std.json.parseFromSliceLeaky(Raw, a, json, .{ .ignore_unknown_fields = true });
    if (raw.providers.len > max_providers) return error.TooManyProviders;
    const out = try a.alloc(Provider, raw.providers.len);
    for (raw.providers, out) |r, *p| {
        const covers: Covers = switch (r.covers) {
            .string => |s| if (std.mem.eql(u8, s, "all")) .all else if (std.mem.eql(u8, s, "own_ids")) .own_ids else return error.BadCovers,
            .array => |arr| blk: {
                const vs = try a.alloc([]const u8, arr.items.len);
                for (arr.items, vs) |v, *slot| slot.* = if (v == .string) v.string else return error.BadCovers;
                break :blk .{ .vendors = vs };
            },
            else => return error.BadCovers,
        };
        var map: std.ArrayList([2][]const u8) = .empty;
        if (r.id_map == .object) {
            var it = r.id_map.object.iterator();
            while (it.next()) |e| if (e.value_ptr.* == .string) try map.append(a, .{ e.key_ptr.*, e.value_ptr.string });
        }
        p.* = .{
            .id = r.id,
            .name = r.name,
            .header = r.header,
            .auth = std.meta.stringToEnum(Auth, r.auth) orelse return error.BadAuth,
            .base_url = r.base_url,
            .covers = covers,
            .id_map = map.items,
            .status = std.meta.stringToEnum(Status, r.status) orelse return error.BadStatus,
        };
    }
    return out;
}

/// The keys one request carries, one slot per table entry.
pub const Keys = struct {
    slots: [max_providers]?[]const u8 = @splat(null),

    pub fn of(req: *anole.Request) Keys {
        var k: Keys = .{};
        for (table(), 0..) |p, i| k.slots[i] = clean(req.headers.get(p.header));
        return k;
    }

    pub fn get(self: Keys, id: []const u8) ?[]const u8 {
        for (table(), 0..) |p, i| if (std.mem.eql(u8, p.id, id)) return self.slots[i];
        return null;
    }

    pub fn any(self: Keys) bool {
        for (self.slots) |s| if (s != null) return true;
        return false;
    }

    pub const Pick = struct { provider: Provider, key: []const u8 };

    /// Which key runs `model`: Anthropic natively for `anthropic/*`, then a
    /// connected direct provider covering its vendor, then OpenRouter.
    /// `native_ok` false means the call needs OpenRouter (the web plugin).
    pub fn pick(self: Keys, model: []const u8, native_ok: bool) ?Pick {
        if (native_ok) {
            for (table(), 0..) |p, i| {
                const key = self.slots[i] orelse continue;
                if (p.covers == .all or !p.coversModel(model)) continue;
                if (p.status == .saved and !allow_saved) continue;
                return .{ .provider = p, .key = key };
            }
        }
        for (table(), 0..) |p, i| if (p.covers == .all) if (self.slots[i]) |key| return .{ .provider = p, .key = key };
        return null;
    }

    /// Whether `model` runs on one of these keys (so it is never charged).
    pub fn covers(self: Keys, model: []const u8, native_ok: bool) bool {
        return self.pick(model, native_ok) != null;
    }
};

pub fn isAnthropic(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "anthropic/");
}

/// A key worth trying: trimmed, non-empty, printable ASCII without spaces
/// (it goes into an upstream header as is).
fn clean(raw: ?[]const u8) ?[]const u8 {
    const k = std.mem.trim(u8, raw orelse return null, " \t");
    if (k.len < 8 or k.len > 512) return null;
    for (k) |c| if (c <= ' ' or c >= 0x7f) return null;
    return k;
}

/// The hosted server never takes a user's provider key: those go to the
/// app's bundled local server only. Any `X-Provider-Key-*` header is a 400
/// `keys_not_accepted`, before a handler sees it.
pub const Refuse = struct {
    pub const no_wait = true;

    pub fn execute(_: *const Refuse, req: *anole.Request, res: *anole.Response, next: anytype) !void {
        if (carriesKey(req)) {
            res.status = .bad_request;
            return res.json(.{
                .message = "Provider keys go to the EveryAI app's local server, never to this one. Update the app.",
                .code = "keys_not_accepted",
            });
        }
        return next.call();
    }
};

fn carriesKey(req: *anole.Request) bool {
    for (table()) |p| if (req.headers.get(p.header) != null) return true;
    // Any other spelling of the prefix too (a provider the table doesn't know yet).
    var it = req.headers.iterator();
    while (it.next()) |h| if (std.ascii.startsWithIgnoreCase(h.key, "X-Provider-Key-")) return true;
    return false;
}

test "the table parses; every provider not yet checked live is saved only" {
    try load();
    try std.testing.expect(table().len >= 20);
    try std.testing.expectEqual(Status.connected, byId("openrouter").?.status);
    try std.testing.expectEqual(Status.connected, byId("anthropic").?.status);
    for (table()) |p| {
        if (!std.mem.eql(u8, p.id, "openrouter") and !std.mem.eql(u8, p.id, "anthropic"))
            try std.testing.expectEqual(Status.saved, p.status);
        try std.testing.expect(std.mem.startsWith(u8, p.header, "X-Provider-Key-"));
        try std.testing.expect(std.mem.startsWith(u8, p.base_url, "https://"));
    }
}

test "keys pick the most direct connected provider, then OpenRouter" {
    try load();
    var k: Keys = .{};
    for (table(), 0..) |p, i| {
        if (std.mem.eql(u8, p.id, "anthropic")) k.slots[i] = "sk-ant-abc";
        if (std.mem.eql(u8, p.id, "openai")) k.slots[i] = "sk-openai-abc";
    }
    try std.testing.expectEqualStrings("anthropic", k.pick("anthropic/claude-haiku-5.5", true).?.provider.id);
    try std.testing.expect(k.pick("anthropic/claude-haiku-5.5", false) == null);
    // OpenAI is saved only: nothing routes to it.
    try std.testing.expect(k.pick("openai/gpt-6.1-sol", true) == null);
    allow_saved = true;
    defer allow_saved = false;
    const o = k.pick("openai/gpt-6.1-sol", true).?;
    try std.testing.expectEqualStrings("openai", o.provider.id);
    try std.testing.expectEqualStrings("gpt-6.1-sol", o.provider.modelId("openai/gpt-6.1-sol"));
    for (table(), 0..) |p, i| if (p.covers == .all) {
        k.slots[i] = "sk-or-v1-abc";
    };
    try std.testing.expectEqualStrings("openrouter", k.pick("qwen/qwen3", true).?.provider.id);
    try std.testing.expectEqualStrings("openrouter", k.pick("anthropic/claude-haiku-5.5", false).?.provider.id);
    try std.testing.expect(!(Keys{}).covers("anthropic/claude-haiku-5.5", true));
}

test "malformed keys are ignored" {
    try std.testing.expect(clean("  sk-or-v1-abcdef  ") != null);
    try std.testing.expect(clean("short") == null);
    try std.testing.expect(clean("sk-or v1 abcdef") == null);
    try std.testing.expect(clean("sk-or-v1-abc\r\nX-Evil: 1") == null);
    try std.testing.expect(clean(null) == null);
}
