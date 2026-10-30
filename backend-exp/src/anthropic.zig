//! Anthropic's Messages API behind the OpenAI chat-completions shape the rest
//! of the backend speaks. `Adapter` is an `openrouter.Upstream`: it translates
//! the request, posts it to `/messages` through an inner transport (the real
//! API, or a fake in tests), and translates the reply (SSE or JSON) back into
//! OpenAI chunks. Anthropic reports tokens but no cost, so the usage chunk's
//! `cost` is computed from the catalog's prices; `complete()`, the gateway and
//! billing then work unchanged.
//!
//! Thinking comes out as `reasoning` text plus OpenRouter-style
//! `reasoning_details` (signed `reasoning.text`, `reasoning.encrypted` for
//! redacted blocks). Details on an assistant message go back in as thinking
//! blocks, so a tool loop keeps its reasoning; messages without them (earlier
//! turns, other callers) still work, as the 5.5 models accept that.
const std = @import("std");
const anole = @import("anole");
const openrouter = @import("openrouter.zig");
const models = @import("models.zig");
const sse = @import("net/sse_client.zig");
const util = @import("util.zig");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const jsonStr = openrouter.jsonStr;
const jsonInt = openrouter.jsonInt;

/// The `format` of reasoning details this adapter makes and takes back.
const details_format = "anthropic-claude-v1";

pub const Adapter = struct {
    /// Posts raw Messages API requests (`openrouter.Client` with `.auth = .anthropic`).
    inner: openrouter.Upstream,
    catalog: *models.Catalog,

    pub fn upstream(self: *Adapter) openrouter.Upstream {
        return .{ .ptr = self, .vtable = &.{ .post = post, .get = get } };
    }

    /// The catalog always comes from OpenRouter.
    fn get(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
        return error.Unsupported;
    }

    fn post(ptr: *anyopaque, req: *anole.Request, path: []const u8, body: []const u8, extra: []const [2][]const u8) anyerror!openrouter.Stream {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, path, "/chat/completions")) return error.Unsupported;
        const arena = req.arena;
        const in = try std.json.parseFromSliceLeaky(Value, arena, body, .{});
        if (in != .object) return error.BadRequest;
        const t = try translateRequest(arena, in.object);

        var headers: std.ArrayList([2][]const u8) = .empty;
        try headers.appendSlice(arena, extra);
        if (t.fallbacks) try headers.append(arena, .{ "anthropic-beta", "server-side-fallback-2026-07-01" });
        const up = try self.inner.post(req, "/messages", t.body, headers.items);

        const prices = self.catalog.pricesOf(req.io, t.model);
        if (prices == null) std.log.warn("no catalog prices for {s}; the call is billed as free", .{t.model});
        const meta: Meta = .{ .model = t.model, .prices = prices, .created = util.now(req.io) };

        if (up.status >= 300) {
            defer up.close();
            const raw = up.reader.allocRemaining(arena, .limited(64 * 1024)) catch "";
            // 529 (overloaded) is Anthropic-only; clients know 503.
            const status: u16 = if (up.status == 529) 503 else up.status;
            return fixed(arena, status, try translateError(arena, raw, up.status));
        }
        if (!t.stream) {
            defer up.close();
            const raw = try up.reader.allocRemaining(arena, .limited(64 << 20));
            return fixed(arena, 200, try translateMessage(arena, raw, meta));
        }
        const tr = try arena.create(Translator);
        tr.init(arena, up, meta);
        return .{ .status = 200, .reader = &tr.reader, .ctx = tr, .closeFn = Translator.close };
    }
};

const Fixed = struct { reader: std.Io.Reader };

fn fixed(arena: std.mem.Allocator, status: u16, bytes: []const u8) !openrouter.Stream {
    const f = try arena.create(Fixed);
    f.reader = .fixed(bytes);
    return .{ .status = status, .reader = &f.reader, .ctx = f, .closeFn = noClose };
}

fn noClose(_: *anyopaque) void {}

// ------------------------------------------------------------------ request

pub const Translated = struct {
    body: []const u8,
    /// The OpenRouter id the caller used (prices, and echoed in replies).
    model: []const u8,
    stream: bool,
    fallbacks: bool,
};

/// "anthropic/claude-haiku-5.5" -> "claude-haiku-5-5".
pub fn anthropicId(arena: std.mem.Allocator, model: []const u8) ![]const u8 {
    var id = model;
    if (std.mem.indexOfScalar(u8, id, '/')) |i| id = id[i + 1 ..];
    if (std.mem.indexOfScalar(u8, id, ':')) |i| id = id[0..i];
    const out = try arena.dupe(u8, id);
    std.mem.replaceScalar(u8, out, '.', '-');
    return out;
}

/// Most cache breakpoints one request may carry.
const max_breakpoints = 4;

