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
const truncation = @import("truncation.zig");

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
    try applyEffort(req.arena, o, req.headers.get("X-EveryAI-Effort"));
    const streaming = if (o.get("stream")) |s| s == .bool and s.bool else false;
    const body = try std.json.Stringify.valueAlloc(req.arena, root, .{});
    const session = req.headers.get("X-EveryAI-Session");

    const route = app.route(model, true);
    const up = try route.up.post(req, "/chat/completions", body, &.{});
    var call: Call = .{ .app = app, .req = req, .who = who, .session = session, .model = model, .route = route, .o = o, .max_output = facts.max_output };

    if (up.status >= 300) {
        defer up.close();
        const reply = try up.reader.allocRemaining(req.arena, .limited(64 * 1024 * 1024));
        res.status = @fromBackingInt(@intCast(up.status));
        res.content_type = .json;
        res.body = reply;
        return;
    }
    if (!streaming) {
        res.status = .ok;
        res.content_type = .json;
        res.body = try call.whole(up);
        return;
    }
    var buf: [16 * 1024]u8 = undefined;
    try res.header("Content-Type", "text/event-stream");
    try res.header("Cache-Control", "no-cache");
    var out = try res.stream(&buf);
    try call.streamed(up, &out.interface);
    try out.end();
}

/// One gateway request and its recovery from cut-off replies (see
/// truncation.zig): a cut-off tool call is asked for again once with a bigger
/// output cap, cut-off text is continued with a nudge, and a call still cut
/// off is made unparseable so the harness reports it instead of running it.
const Call = struct {
    app: *App,
    req: *anole.Request,
    who: auth.Identity,
    session: ?[]const u8,
    model: []const u8,
    route: App.Route,
    /// The request body; the output cap is raised in place.
    o: *std.json.ObjectMap,
    max_output: i64,
    boosted: bool = false,
    continuations: u8 = 0,
    /// Text of the replies continued so far.
    text: std.ArrayList(u8) = .empty,

    const Next = enum { done, boost, continue_text };

    /// What to do after a reply that finished with `finish` (`used` output tokens).
    fn next(self: *Call, finish: []const u8, has_tools: bool, text: []const u8, used: i64) !Next {
        if (!truncation.isLength(finish)) return .done;
        const arena = self.req.arena;
        if (has_tools) {
            if (self.boosted) return .done;
            const cap = truncation.boostedCap(capOf(self.o.*, used), self.max_output) orelse return .done;
            self.boosted = true;
            try self.o.put(arena, "max_tokens", .{ .integer = cap });
            if (self.o.get("max_completion_tokens") != null) try self.o.put(arena, "max_completion_tokens", .{ .integer = cap });
            return .boost;
        }
        if (text.len == 0 or self.continuations >= truncation.max_continuations) return .done;
        self.continuations += 1;
        return .continue_text;
    }

    /// The body for the next attempt: the request, plus the text so far and
    /// a nudge when continuing.
    fn body(self: *Call) ![]const u8 {
        const arena = self.req.arena;
        if (self.text.items.len == 0) return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = self.o.* }, .{});
        var o = try self.o.clone(arena);
        var msgs: std.json.Array = .init(arena);
        if (o.get("messages")) |m| if (m == .array) try msgs.appendSlice(m.array.items);
        try msgs.append(try jsonObject(arena, &.{ .{ "role", .{ .string = "assistant" } }, .{ "content", .{ .string = self.text.items } } }));
        try msgs.append(try jsonObject(arena, &.{ .{ "role", .{ .string = "user" } }, .{ "content", .{ .string = truncation.continue_nudge } } }));
        try o.put(arena, "messages", .{ .array = msgs });
        return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = o }, .{});
    }

    /// The next attempt, or null when it failed (the caller keeps the last
    /// reply). `text` is the reply being continued.
    fn retry(self: *Call, step: Next, text: []const u8) !?openrouter.Stream {
        const kept = self.text.items.len;
        if (step == .continue_text) try self.text.appendSlice(self.req.arena, text);
        const up = self.route.up.post(self.req, "/chat/completions", try self.body(), &.{}) catch |err| {
            std.log.warn("gateway retry failed: {t}", .{err});
            self.text.shrinkRetainingCapacity(kept);
            return null;
        };
        if (up.status < 300) return up;
        std.log.warn("gateway retry failed: HTTP {d}", .{up.status});
        up.close();
        self.text.shrinkRetainingCapacity(kept);
        return null;
    }

    fn meter(self: *Call, u: openrouter.Usage) !void {
        try meterUsage(self.app, self.req, self.who, self.session, self.model, self.route.provider, u);
    }

    /// Non-streamed: the final reply's JSON.
    fn whole(self: *Call, first: openrouter.Stream) ![]const u8 {
        const arena = self.req.arena;
        var up = first;
        while (true) {
            const reply = blk: {
                defer up.close();
                break :blk try up.reader.allocRemaining(arena, .limited(64 * 1024 * 1024));
            };
            var v = std.json.parseFromSliceLeaky(std.json.Value, arena, reply, .{}) catch return reply;
            if (v != .object) return reply;
            var used: i64 = 0;
            if (v.object.get("usage")) |u| if (u == .object) {
                const usage = openrouter.parseUsage(u.object);
                used = usage.completion_tokens;
                try self.meter(usage);
            };
            const choice = firstChoice(v) orelse return reply;
            const msg = choice.getPtr("message") orelse return reply;
            if (msg.* != .object) return reply;
            const finish = openrouter.jsonStr(choice.get("finish_reason")) orelse "";
            const calls = if (msg.object.get("tool_calls")) |t| (if (t == .array) t.array.items else &.{}) else &.{};
            const text = openrouter.jsonStr(msg.object.get("content")) orelse "";

            const step = try self.next(finish, calls.len > 0, text, used);
            if (step != .done) if (try self.retry(step, text)) |again| {
                up = again;
                continue;
            };
            // Final: the text before it, and a cut-off call made unparseable.
            if (self.text.items.len > 0) try msg.object.put(arena, "content", .{ .string = try std.mem.concat(arena, u8, &.{ self.text.items, text }) });
            if (truncation.isLength(finish) and calls.len > 0) try markCut(arena, @constCast(&calls[calls.len - 1]));
            if (self.text.items.len == 0 and !(truncation.isLength(finish) and calls.len > 0)) return reply;
            return std.json.Stringify.valueAlloc(arena, v, .{});
        }
    }

    /// Streamed: text goes through as it arrives; tool calls, the finish
    /// chunk and usage are held until the reply is known not to need a retry.
    fn streamed(self: *Call, first: openrouter.Stream, out: *std.Io.Writer) !void {
        const arena = self.req.arena;
        var up = first;
        var forward_text = true;
        while (true) {
            var held: Held = .{};
            const current = up;
            defer current.close();
            try held.read(arena, self.req.io, up.reader, out, forward_text, keepalive_every);
            if (held.usage) |u| try self.meter(u);

            const step = try self.next(held.finish, held.tools, held.text.items, if (held.usage) |u| u.completion_tokens else 0);
            if (step != .done) if (try self.retry(step, held.text.items)) |again| {
                // Text held in finish chunks still goes to the client.
                if (forward_text) for (held.chunks.items) |c| if (c.text.len > 0) try writeData(out, try held.textChunk(arena, c.text));
                up = again;
                // A retried call repeats text the client already has.
                forward_text = step == .continue_text;
                continue;
            };
            for (held.chunks.items, 0..) |c, i| {
                if (held.finish_at == i and truncation.isLength(held.finish) and held.tools)
                    try writeData(out, try held.markChunk(arena));
                try writeData(out, c.raw);
            }
            try writeData(out, "[DONE]");
            return;
        }
    }
};

