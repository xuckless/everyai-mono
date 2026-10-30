//! OpenAI-compatible `POST /v1/chat/completions` for OpenHands and other
//! agent harnesses: authenticated by a gateway key (`sk-eai-...`), forwarded
//! to OpenRouter, metered per user/key/session (`X-EveryAI-Session`).
//! Anthropic/Gemini requests get prompt-cache breakpoints when the caller
//! sent none: system prompt, tools, and the latest message.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const billing = @import("billing.zig");
const chat = @import("chat.zig");
const openrouter = @import("openrouter.zig");
const sse = @import("net/sse_client.zig");

fn completions(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const who = try auth.identity(req);
    const raw = (try req.body()) orelse return res.fail(.bad_request, "missing body");
    var root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, raw, .{}) catch return res.fail(.bad_request, "body must be JSON");
    if (root != .object) return res.fail(.bad_request, "body must be a JSON object");
    const o = &root.object;

    // LiteLLM-style prefixes ("openai/anthropic/claude-...") are stripped to the OpenRouter id.
    var model = openrouter.jsonStr(o.get("model")) orelse return res.fail(.bad_request, "model is required");
    for ([_][]const u8{ "openai/", "openrouter/", "litellm_proxy/" }) |p| {
        if (std.mem.startsWith(u8, model, p) and std.mem.indexOfScalar(u8, model[p.len..], '/') != null) model = model[p.len..];
    }
    try o.put(req.arena, "model", .{ .string = model });

    app.catalog.ensureFresh(app.upstream, req.io, app.cfg.markup);
    const facts = app.catalog.facts(req.io, model);
    billing.preflight(app, req, who.user_id, facts.free) catch {
        res.status = .payment_required;
        return res.json(.{ .@"error" = .{ .message = "Out of EveryAI credits", .type = "insufficient_quota", .code = "out_of_credits" } });
    };

    // Metering needs the usage block.
    try o.put(req.arena, "usage", try jsonObject(req.arena, &.{.{ "include", .{ .bool = true } }}));
    if (chat.wantsBreakpoints(model) and !std.mem.containsAtLeast(u8, raw, 1, "cache_control")) {
        try addBreakpoints(req.arena, o, app.cfg.gateway_cache_ttl);
    }
    const streaming = if (o.get("stream")) |s| s == .bool and s.bool else false;
    const body = try std.json.Stringify.valueAlloc(req.arena, root, .{});
    const session = req.headers.get("X-EveryAI-Session");

    const up = try app.upstream.post(req, "/chat/completions", body, &.{});
    defer up.close();

    if (!streaming or up.status >= 300) {
        const reply = try up.reader.allocRemaining(req.arena, .limited(64 * 1024 * 1024));
        if (up.status < 300) {
            if (std.json.parseFromSliceLeaky(std.json.Value, req.arena, reply, .{})) |v| {
                if (v == .object) if (v.object.get("usage")) |u| if (u == .object) try meter(app, req, who, session, model, openrouter.parseUsage(u.object));
            } else |_| {}
        }
        res.status = @enumFromInt(up.status);
        res.content_type = .json;
        res.body = reply;
        return;
    }

    // Stream through event by event, watching for the usage chunk.
    var buf: [16 * 1024]u8 = undefined;
    try res.header("Content-Type", "text/event-stream");
    try res.header("Cache-Control", "no-cache");
    var out = try res.stream(&buf);
    var parser = sse.Parser.init(req.arena, up.reader);
    defer parser.deinit();
    var scratch: std.heap.ArenaAllocator = .init(req.arena);
    defer scratch.deinit();
    var usage: ?openrouter.Usage = null;
    while (try parser.next()) |ev| {
        try out.interface.writeAll("data: ");
        try out.interface.writeAll(ev.data);
        try out.interface.writeAll("\n\n");
        try out.interface.flush();
        if (std.mem.eql(u8, ev.data, "[DONE]")) break;
        if (std.mem.indexOf(u8, ev.data, "\"usage\"") == null) continue;
        _ = scratch.reset(.retain_capacity);
        const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), ev.data, .{}) catch continue;
        if (v == .object) if (v.object.get("usage")) |u| if (u == .object) {
            usage = openrouter.parseUsage(u.object);
        };
    }
    try out.end();
    if (usage) |u| try meter(app, req, who, session, model, u);
}