pub fn translateRequest(arena: std.mem.Allocator, in: ObjectMap) !Translated {
    const model = jsonStr(in.get("model")) orelse return error.BadRequest;
    const id = try anthropicId(arena, model);
    var out: ObjectMap = .empty;
    try out.put(arena, "model", .{ .string = id });

    const max = jsonInt(in.get("max_completion_tokens"));
    const max2 = jsonInt(in.get("max_tokens"));
    try out.put(arena, "max_tokens", .{ .integer = if (max > 0) max else if (max2 > 0) max2 else 32000 });

    const stream = if (in.get("stream")) |s| s == .bool and s.bool else false;
    if (stream) try out.put(arena, "stream", .{ .bool = true });

    // Summarized thinking streams as `reasoning`.
    try out.put(arena, "thinking", try obj(arena, &.{ .{ "type", str("adaptive") }, .{ "display", str("summarized") } }));
    const effort = jsonStr(in.get("reasoning_effort")) orelse
        (if (in.get("reasoning")) |r| (if (r == .object) jsonStr(r.object.get("effort")) else null) else null);
    if (effort) |e| for ([_][]const u8{ "low", "medium", "high", "xhigh", "max" }) |ok| {
        if (std.mem.eql(u8, e, ok)) {
            try out.put(arena, "output_config", try obj(arena, &.{.{ "effort", str(ok) }}));
            break;
        }
    };

    // Refusal fallbacks (recommended on the models that have them).
    const fallbacks = std.mem.indexOf(u8, id, "opus-5-5") != null or std.mem.indexOf(u8, id, "sonnet-5-5") != null;
    if (fallbacks) try out.put(arena, "fallbacks", str("default"));

    if (in.get("stop")) |s| {
        var list: std.json.Array = .init(arena);
        switch (s) {
            .string => |x| if (std.mem.trim(u8, x, " \n\t").len > 0) try list.append(str(x)),
            .array => |a| for (a.items) |x| if (x == .string and std.mem.trim(u8, x.string, " \n\t").len > 0) try list.append(x),
            else => {},
        }
        if (list.items.len > 0) try out.put(arena, "stop_sequences", .{ .array = list });
    }

    // Tools.
    var marks: std.ArrayList(*ObjectMap) = .empty;
    var fixed_marks: usize = 0;
    var has_tools = false;
    if (in.get("tools")) |tv| if (tv == .array and tv.array.items.len > 0) {
        var tools: std.json.Array = .init(arena);
        for (tv.array.items) |t| {
            if (t != .object) continue;
            const f = (t.object.get("function") orelse continue);
            if (f != .object) continue;
            var tool: ObjectMap = .empty;
            try tool.put(arena, "name", f.object.get("name") orelse continue);
            if (f.object.get("description")) |d| if (d == .string) try tool.put(arena, "description", d);
            try tool.put(arena, "input_schema", f.object.get("parameters") orelse try obj(arena, &.{ .{ "type", str("object") }, .{ "properties", try obj(arena, &.{}) } }));
            if (t.object.get("cache_control") orelse f.object.get("cache_control")) |cc| try tool.put(arena, "cache_control", cc);
            try tools.append(.{ .object = tool });
        }
        if (tools.items.len > 0) {
            has_tools = true;
            try out.put(arena, "tools", .{ .array = tools });
        }
    };
    if (has_tools) {
        const none = if (in.get("tool_choice")) |c| (c == .string and std.mem.eql(u8, c.string, "none")) else false;
        // Forced choices ("required", a named tool) are rejected with thinking on.
        try out.put(arena, "tool_choice", try obj(arena, &.{.{ "type", str(if (none) "none" else "auto") }}));
    }

    // Messages: system ones hoisted; tool results grouped into user turns.
    var system: std.json.Array = .init(arena);
    var msgs: std.ArrayList(Msg) = .empty;
    const list = in.get("messages") orelse return error.BadRequest;
    if (list != .array) return error.BadRequest;
    for (list.array.items) |m| {
        if (m != .object) continue;
        const role = jsonStr(m.object.get("role")) orelse continue;
        const content = m.object.get("content");
        if (std.mem.eql(u8, role, "system") or std.mem.eql(u8, role, "developer")) {
            try blocksOf(arena, content, &system);
        } else if (std.mem.eql(u8, role, "assistant")) {
            var blocks: std.json.Array = .init(arena);
            try thinkingOf(arena, m.object.get("reasoning_details"), &blocks);
            try blocksOf(arena, content, &blocks);
            if (m.object.get("tool_calls")) |tc| if (tc == .array) for (tc.array.items) |call| {
                if (call != .object) continue;
                const f = call.object.get("function") orelse continue;
                if (f != .object) continue;
                const args = jsonStr(f.object.get("arguments")) orelse "{}";
                const input = std.json.parseFromSliceLeaky(Value, arena, if (args.len == 0) "{}" else args, .{}) catch try obj(arena, &.{});
                try blocks.append(try obj(arena, &.{
                    .{ "type", str("tool_use") },
                    .{ "id", call.object.get("id") orelse str("") },
                    .{ "name", f.object.get("name") orelse str("") },
                    .{ "input", if (input == .object) input else try obj(arena, &.{}) },
                }));
            };
            try appendMsg(arena, &msgs, "assistant", blocks);
        } else if (std.mem.eql(u8, role, "tool")) {
            var inner: std.json.Array = .init(arena);
            try blocksOf(arena, content, &inner);
            var result: ObjectMap = .empty;
            try result.put(arena, "type", str("tool_result"));
            try result.put(arena, "tool_use_id", m.object.get("tool_call_id") orelse str(""));
            // A breakpoint inside the result moves onto the result block.
            for (inner.items) |*b| if (b.object.fetchSwapRemove("cache_control")) |kv| try result.put(arena, "cache_control", kv.value);
            if (inner.items.len == 0) {
                try result.put(arena, "content", str("(no output)"));
            } else {
                try result.put(arena, "content", .{ .array = inner });
            }
            var blocks: std.json.Array = .init(arena);
            try blocks.append(.{ .object = result });
            try appendMsg(arena, &msgs, "user", blocks);
        } else {
            var blocks: std.json.Array = .init(arena);
            try blocksOf(arena, content, &blocks);
            try appendMsg(arena, &msgs, "user", blocks);
        }
    }
    if (msgs.items.len == 0 or !std.mem.eql(u8, msgs.items[0].role, "user")) {
        var blocks: std.json.Array = .init(arena);
        try blocks.append(try textBlock(arena, "(continue)"));
        try msgs.insert(arena, 0, .{ .role = "user", .blocks = blocks });
    }

    // Keep at most four breakpoints: tools and system first, then the latest messages.
    if (out.getPtr("tools")) |t| for (t.array.items) |*b| if (b.object.contains("cache_control")) try marks.append(arena, &b.object);
    for (system.items) |*b| if (b.object.contains("cache_control")) try marks.append(arena, &b.object);
    fixed_marks = marks.items.len;
    for (msgs.items) |*msg| for (msg.blocks.items) |*b| if (b.object.contains("cache_control")) try marks.append(arena, &b.object);
    var drop = if (marks.items.len > max_breakpoints) marks.items.len - max_breakpoints else 0;
    var i: usize = fixed_marks;
    while (drop > 0 and i < marks.items.len) : (i += 1) {
        _ = marks.items[i].swapRemove("cache_control");
        drop -= 1;
    }
    i = 0;
    while (drop > 0) : (i += 1) {
        _ = marks.items[i].swapRemove("cache_control");
        drop -= 1;
    }

    if (system.items.len > 0) try out.put(arena, "system", .{ .array = system });
    var out_msgs: std.json.Array = .init(arena);
    for (msgs.items) |msg| try out_msgs.append(try obj(arena, &.{ .{ "role", str(msg.role) }, .{ "content", .{ .array = msg.blocks } } }));
    try out.put(arena, "messages", .{ .array = out_msgs });

    return .{
        .body = try std.json.Stringify.valueAlloc(arena, Value{ .object = out }, .{}),
        .model = model,
        .stream = stream,
        .fallbacks = fallbacks,
    };
}