/// How long a stream may go without sending anything while chunks are held
/// back (a long tool call): idle clients and proxies time out well before
/// a big file is generated.
const keepalive_every: std.Io.Duration = .fromSeconds(15);

/// One streamed attempt's held-back chunks.
const Held = struct {
    chunks: std.ArrayList(struct { raw: []const u8, text: []const u8 }) = .empty,
    finish_at: ?usize = null,
    finish: []const u8 = "",
    tools: bool = false,
    last_tool: i64 = 0,
    text: std.ArrayList(u8) = .empty,
    usage: ?openrouter.Usage = null,
    id: []const u8 = "",
    model: []const u8 = "",

    /// Reads one attempt, forwarding text when `forward_text` and holding
    /// the rest. While holding, an SSE comment goes out every `beat_every`.
    fn read(self: *Held, arena: std.mem.Allocator, io: std.Io, reader: *std.Io.Reader, out: *std.Io.Writer, forward_text: bool, beat_every: std.Io.Duration) !void {
        const Ts = std.Io.Clock.Timestamp;
        var last_sent = Ts.now(io, .awake);
        var parser = sse.Parser.init(arena, reader);
        defer parser.deinit();
        var scratch: std.heap.ArenaAllocator = .init(arena);
        defer scratch.deinit();
        while (try parser.next()) |ev| {
            if (std.mem.eql(u8, ev.data, "[DONE]")) break;
            _ = scratch.reset(.retain_capacity);
            const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), ev.data, .{}) catch {
                try writeData(out, ev.data);
                continue;
            };
            if (v != .object or v.object.get("error") != null) {
                try writeData(out, ev.data);
                continue;
            }
            if (self.id.len == 0) if (openrouter.jsonStr(v.object.get("id"))) |id| {
                self.id = try arena.dupe(u8, id);
            };
            if (self.model.len == 0) if (openrouter.jsonStr(v.object.get("model"))) |m| {
                self.model = try arena.dupe(u8, m);
            };
            var hold = false;
            if (v.object.get("usage")) |u| if (u == .object) {
                self.usage = openrouter.parseUsage(u.object);
                hold = true;
            };
            var text: []const u8 = "";
            if (firstChoice(v)) |choice| {
                if (openrouter.jsonStr(choice.get("finish_reason"))) |f| {
                    self.finish = try arena.dupe(u8, f);
                    self.finish_at = self.chunks.items.len;
                    hold = true;
                }
                if (choice.get("delta")) |d| if (d == .object) {
                    text = openrouter.jsonStr(d.object.get("content")) orelse "";
                    if (d.object.get("tool_calls")) |tc| if (tc == .array and tc.array.items.len > 0) {
                        self.tools = true;
                        hold = true;
                        for (tc.array.items) |c| if (c == .object) {
                            self.last_tool = @max(self.last_tool, openrouter.jsonInt(c.object.get("index")));
                        };
                    };
                };
            } else hold = true;
            try self.text.appendSlice(arena, text);
            if (hold) {
                try self.chunks.append(arena, .{ .raw = try arena.dupe(u8, ev.data), .text = try arena.dupe(u8, text) });
                const now = Ts.now(io, .awake);
                if (now.compare(.gte, last_sent.addDuration(.{ .raw = beat_every, .clock = .awake }))) {
                    try out.writeAll(": keepalive\n\n");
                    try out.flush();
                    last_sent = now;
                }
            } else if (forward_text) {
                try writeData(out, ev.data);
                last_sent = Ts.now(io, .awake);
            }
        }
    }

    fn textChunk(self: *const Held, arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        return chunkJson(arena, self.id, self.model, .{ .content = text });
    }

    /// Appends `cut_marker` to the last tool call's arguments.
    fn markChunk(self: *const Held, arena: std.mem.Allocator) ![]const u8 {
        return chunkJson(arena, self.id, self.model, .{ .tool_calls = .{.{ .index = self.last_tool, .function = .{ .arguments = truncation.cut_marker } }} });
    }
};

