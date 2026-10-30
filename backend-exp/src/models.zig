//! The model shop: OpenRouter's catalog, refreshed hourly, with prices shown
//! marked up. The response is OpenAI-list shaped (`object: list`, `data[].id`)
//! so OpenAI-compatible clients (OpenHands) can read it too.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const util = @import("util.zig");
const openrouter = @import("openrouter.zig");

/// Added to "My models" on first run (the app seeds its local list from these).
pub const defaults = [_][]const u8{
    "anthropic/claude-haiku-5.5",
    "anthropic/claude-sonnet-5.5",
    "anthropic/claude-opus-5.5",
    "openai/gpt-6.1-sol",
    "openai/gpt-6.1-terra",
    "openai/gpt-5.4-mini",
    "xingchen-agi/xing4.0-29b-a4b:free",
    "dots-studio/dots-3-note-preview:free",
};

pub const Model = struct {
    id: []const u8,
    object: []const u8 = "model",
    owned_by: []const u8,
    name: []const u8,
    provider: []const u8,
    blurb: []const u8,
    context_length: i64,
    input_modalities: []const []const u8,
    output_modalities: []const []const u8,
    /// USD per million tokens, markup included.
    prompt_per_mtok: f64,
    completion_per_mtok: f64,
    free: bool,
    tools: bool,
    reasoning: bool,
    web_search: bool,
    default: bool,
    created: i64,
};

const ttl_seconds = 3600;

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    arena: ?*std.heap.ArenaAllocator = null,
    models: []const Model = &.{},
    /// The serialized `/v1/models` body.
    json: []const u8 = "{\"object\":\"list\",\"data\":[]}",
    fetched_at: i64 = 0,

    pub fn init(gpa: std.mem.Allocator) Catalog {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Catalog) void {
        if (self.arena) |a| {
            a.deinit();
            self.gpa.destroy(a);
        }
    }

    /// Refetches when older than an hour. A failed fetch keeps the old list.
    pub fn ensureFresh(self: *Catalog, up: openrouter.Upstream, io: std.Io, markup: f64) void {
        if (util.now(io) - self.fetched_at < ttl_seconds) return;
        self.refresh(up, io, markup) catch |err| std.log.warn("model catalog refresh failed: {t}", .{err});
    }

    pub fn refresh(self: *Catalog, up: openrouter.Upstream, io: std.Io, markup: f64) !void {
        const arena = try self.gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(self.gpa);
        errdefer {
            arena.deinit();
            self.gpa.destroy(arena);
        }
        const a = arena.allocator();
        const raw = try up.get(io, a, "/models");
        const models = try parse(a, raw, markup);
        const json = try std.json.Stringify.valueAlloc(a, .{ .object = "list", .data = models }, .{});

        self.mutex.lockUncancelable(io);
        const old = self.arena;
        self.arena = arena;
        self.models = models;
        self.json = json;
        self.fetched_at = util.now(io);
        self.mutex.unlock(io);
        // Requests copy what they read under the lock, so the old arena is free.
        if (old) |o| {
            o.deinit();
            self.gpa.destroy(o);
        }
    }

    pub fn jsonCopy(self: *Catalog, io: std.Io, arena: std.mem.Allocator) ![]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return arena.dupe(u8, self.json);
    }

    pub const Facts = struct { known: bool, free: bool, tools: bool, web_search: bool };

    pub fn facts(self: *Catalog, io: std.Io, id: []const u8) Facts {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.models) |m| if (std.mem.eql(u8, m.id, id)) return .{ .known = true, .free = m.free, .tools = m.tools, .web_search = m.web_search };
        // Unknown (catalog not loaded): treat as paid, assume tools.
        return .{ .known = false, .free = std.mem.endsWith(u8, id, ":free"), .tools = true, .web_search = true };
    }
};