fn meter(app: *App, req: *anole.Request, who: auth.Identity, session: ?[]const u8, model: []const u8, u: openrouter.Usage) !void {
    _ = try billing.charge(app, req, who.user_id, .{
        .kind = "gateway",
        .model = model,
        .prompt_tokens = u.prompt_tokens,
        .completion_tokens = u.completion_tokens,
        .cached_tokens = u.cached_tokens,
        .cache_write_tokens = u.cache_write_tokens,
        .cost_usd = u.cost_usd,
        .session = session,
        .api_key_id = who.key_id,
    });
}

fn jsonObject(arena: std.mem.Allocator, fields: []const struct { []const u8, std.json.Value }) !std.json.Value {
    var m: std.json.ObjectMap = .empty;
    for (fields) |f| try m.put(arena, f[0], f[1]);
    return .{ .object = m };
}

fn cacheControl(arena: std.mem.Allocator, ttl: []const u8) !std.json.Value {
    if (std.mem.eql(u8, ttl, "1h")) return jsonObject(arena, &.{ .{ "type", .{ .string = "ephemeral" } }, .{ "ttl", .{ .string = "1h" } } });
    return jsonObject(arena, &.{.{ "type", .{ .string = "ephemeral" } }});
}

/// Breakpoints on: the last tool definition (tools + system prefix), the
/// system message, and the last message.
pub fn addBreakpoints(arena: std.mem.Allocator, o: *std.json.ObjectMap, ttl: []const u8) !void {
    if (o.get("tools")) |t| if (t == .array and t.array.items.len > 0) {
        const last = &t.array.items[t.array.items.len - 1];
        if (last.* == .object) try last.object.put(arena, "cache_control", try cacheControl(arena, ttl));
    };
    const msgs = (o.get("messages") orelse return);
    if (msgs != .array or msgs.array.items.len == 0) return;
    const items = msgs.array.items;
    for (items) |*m| {
        if (m.* == .object and std.mem.eql(u8, openrouter.jsonStr(m.object.get("role")) orelse "", "system")) {
            try markLastPart(arena, m, ttl);
            break;
        }
    }
    try markLastPart(arena, &items[items.len - 1], ttl);
}

/// Turns string content into a one-part array and marks its last text part.
fn markLastPart(arena: std.mem.Allocator, msg: *std.json.Value, ttl: []const u8) !void {
    if (msg.* != .object) return;
    const content = msg.object.getPtr("content") orelse return;
    switch (content.*) {
        .string => |s| {
            if (s.len == 0) return;
            var parts: std.json.Array = .init(arena);
            try parts.append(try jsonObject(arena, &.{ .{ "type", .{ .string = "text" } }, .{ "text", .{ .string = s } }, .{ "cache_control", try cacheControl(arena, ttl) } }));
            content.* = .{ .array = parts };
        },
        .array => |*parts| {
            var i = parts.items.len;
            while (i > 0) {
                i -= 1;
                const p = &parts.items[i];
                if (p.* == .object and std.mem.eql(u8, openrouter.jsonStr(p.object.get("type")) orelse "", "text")) {
                    try p.object.put(arena, "cache_control", try cacheControl(arena, ttl));
                    return;
                }
            }
        },
        else => {},
    }
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    app.group("/v1", .{auth.Authenticate{ .app = state, .keys = true }}).post("/chat/completions", completions);
}

test addBreakpoints {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"model":"anthropic/claude-sonnet-5.5","tools":[{"type":"function","function":{"name":"x"}}],
        \\ "messages":[{"role":"system","content":"sys"},{"role":"user","content":"hi"},{"role":"assistant","content":"yo"},{"role":"user","content":[{"type":"text","text":"more"}]}]}
    , .{});
    try addBreakpoints(a, &v.object, "1h");
    const out = try std.json.Stringify.valueAlloc(a, v, .{});
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "cache_control"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\"ttl\":\"1h\""));
}