fn chunkJson(arena: std.mem.Allocator, id: []const u8, model: []const u8, delta: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .id = id,
        .object = "chat.completion.chunk",
        .model = model,
        .choices = .{.{ .index = 0, .delta = delta, .finish_reason = @as(?[]const u8, null) }},
    }, .{});
}

fn writeData(out: *std.Io.Writer, data: []const u8) !void {
    try out.writeAll("data: ");
    try out.writeAll(data);
    try out.writeAll("\n\n");
    try out.flush();
}

fn firstChoice(v: std.json.Value) ?*std.json.ObjectMap {
    if (v != .object) return null;
    const choices = v.object.getPtr("choices") orelse return null;
    if (choices.* != .array or choices.array.items.len == 0) return null;
    const c = &choices.array.items[0];
    return if (c.* == .object) &c.object else null;
}

/// The cap the request set, else the output the cut-off reply used.
fn capOf(o: std.json.ObjectMap, used: i64) i64 {
    const a = openrouter.jsonInt(o.get("max_completion_tokens"));
    if (a > 0) return a;
    const b = openrouter.jsonInt(o.get("max_tokens"));
    return if (b > 0) b else used;
}

/// Makes a tool call's arguments unparseable (see `truncation.cut_marker`).
fn markCut(arena: std.mem.Allocator, call: *std.json.Value) !void {
    if (call.* != .object) return;
    const f = call.object.getPtr("function") orelse return;
    if (f.* != .object) return;
    const args = openrouter.jsonStr(f.object.get("arguments")) orelse "";
    try f.object.put(arena, "arguments", .{ .string = try std.mem.concat(arena, u8, &.{ args, truncation.cut_marker }) });
}