const Msg = struct { role: []const u8, blocks: std.json.Array };

/// Consecutive same-role turns merge (Anthropic wants them alternating). An
/// empty turn is dropped.
fn appendMsg(arena: std.mem.Allocator, msgs: *std.ArrayList(Msg), role: []const u8, blocks: std.json.Array) !void {
    if (blocks.items.len == 0) return;
    if (msgs.items.len > 0) {
        const last = &msgs.items[msgs.items.len - 1];
        if (std.mem.eql(u8, last.role, role)) return last.blocks.appendSlice(blocks.items);
    }
    try msgs.append(arena, .{ .role = role, .blocks = blocks });
}

/// Signed reasoning details as thinking blocks (they lead the assistant
/// message). Unsigned text and other providers' formats are dropped: Anthropic
/// rejects thinking it can't verify.
fn thinkingOf(arena: std.mem.Allocator, details: ?Value, out: *std.json.Array) !void {
    const list = details orelse return;
    if (list != .array) return;
    for (list.array.items) |d| {
        if (d != .object) continue;
        if (jsonStr(d.object.get("format"))) |f| if (!std.mem.startsWith(u8, f, "anthropic")) continue;
        const kind = jsonStr(d.object.get("type")) orelse continue;
        if (std.mem.eql(u8, kind, "reasoning.text")) {
            const sig = jsonStr(d.object.get("signature")) orelse continue;
            if (sig.len == 0) continue;
            try out.append(try obj(arena, &.{ .{ "type", str("thinking") }, .{ "thinking", str(jsonStr(d.object.get("text")) orelse "") }, .{ "signature", str(sig) } }));
        } else if (std.mem.eql(u8, kind, "reasoning.encrypted")) {
            const data = jsonStr(d.object.get("data")) orelse continue;
            try out.append(try obj(arena, &.{ .{ "type", str("redacted_thinking") }, .{ "data", str(data) } }));
        }
    }
}