fn parse(a: std.mem.Allocator, raw: []const u8, markup: f64) ![]const Model {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{});
    const data = (root.object.get("data") orelse return error.BadCatalog).array.items;
    var out: std.ArrayList(Model) = .empty;
    for (data) |item| {
        const o = item.object;
        const id = openrouter.jsonStr(o.get("id")) orelse continue;
        // Batch variants are not for interactive use.
        if (std.mem.endsWith(u8, id, ":batch")) continue;
        const pricing = if (o.get("pricing")) |p| p.object else continue;
        const prompt = priceOf(pricing.get("prompt"));
        const completion = priceOf(pricing.get("completion"));
        const arch = if (o.get("architecture")) |x| x.object else null;
        const params = if (o.get("supported_parameters")) |p| p.array.items else &.{};
        const slash = std.mem.indexOfScalar(u8, id, '/') orelse 0;
        // "~openai/gpt-latest" is an alias that follows a vendor's newest model.
        const vendor = std.mem.trimStart(u8, id[0..slash], "~");
        var name = openrouter.jsonStr(o.get("name")) orelse id;
        // "Anthropic: Claude Haiku 5.5" -> "Claude Haiku 5.5"
        if (std.mem.indexOf(u8, name, ": ")) |i| name = name[i + 2 ..];
        try out.append(a, .{
            .id = id,
            .owned_by = vendor,
            .name = name,
            .provider = vendor,
            .blurb = try blurbOf(a, openrouter.jsonStr(o.get("description")) orelse ""),
            .context_length = openrouter.jsonInt(o.get("context_length")),
            .input_modalities = try strings(a, if (arch) |x| x.get("input_modalities") else null),
            .output_modalities = try strings(a, if (arch) |x| x.get("output_modalities") else null),
            .prompt_per_mtok = prompt * 1_000_000 * markup,
            .completion_per_mtok = completion * 1_000_000 * markup,
            .free = prompt == 0 and completion == 0,
            .tools = contains(params, "tools"),
            .reasoning = contains(params, "reasoning") or contains(params, "include_reasoning"),
            .web_search = pricing.get("web_search") != null,
            .default = isDefault(id),
            .created = openrouter.jsonInt(o.get("created")),
        });
    }
    return out.items;
}

fn priceOf(v: ?std.json.Value) f64 {
    const x = v orelse return 0;
    return switch (x) {
        .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => openrouter.jsonFloat(x),
    };
}

fn strings(a: std.mem.Allocator, v: ?std.json.Value) ![]const []const u8 {
    const x = v orelse return &.{};
    if (x != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (x.array.items) |s| if (s == .string) try out.append(a, s.string);
    return out.items;
}

fn contains(items: []const std.json.Value, name: []const u8) bool {
    for (items) |i| if (i == .string and std.mem.eql(u8, i.string, name)) return true;
    return false;
}

fn isDefault(id: []const u8) bool {
    for (defaults) |d| if (std.mem.eql(u8, d, id)) return true;
    return false;
}

/// The description's first sentence; past 160 characters, cut at a word with "…".
fn blurbOf(a: std.mem.Allocator, desc: []const u8) ![]const u8 {
    const sentence = if (std.mem.indexOf(u8, desc, ". ")) |i| desc[0 .. i + 1] else desc;
    if (sentence.len <= 160) return sentence;
    const cut = std.mem.lastIndexOfScalar(u8, sentence[0..160], ' ') orelse 160;
    return std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, sentence[0..cut], " ,;:"), "…" });
}

// ------------------------------------------------------------------ routes

fn list(app: *App, req: *anole.Request, res: *anole.Response) !void {
    app.catalog.ensureFresh(app.upstream, req.io, app.cfg.markup);
    res.content_type = .json;
    res.body = try app.catalog.jsonCopy(req.io, req.arena);
}

fn defaultList(_: *App, _: *anole.Request) struct { models: []const []const u8 } {
    return .{ .models = &defaults };
}

pub fn routes(app: *anole.Server(App), _: *App) void {
    app.get("/v1/models", list);
    app.get("/v1/models/defaults", defaultList);
}