fn meterUsage(app: *App, req: *anole.Request, who: auth.Identity, session: ?[]const u8, model: []const u8, provider: []const u8, u: openrouter.Usage) !void {
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
        .provider = provider,
    });
}

/// LiteLLM drops `reasoning_effort` for models it doesn't know, so the app
/// sends the effort as `X-EveryAI-Effort`. It becomes OpenRouter's
/// `reasoning.effort` (the Anthropic adapter reads it too) unless the body
/// already sets one.
pub fn applyEffort(arena: std.mem.Allocator, o: *std.json.ObjectMap, header: ?[]const u8) !void {
    const effort = header orelse return;
    if (o.get("reasoning_effort") != null or o.get("reasoning") != null) return;
    for ([_][]const u8{ "low", "medium", "high", "xhigh", "max" }) |ok| {
        if (std.mem.eql(u8, effort, ok)) {
            try o.put(arena, "reasoning", try jsonObject(arena, &.{.{ "effort", .{ .string = ok } }}));
            return;
        }
    }
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

test "held tool-call chunks keep the stream alive with comments, then go out whole" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const up =
        \\data: {"id":"r","model":"m","choices":[{"index":0,"delta":{"content":"hi"}}]}
        \\
        \\data: {"id":"r","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"a"}}]}}]}
        \\
        \\data: {"id":"r","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\":1}"}}]}}]}
        \\
        \\data: [DONE]
        \\
        \\
    ;
    var reader: std.Io.Reader = .fixed(up);
    var out: std.Io.Writer.Allocating = .init(a);
    var held: Held = .{};
    try held.read(a, std.testing.io, &reader, &out.writer, true, .fromMilliseconds(0));
    const sent = out.written();
    // The text went through; the tool call is held, with a keepalive per held chunk.
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"content\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "tool_calls") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, sent, ": keepalive\n\n"));
    try std.testing.expectEqual(@as(usize, 2), held.chunks.items.len);
    try std.testing.expect(held.tools);

    // With a long interval nothing extra is sent.
    var reader2: std.Io.Reader = .fixed(up);
    var out2: std.Io.Writer.Allocating = .init(a);
    var held2: Held = .{};
    try held2.read(a, std.testing.io, &reader2, &out2.writer, true, .fromSeconds(60));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out2.written(), "keepalive"));
}

test "the effort header fills in reasoning.effort when the body has none" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"model\":\"m\"}", .{});
    try applyEffort(a, &v.object, "medium");
    try std.testing.expectEqualStrings("medium", v.object.get("reasoning").?.object.get("effort").?.string);

    var kept = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"reasoning_effort\":\"low\"}", .{});
    try applyEffort(a, &kept.object, "high");
    try std.testing.expect(kept.object.get("reasoning") == null);

    var bogus = try std.json.parseFromSliceLeaky(std.json.Value, a, "{}", .{});
    try applyEffort(a, &bogus.object, "turbo");
    try std.testing.expect(bogus.object.get("reasoning") == null);
}