/// OpenAI content (a string or parts) as Anthropic blocks. Empty text is
/// skipped (Anthropic rejects it); `cache_control` is kept.
fn blocksOf(arena: std.mem.Allocator, content: ?Value, out: *std.json.Array) !void {
    const c = content orelse return;
    switch (c) {
        .string => |s| if (s.len > 0) try out.append(try textBlock(arena, s)),
        .array => |parts| for (parts.items) |p| {
            if (p != .object) continue;
            const kind = jsonStr(p.object.get("type")) orelse continue;
            var block: Value = undefined;
            if (std.mem.eql(u8, kind, "text")) {
                const t = jsonStr(p.object.get("text")) orelse continue;
                if (t.len == 0) continue;
                block = try textBlock(arena, t);
            } else if (std.mem.eql(u8, kind, "image_url")) {
                const iu = p.object.get("image_url") orelse continue;
                const url = (if (iu == .object) jsonStr(iu.object.get("url")) else jsonStr(iu)) orelse continue;
                block = if (parseDataUrl(url)) |d|
                    try obj(arena, &.{ .{ "type", str("image") }, .{ "source", try obj(arena, &.{ .{ "type", str("base64") }, .{ "media_type", str(d.mime) }, .{ "data", str(d.data) } }) } })
                else
                    try obj(arena, &.{ .{ "type", str("image") }, .{ "source", try obj(arena, &.{ .{ "type", str("url") }, .{ "url", str(url) } }) } });
            } else if (std.mem.eql(u8, kind, "file")) {
                const f = p.object.get("file") orelse continue;
                if (f != .object) continue;
                const name = jsonStr(f.object.get("filename")) orelse "file";
                const d = parseDataUrl(jsonStr(f.object.get("file_data")) orelse "") orelse continue;
                block = if (std.mem.eql(u8, d.mime, "application/pdf"))
                    try obj(arena, &.{ .{ "type", str("document") }, .{ "title", str(name) }, .{ "source", try obj(arena, &.{ .{ "type", str("base64") }, .{ "media_type", str(d.mime) }, .{ "data", str(d.data) } }) } })
                else
                    try textBlock(arena, try std.fmt.allocPrint(arena, "[{s} ({s}) can't be read by this model]", .{ name, d.mime }));
            } else if (std.mem.eql(u8, kind, "input_audio")) {
                block = try textBlock(arena, "[An audio clip was attached; this model can't listen to audio]");
            } else continue;
            if (p.object.get("cache_control")) |cc| try block.object.put(arena, "cache_control", cc);
            try out.append(block);
        },
        else => {},
    }
}

const DataUrl = struct { mime: []const u8, data: []const u8 };

/// "data:image/png;base64,AAAA" -> {image/png, AAAA}.
fn parseDataUrl(url: []const u8) ?DataUrl {
    if (!std.mem.startsWith(u8, url, "data:")) return null;
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse return null;
    const head = url[5..comma];
    if (!std.mem.endsWith(u8, head, ";base64")) return null;
    return .{ .mime = head[0 .. head.len - ";base64".len], .data = url[comma + 1 ..] };
}

fn str(s: []const u8) Value {
    return .{ .string = s };
}

fn obj(arena: std.mem.Allocator, fields: []const struct { []const u8, Value }) !Value {
    var m: ObjectMap = .empty;
    for (fields) |f| try m.put(arena, f[0], f[1]);
    return .{ .object = m };
}

fn textBlock(arena: std.mem.Allocator, text: []const u8) !Value {
    return obj(arena, &.{ .{ "type", str("text") }, .{ "text", str(text) } });
}

// ------------------------------------------------------------------ response

const Meta = struct {
    model: []const u8,
    prices: ?models.Prices,
    created: i64,
};

const Usage = struct {
    input: i64 = 0,
    cache_read: i64 = 0,
    cache_creation: i64 = 0,
    cache_5m: i64 = 0,
    cache_1h: i64 = 0,
    output: i64 = 0,

    fn merge(self: *Usage, u: ObjectMap) void {
        if (u.get("input_tokens")) |v| self.input = jsonInt(v);
        if (u.get("output_tokens")) |v| self.output = jsonInt(v);
        if (u.get("cache_read_input_tokens")) |v| self.cache_read = jsonInt(v);
        if (u.get("cache_creation_input_tokens")) |v| self.cache_creation = jsonInt(v);
        if (u.get("cache_creation")) |c| if (c == .object) {
            self.cache_5m = jsonInt(c.object.get("ephemeral_5m_input_tokens"));
            self.cache_1h = jsonInt(c.object.get("ephemeral_1h_input_tokens"));
        };
    }

    fn cost(self: Usage, prices: ?models.Prices) f64 {
        const p = prices orelse return 0;
        // No TTL breakdown: price every write as a 5-minute one.
        const split = self.cache_5m + self.cache_1h == self.cache_creation;
        return p.cost(.{
            .input = self.input,
            .cache_read = self.cache_read,
            .cache_write_5m = if (split) self.cache_5m else self.cache_creation,
            .cache_write_1h = if (split) self.cache_1h else 0,
            .output = self.output,
        });
    }

    /// The OpenAI/OpenRouter usage object (`prompt_tokens` includes cached).
    fn write(self: Usage, s: *std.json.Stringify, prices: ?models.Prices) !void {
        const prompt = self.input + self.cache_read + self.cache_creation;
        try s.write(.{
            .prompt_tokens = prompt,
            .completion_tokens = self.output,
            .total_tokens = prompt + self.output,
            .cost = self.cost(prices),
            .prompt_tokens_details = .{ .cached_tokens = self.cache_read, .cache_write_tokens = self.cache_creation },
        });
    }
};

fn finishReason(stop: []const u8) []const u8 {
    const map = [_][2][]const u8{
        .{ "tool_use", "tool_calls" },
        .{ "max_tokens", "length" },
        .{ "model_context_window_exceeded", "length" },
        .{ "refusal", "content_filter" },
    };
    for (map) |m| if (std.mem.eql(u8, stop, m[0])) return m[1];
    return "stop";
}

/// Anthropic SSE in, OpenAI `chat.completion.chunk` SSE out, as a reader.
const Translator = struct {
    reader: std.Io.Reader,
    buffer: [16 * 1024]u8,
    up: openrouter.Stream,
    parser: sse.Parser,
    arena: std.mem.Allocator,
    scratch: std.heap.ArenaAllocator,
    out: std.Io.Writer.Allocating,
    pos: usize = 0,
    meta: Meta,
    id: []const u8 = "",
    /// Anthropic block index -> OpenAI tool_calls index (-1: not a tool).
    tool_of: std.ArrayList(i64) = .empty,
    tools: i64 = 0,
    usage: Usage = .{},
    done: bool = false,

    fn init(self: *Translator, arena: std.mem.Allocator, up: openrouter.Stream, meta: Meta) void {
        self.* = .{
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
            .buffer = undefined,
            .up = up,
            .parser = sse.Parser.init(arena, up.reader),
            .arena = arena,
            .scratch = .init(arena),
            .out = .init(arena),
            .meta = meta,
        };
        self.reader.buffer = &self.buffer;
    }

    fn close(ctx: *anyopaque) void {
        const self: *Translator = @ptrCast(@alignCast(ctx));
        self.parser.deinit();
        self.up.close();
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Translator = @alignCast(@fieldParentPtr("reader", r));
        while (self.pos >= self.out.written().len) {
            if (self.done) return error.EndOfStream;
            self.out.clearRetainingCapacity();
            self.pos = 0;
            self.pump() catch |err| {
                std.log.err("anthropic stream: {t}", .{err});
                return error.ReadFailed;
            };
        }
        const pending = self.out.written()[self.pos..];
        const n = limit.minInt(pending.len);
        try w.writeAll(pending[0..n]);
        self.pos += n;
        return n;
    }

    /// Translates the next upstream event into zero or more output chunks.
    fn pump(self: *Translator) !void {
        const ev = (try self.parser.next()) orelse return self.finish();
        _ = self.scratch.reset(.retain_capacity);
        const v = std.json.parseFromSliceLeaky(Value, self.scratch.allocator(), ev.data, .{}) catch return;
        if (v != .object) return;
        const o = v.object;
        const kind = jsonStr(o.get("type")) orelse return;

        if (std.mem.eql(u8, kind, "message_start")) {
            const m = (o.get("message") orelse return).object;
            self.id = try self.arena.dupe(u8, jsonStr(m.get("id")) orelse "");
            if (m.get("usage")) |u| if (u == .object) self.usage.merge(u.object);
            try self.chunk(.{ .role = "assistant", .content = "" }, null);
        } else if (std.mem.eql(u8, kind, "content_block_start")) {
            const index: usize = @intCast(@max(0, jsonInt(o.get("index"))));
            const block = (o.get("content_block") orelse return).object;
            const btype = jsonStr(block.get("type")) orelse "";
            while (self.tool_of.items.len <= index) try self.tool_of.append(self.arena, -1);
            if (std.mem.eql(u8, btype, "tool_use")) {
                const ti = self.tools;
                self.tools += 1;
                self.tool_of.items[index] = ti;
                try self.chunk(.{ .tool_calls = .{.{
                    .index = ti,
                    .id = jsonStr(block.get("id")) orelse "",
                    .type = "function",
                    .function = .{ .name = jsonStr(block.get("name")) orelse "", .arguments = "" },
                }} }, null);
            } else if (std.mem.eql(u8, btype, "text")) {
                const t = jsonStr(block.get("text")) orelse "";
                if (t.len > 0) try self.chunk(.{ .content = t }, null);
            } else if (std.mem.eql(u8, btype, "redacted_thinking")) {
                const data = jsonStr(block.get("data")) orelse "";
                try self.chunk(.{ .reasoning_details = .{.{ .type = "reasoning.encrypted", .data = data, .format = details_format, .index = index }} }, null);
            }
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            const index: usize = @intCast(@max(0, jsonInt(o.get("index"))));
            const d = (o.get("delta") orelse return).object;
            const dtype = jsonStr(d.get("type")) orelse "";
            if (std.mem.eql(u8, dtype, "text_delta")) {
                const t = jsonStr(d.get("text")) orelse "";
                if (t.len > 0) try self.chunk(.{ .content = t }, null);
            } else if (std.mem.eql(u8, dtype, "thinking_delta")) {
                const t = jsonStr(d.get("thinking")) orelse "";
                if (t.len > 0) try self.chunk(.{
                    .reasoning = t,
                    .reasoning_content = t,
                    .reasoning_details = .{.{ .type = "reasoning.text", .text = t, .format = details_format, .index = index }},
                }, null);
            } else if (std.mem.eql(u8, dtype, "signature_delta")) {
                const sig = jsonStr(d.get("signature")) orelse "";
                if (sig.len > 0) try self.chunk(.{ .reasoning_details = .{.{ .type = "reasoning.text", .signature = sig, .format = details_format, .index = index }} }, null);
            } else if (std.mem.eql(u8, dtype, "input_json_delta")) {
                const part = jsonStr(d.get("partial_json")) orelse "";
                if (part.len == 0 or index >= self.tool_of.items.len or self.tool_of.items[index] < 0) return;
                try self.chunk(.{ .tool_calls = .{.{ .index = self.tool_of.items[index], .function = .{ .arguments = part } }} }, null);
            }
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            if (o.get("usage")) |u| if (u == .object) self.usage.merge(u.object);
            const d = (o.get("delta") orelse return).object;
            if (jsonStr(d.get("stop_reason"))) |stop| try self.chunk(struct {}{}, finishReason(stop));
        } else if (std.mem.eql(u8, kind, "message_stop")) {
            try self.finish();
        } else if (std.mem.eql(u8, kind, "error")) {
            const e = o.get("error");
            const message = if (e) |x| openrouter.jsonString(x, "message") orelse "upstream error" else "upstream error";
            try self.out.writer.writeAll("data: ");
            try std.json.Stringify.value(.{ .@"error" = .{ .message = message, .code = if (e) |x| openrouter.jsonString(x, "type") orelse "error" else "error" } }, .{}, &self.out.writer);
            try self.out.writer.writeAll("\n\n");
            try self.finish();
        }
    }

    fn chunk(self: *Translator, delta: anytype, finish_reason: ?[]const u8) !void {
        const w = &self.out.writer;
        try w.writeAll("data: ");
        try std.json.Stringify.value(.{
            .id = self.id,
            .object = "chat.completion.chunk",
            .created = self.meta.created,
            .model = self.meta.model,
            .choices = .{.{ .index = 0, .delta = delta, .finish_reason = finish_reason }},
        }, .{}, w);
        try w.writeAll("\n\n");
    }

    /// The usage chunk and `[DONE]`, once.
    fn finish(self: *Translator) !void {
        if (self.done) return;
        self.done = true;
        const w = &self.out.writer;
        var s: std.json.Stringify = .{ .writer = w };
        try w.writeAll("data: ");
        try s.beginObject();
        try s.objectField("id");
        try s.write(self.id);
        try s.objectField("object");
        try s.write("chat.completion.chunk");
        try s.objectField("created");
        try s.write(self.meta.created);
        try s.objectField("model");
        try s.write(self.meta.model);
        try s.objectField("choices");
        try s.beginArray();
        try s.endArray();
        try s.objectField("usage");
        try self.usage.write(&s, self.meta.prices);
        try s.endObject();
        try w.writeAll("\n\ndata: [DONE]\n\n");
    }
};

/// A whole (non-streamed) Messages reply as a `chat.completion`.
fn translateMessage(arena: std.mem.Allocator, raw: []const u8, meta: Meta) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(Value, arena, raw, .{});
    if (v != .object) return error.BadGateway;
    const o = v.object;
    var text: std.Io.Writer.Allocating = .init(arena);
    var reasoning: std.Io.Writer.Allocating = .init(arena);
    var calls: std.json.Array = .init(arena);
    var details: std.json.Array = .init(arena);
    if (o.get("content")) |c| if (c == .array) for (c.array.items, 0..) |b, i| {
        if (b != .object) continue;
        const btype = jsonStr(b.object.get("type")) orelse continue;
        if (std.mem.eql(u8, btype, "text")) {
            try text.writer.writeAll(jsonStr(b.object.get("text")) orelse "");
        } else if (std.mem.eql(u8, btype, "thinking")) {
            const t = jsonStr(b.object.get("thinking")) orelse "";
            try reasoning.writer.writeAll(t);
            try details.append(try obj(arena, &.{
                .{ "type", str("reasoning.text") },
                .{ "text", str(t) },
                .{ "signature", b.object.get("signature") orelse str("") },
                .{ "format", str(details_format) },
                .{ "index", .{ .integer = @intCast(i) } },
            }));
        } else if (std.mem.eql(u8, btype, "redacted_thinking")) {
            try details.append(try obj(arena, &.{
                .{ "type", str("reasoning.encrypted") },
                .{ "data", b.object.get("data") orelse str("") },
                .{ "format", str(details_format) },
                .{ "index", .{ .integer = @intCast(i) } },
            }));
        } else if (std.mem.eql(u8, btype, "tool_use")) {
            const args = try std.json.Stringify.valueAlloc(arena, b.object.get("input") orelse try obj(arena, &.{}), .{});
            try calls.append(try obj(arena, &.{
                .{ "id", b.object.get("id") orelse str("") },
                .{ "type", str("function") },
                .{ "function", try obj(arena, &.{ .{ "name", b.object.get("name") orelse str("") }, .{ "arguments", str(args) } }) },
            }));
        }
    };
    var message: ObjectMap = .empty;
    try message.put(arena, "role", str("assistant"));
    try message.put(arena, "content", if (text.written().len > 0) str(text.written()) else .null);
    if (reasoning.written().len > 0) {
        try message.put(arena, "reasoning", str(reasoning.written()));
        try message.put(arena, "reasoning_content", str(reasoning.written()));
    }
    if (details.items.len > 0) try message.put(arena, "reasoning_details", .{ .array = details });
    if (calls.items.len > 0) try message.put(arena, "tool_calls", .{ .array = calls });

    var usage: Usage = .{};
    if (o.get("usage")) |u| if (u == .object) usage.merge(u.object);

    var out: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("id");
    try s.write(jsonStr(o.get("id")) orelse "");
    try s.objectField("object");
    try s.write("chat.completion");
    try s.objectField("created");
    try s.write(meta.created);
    try s.objectField("model");
    try s.write(meta.model);
    try s.objectField("choices");
    try s.write(.{.{ .index = 0, .message = Value{ .object = message }, .finish_reason = finishReason(jsonStr(o.get("stop_reason")) orelse "end_turn") }});
    try s.objectField("usage");
    try usage.write(&s, meta.prices);
    try s.endObject();
    return out.written();
}

/// Anthropic's error body in OpenAI's shape (`openrouter.complete` and
/// LiteLLM read `error.message`).
fn translateError(arena: std.mem.Allocator, raw: []const u8, status: u16) ![]const u8 {
    var message: []const u8 = if (raw.len > 0) raw else "upstream error";
    var kind: []const u8 = "upstream_error";
    if (std.json.parseFromSliceLeaky(Value, arena, raw, .{})) |v| {
        if (v == .object) if (v.object.get("error")) |e| {
            message = openrouter.jsonString(e, "message") orelse message;
            kind = openrouter.jsonString(e, "type") orelse kind;
        };
    } else |_| {}
    return std.json.Stringify.valueAlloc(arena, .{ .@"error" = .{ .message = message, .type = kind, .code = status } }, .{});
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test anthropicId {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("claude-haiku-5-5", try anthropicId(arena.allocator(), "anthropic/claude-haiku-5.5"));
    try testing.expectEqualStrings("claude-opus-5-5", try anthropicId(arena.allocator(), "anthropic/claude-opus-5.5:thinking"));
}

test translateRequest {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in = try std.json.parseFromSliceLeaky(Value, a,
        \\{"model":"anthropic/claude-sonnet-5.5","stream":true,"temperature":0.2,"top_p":1,"usage":{"include":true},
        \\ "plugins":[{"id":"web"}],"tool_choice":"required",
        \\ "tools":[{"type":"function","function":{"name":"make_quiz","description":"Quiz","parameters":{"type":"object"}},"cache_control":{"type":"ephemeral"}}],
        \\ "messages":[
        \\  {"role":"system","content":[{"type":"text","text":"sys","cache_control":{"type":"ephemeral"}}]},
        \\  {"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBO"}},
        \\     {"type":"file","file":{"filename":"a.pdf","file_data":"data:application/pdf;base64,JVBE"}},{"type":"text","text":"what's this?","cache_control":{"type":"ephemeral"}}]},
        \\  {"role":"assistant","content":"","tool_calls":[{"id":"toolu_1","type":"function","function":{"name":"make_quiz","arguments":"{\"title\":\"x\"}"}}]},
        \\  {"role":"tool","tool_call_id":"toolu_1","content":"Shown to the user."},
        \\  {"role":"user","content":[{"type":"text","text":"thanks","cache_control":{"type":"ephemeral"}}]},
        \\  {"role":"assistant","content":"sure"},
        \\  {"role":"user","content":[{"type":"text","text":"more","cache_control":{"type":"ephemeral"}}]}
        \\ ]}
    , .{});
    const t = try translateRequest(a, in.object);
    try testing.expect(t.stream and t.fallbacks);
    try testing.expectEqualStrings("anthropic/claude-sonnet-5.5", t.model);
    const out = (try std.json.parseFromSliceLeaky(Value, a, t.body, .{})).object;
    try testing.expectEqualStrings("claude-sonnet-5-5", out.get("model").?.string);
    for ([_][]const u8{ "temperature", "top_p", "usage", "plugins" }) |k| try testing.expect(out.get(k) == null);
    try testing.expectEqualStrings("auto", out.get("tool_choice").?.object.get("type").?.string);
    try testing.expectEqualStrings("sys", out.get("system").?.array.items[0].object.get("text").?.string);
    const msgs = out.get("messages").?.array.items;
    // user, assistant(tool_use), user(tool_result + thanks), assistant, user
    try testing.expectEqual(@as(usize, 5), msgs.len);
    const first = msgs[0].object.get("content").?.array.items;
    try testing.expectEqualStrings("image", first[0].object.get("type").?.string);
    try testing.expectEqualStrings("image/png", first[0].object.get("source").?.object.get("media_type").?.string);
    try testing.expectEqualStrings("document", first[1].object.get("type").?.string);
    const tool_use = msgs[1].object.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("x", tool_use.get("input").?.object.get("title").?.string);
    const merged = msgs[2].object.get("content").?.array.items;
    try testing.expectEqualStrings("tool_result", merged[0].object.get("type").?.string);
    try testing.expectEqualStrings("thanks", merged[1].object.get("text").?.string);
    // Five breakpoints in: the oldest message one is dropped.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, t.body, "cache_control"));
    try testing.expect(first[2].object.get("cache_control") == null);
    try testing.expect(merged[1].object.get("cache_control") != null);
}

test "stream translation: text, thinking, tool call, usage with computed cost" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const upstream_sse =
        \\event: message_start
        \\data: {"type":"message_start","message":{"id":"msg_1","model":"claude-haiku-5-5","usage":{"input_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":200},"output_tokens":1}}}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Hmm."}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQB"}}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Here you go."}}
        \\
        \\event: ping
        \\data: {"type":"ping"}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_9","name":"make_quiz","input":{}}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"title\":"}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"Zig\"}"}}
        \\
        \\event: message_delta
        \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":40}}
        \\
        \\event: message_stop
        \\data: {"type":"message_stop"}
        \\
        \\
    ;
    var src: std.Io.Reader = .fixed(upstream_sse);
    const tr = try a.create(Translator);
    tr.init(a, .{ .status = 200, .reader = &src, .ctx = undefined, .closeFn = noClose }, .{
        .model = "anthropic/claude-haiku-5.5",
        .created = 1,
        .prices = .{ .base = .{ .prompt = 1e-6, .completion = 5e-6, .cache_read = 1e-7, .cache_write = 1.25e-6, .cache_write_1h = 2e-6 } },
    });
    defer tr.parser.deinit();

    // The same parser `openrouter.complete` uses reads it back.
    const Sink = struct {
        text: std.ArrayList(u8) = .empty,
        a: std.mem.Allocator,
        pub fn onDelta(self: *@This(), d: openrouter.Delta) !void {
            switch (d) {
                .text => |t| try self.text.appendSlice(self.a, t),
                .reasoning => |t| try self.text.appendSlice(self.a, t),
                .sources => {},
            }
        }
    };
    var sink: Sink = .{ .a = a };
    var err: openrouter.UpstreamError = .{ .status = 0, .message = "" };
    const translated = try tr.reader.allocRemaining(a, .unlimited);
    try testing.expect(std.mem.indexOf(u8, translated, "\"delta\":[]") == null);
    try testing.expect(std.mem.endsWith(u8, translated, "data: [DONE]\n\n"));
    var again: std.Io.Reader = .fixed(translated);
    const result = try openrouter.parseStream(a, &again, &sink, &err);
    try testing.expectEqualStrings("Hmm.Here you go.", sink.text.items);
    try testing.expectEqualStrings("Here you go.", result.text);
    try testing.expectEqualStrings("Hmm.", result.reasoning);
    try testing.expectEqualStrings(
        \\[{"type":"reasoning.text","format":"anthropic-claude-v1","signature":"EqQB","text":"Hmm.","index":0}]
    , result.reasoning_details);
    try testing.expectEqualStrings("tool_calls", result.finish_reason);
    try testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try testing.expectEqualStrings("toolu_9", result.tool_calls[0].id);
    try testing.expectEqualStrings("{\"title\":\"Zig\"}", result.tool_calls[0].arguments);
    try testing.expectEqual(@as(i64, 1300), result.usage.prompt_tokens);
    try testing.expectEqual(@as(i64, 1000), result.usage.cached_tokens);
    try testing.expectEqual(@as(i64, 200), result.usage.cache_write_tokens);
    try testing.expectEqual(@as(i64, 40), result.usage.completion_tokens);
    // 100×1e-6 + 1000×1e-7 + 200×2e-6 + 40×5e-6 = 0.0008
    try testing.expectApproxEqAbs(@as(f64, 0.0008), result.usage.cost_usd, 1e-12);
}

test "signed reasoning details go back as thinking blocks ahead of the tool call" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in = try std.json.parseFromSliceLeaky(Value, a,
        \\{"model":"anthropic/claude-haiku-5.5","reasoning":{"effort":"max"},"messages":[
        \\  {"role":"user","content":"go"},
        \\  {"role":"assistant","content":"","reasoning":"Hmm.","reasoning_details":[
        \\    {"type":"reasoning.text","text":"Hmm.","signature":"EqQB","format":"anthropic-claude-v1","index":0},
        \\    {"type":"reasoning.encrypted","data":"RED","format":"anthropic-claude-v1","index":1},
        \\    {"type":"reasoning.text","text":"unsigned","index":2},
        \\    {"type":"reasoning.text","text":"other","signature":"x","format":"openai-responses-v1","index":3}],
        \\   "tool_calls":[{"id":"toolu_1","type":"function","function":{"name":"web_fetch","arguments":"{}"}}]},
        \\  {"role":"tool","tool_call_id":"toolu_1","content":"page"}
        \\]}
    , .{});
    const t = try translateRequest(a, in.object);
    const out = (try std.json.parseFromSliceLeaky(Value, a, t.body, .{})).object;
    try testing.expectEqualStrings("max", out.get("output_config").?.object.get("effort").?.string);
    const blocks = out.get("messages").?.array.items[1].object.get("content").?.array.items;
    try testing.expectEqual(@as(usize, 3), blocks.len);
    try testing.expectEqualStrings("thinking", blocks[0].object.get("type").?.string);
    try testing.expectEqualStrings("Hmm.", blocks[0].object.get("thinking").?.string);
    try testing.expectEqualStrings("EqQB", blocks[0].object.get("signature").?.string);
    try testing.expectEqualStrings("redacted_thinking", blocks[1].object.get("type").?.string);
    try testing.expectEqualStrings("tool_use", blocks[2].object.get("type").?.string);
}

test "errors come back in OpenAI shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try translateError(arena.allocator(), "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}", 529);
    try testing.expectEqualStrings("{\"error\":{\"message\":\"Overloaded\",\"type\":\"overloaded_error\",\"code\":529}}", out);
}
