//! OpenRouter (OpenAI-compatible) upstream: one streamed chat completion,
//! accumulated into text, reasoning, tool calls, URL citations and usage.
//! `Upstream` is the seam tests replace with canned SSE.
const std = @import("std");
const anole = @import("anole");
const sse = @import("net/sse_client.zig");

// anole.http does not export the core response types; take them from `fetch`.
const CoreResponse = @typeInfo(@typeInfo(@TypeOf(anole.http.Client.fetch)).@"fn".return_type.?).error_union.payload;
const BodyReader = @typeInfo(@typeInfo(@TypeOf(CoreResponse.reader)).@"fn".return_type.?).error_union.payload;

// ------------------------------------------------------------------ the seam

/// An open upstream response body.
pub const Stream = struct {
    status: u16,
    reader: *std.Io.Reader,
    ctx: *anyopaque,
    closeFn: *const fn (*anyopaque) void,

    pub fn close(self: Stream) void {
        self.closeFn(self.ctx);
    }
};

pub const Upstream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// POST `path` (relative to the API root) with a JSON body, streamed.
        post: *const fn (ptr: *anyopaque, req: *anole.Request, path: []const u8, body: []const u8, extra_headers: []const [2][]const u8) anyerror!Stream,
        /// GET `path`, whole body, for catalog refreshes (no request needed).
        get: *const fn (ptr: *anyopaque, io: std.Io, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8,
    };

    pub fn post(self: Upstream, req: *anole.Request, path: []const u8, body: []const u8, extra_headers: []const [2][]const u8) !Stream {
        return self.vtable.post(self.ptr, req, path, body, extra_headers);
    }

    pub fn get(self: Upstream, io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
        return self.vtable.get(self.ptr, io, arena, path);
    }
};

/// The real OpenRouter client, through the server's pooled HTTP client.
pub const Client = struct {
    base_url: []const u8,
    api_key: []const u8,
    referer: []const u8,

    const Live = struct {
        response: CoreResponse,
        buffer: [64 * 1024]u8,
        body: BodyReader,
    };

    pub fn upstream(self: *Client) Upstream {
        return .{ .ptr = self, .vtable = &.{ .post = post, .get = get } };
    }

    fn headers(self: *Client, arena: std.mem.Allocator, extra: []const [2][]const u8) !anole.http.Headers {
        var h = try anole.http.Headers.init(arena, 6 + extra.len);
        try h.put("Authorization", try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key}));
        try h.put("Content-Type", "application/json");
        try h.put("HTTP-Referer", self.referer);
        try h.put("X-Title", "EveryAI");
        for (extra) |e| try h.put(e[0], e[1]);
        return h;
    }

    fn post(ptr: *anyopaque, req: *anole.Request, path: []const u8, body: []const u8, extra: []const [2][]const u8) anyerror!Stream {
        const self: *Client = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(req.arena, "{s}{s}", .{ self.base_url, path });
        const h = try self.headers(req.arena, extra);
        const live = try req.arena.create(Live);
        live.response = try anole.client(req).http.fetch(url, .{
            .method = .post,
            .headers = &h,
            .body = body,
            .stream = true,
            .timeout = .none,
        });
        live.body = try live.response.reader(&live.buffer);
        return .{
            .status = @intCast(@backingInt(live.response.status())),
            .reader = &live.body.interface,
            .ctx = live,
            .closeFn = closeLive,
        };
    }

    fn closeLive(ctx: *anyopaque) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        live.response.deinit();
    }

    fn get(ptr: *anyopaque, io: std.Io, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        const self: *Client = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base_url, path });
        var r = try anole.client(io).fetch(url, .{ .headers = &.{.{ "Authorization", try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key}) }} });
        defer r.deinit();
        if (@backingInt(r.status()) >= 300) return error.BadGateway;
        return arena.dupe(u8, try r.body());
    }
};

// ------------------------------------------------------------------ one completion

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// JSON text as the model produced it.
    arguments: []const u8,
};

pub const Source = struct {
    url: []const u8,
    title: []const u8,
    snippet: ?[]const u8 = null,
};

pub const Usage = struct {
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    cached_tokens: i64 = 0,
    cache_write_tokens: i64 = 0,
    cost_usd: f64 = 0,
};

pub const Result = struct {
    text: []const u8,
    reasoning: []const u8,
    tool_calls: []const ToolCall,
    sources: []const Source,
    usage: Usage,
    finish_reason: []const u8,
    model: []const u8,
};

/// What a completion reports while it streams.
pub const Delta = union(enum) {
    text: []const u8,
    reasoning: []const u8,
    /// Sources new since the last event, in citation order; the client appends.
    sources: []const Source,
};

pub const UpstreamError = struct {
    status: u16,
    message: []const u8,
};

/// Streams one `/chat/completions` call. `sink.onDelta(Delta)` is called as
/// content arrives; the accumulated result is returned (memory in `arena`).
/// An upstream failure returns `error.Upstream` with `err_out` filled in.
pub fn complete(up: Upstream, req: *anole.Request, arena: std.mem.Allocator, body: []const u8, extra_headers: []const [2][]const u8, sink: anytype, err_out: *UpstreamError) !Result {
    const stream = try up.post(req, "/chat/completions", body, extra_headers);
    defer stream.close();

    if (stream.status >= 300) {
        const raw = stream.reader.allocRemaining(arena, .limited(64 * 1024)) catch "";
        err_out.* = .{ .status = stream.status, .message = errorMessage(arena, raw) };
        return error.Upstream;
    }

    var text: std.Io.Writer.Allocating = .init(arena);
    var reasoning: std.Io.Writer.Allocating = .init(arena);
    var calls: std.ArrayList(PartialCall) = .empty;
    var sources: std.ArrayList(Source) = .empty;
    var usage: Usage = .{};
    var finish: []const u8 = "";
    var model: []const u8 = "";

    var scratch: std.heap.ArenaAllocator = .init(arena);
    defer scratch.deinit();

    var parser = sse.Parser.init(arena, stream.reader);
    defer parser.deinit();
    while (try parser.next()) |ev| {
        if (std.mem.eql(u8, ev.data, "[DONE]")) break;
        _ = scratch.reset(.retain_capacity);
        const chunk = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), ev.data, .{}) catch continue;
        if (chunk != .object) continue;
        const o = chunk.object;

        if (o.get("error")) |e| {
            err_out.* = .{ .status = 502, .message = try arena.dupe(u8, jsonString(e, "message") orelse "upstream error") };
            return error.Upstream;
        }
        if (model.len == 0) if (jsonStr(o.get("model"))) |m| {
            model = try arena.dupe(u8, m);
        };
        if (o.get("usage")) |u| if (u == .object) {
            usage = parseUsage(u.object);
        };

        const choices = o.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const choice = choices.array.items[0].object;
        if (jsonStr(choice.get("finish_reason"))) |f| finish = try arena.dupe(u8, f);
        const delta = (choice.get("delta") orelse choice.get("message") orelse continue);
        if (delta != .object) continue;
        const d = delta.object;

        if (jsonStr(d.get("content"))) |c| if (c.len > 0) {
            try text.writer.writeAll(c);
            try sink.onDelta(.{ .text = c });
        };
        if (jsonStr(d.get("reasoning"))) |r| if (r.len > 0) {
            try reasoning.writer.writeAll(r);
            try sink.onDelta(.{ .reasoning = r });
        };
        if (d.get("tool_calls")) |tc| if (tc == .array) for (tc.array.items) |item| {
            try mergeToolCall(arena, &calls, item.object);
        };
        if (d.get("annotations")) |ann| if (ann == .array) {
            const first = sources.items.len;
            for (ann.array.items) |a| {
                const cit = (a.object.get("url_citation") orelse continue).object;
                const url = jsonStr(cit.get("url")) orelse continue;
                if (hasSource(sources.items, url)) continue;
                try sources.append(arena, .{
                    .url = try arena.dupe(u8, url),
                    .title = try arena.dupe(u8, jsonStr(cit.get("title")) orelse url),
                    .snippet = if (jsonStr(cit.get("content"))) |s| try arena.dupe(u8, s[0..@min(s.len, 300)]) else null,
                });
            }
            if (sources.items.len > first) try sink.onDelta(.{ .sources = sources.items[first..] });
        };
    }

    const tool_calls = try arena.alloc(ToolCall, calls.items.len);
    for (calls.items, tool_calls) |*c, *out| out.* = .{ .id = c.id, .name = c.name, .arguments = c.args.written() };
    return .{
        .text = text.written(),
        .reasoning = reasoning.written(),
        .tool_calls = tool_calls,
        .sources = sources.items,
        .usage = usage,
        .finish_reason = finish,
        .model = model,
    };
}

const PartialCall = struct { index: i64, id: []const u8, name: []const u8, args: std.Io.Writer.Allocating };

fn mergeToolCall(arena: std.mem.Allocator, calls: *std.ArrayList(PartialCall), o: std.json.ObjectMap) !void {
    const index: i64 = if (o.get("index")) |i| (if (i == .integer) i.integer else 0) else 0;
    const call = for (calls.items) |*c| {
        if (c.index == index) break c;
    } else blk: {
        try calls.append(arena, .{ .index = index, .id = "", .name = "", .args = .init(arena) });
        break :blk &calls.items[calls.items.len - 1];
    };
    if (jsonStr(o.get("id"))) |id| if (id.len > 0) {
        call.id = try arena.dupe(u8, id);
    };
    if (o.get("function")) |f| if (f == .object) {
        if (jsonStr(f.object.get("name"))) |n| if (n.len > 0) {
            call.name = try arena.dupe(u8, n);
        };
        if (jsonStr(f.object.get("arguments"))) |a| try call.args.writer.writeAll(a);
    };
}

fn hasSource(list: []const Source, url: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s.url, url)) return true;
    return false;
}

pub fn parseUsage(u: std.json.ObjectMap) Usage {
    var out: Usage = .{
        .prompt_tokens = jsonInt(u.get("prompt_tokens")),
        .completion_tokens = jsonInt(u.get("completion_tokens")),
        .cost_usd = jsonFloat(u.get("cost")),
    };
    if (u.get("prompt_tokens_details")) |d| if (d == .object) {
        out.cached_tokens = jsonInt(d.object.get("cached_tokens"));
        out.cache_write_tokens = jsonInt(d.object.get("cache_write_tokens"));
    };
    return out;
}

fn errorMessage(arena: std.mem.Allocator, raw: []const u8) []const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return if (raw.len > 0) raw else "upstream error";
    if (v == .object) if (v.object.get("error")) |e| if (jsonString(e, "message")) |m| return m;
    return if (raw.len > 0) raw else "upstream error";
}

pub fn jsonStr(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

pub fn jsonString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    return jsonStr(v.object.get(key));
}

pub fn jsonInt(v: ?std.json.Value) i64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

pub fn jsonFloat(v: ?std.json.Value) f64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

// ------------------------------------------------------------------ test double

/// Serves canned SSE bodies in order, recording each request body.
pub const Fake = struct {
    responses: []const []const u8,
    status: u16 = 200,
    next_index: usize = 0,
    bodies: std.ArrayList([]const u8) = .empty,
    gpa: std.mem.Allocator,
    models_json: []const u8 = "{\"data\":[]}",

    const Open = struct { reader: std.Io.Reader };

    pub fn upstream(self: *Fake) Upstream {
        return .{ .ptr = self, .vtable = &.{ .post = fakePost, .get = fakeGet } };
    }

    pub fn deinit(self: *Fake) void {
        for (self.bodies.items) |b| self.gpa.free(b);
        self.bodies.deinit(self.gpa);
    }

    fn fakePost(ptr: *anyopaque, req: *anole.Request, _: []const u8, body: []const u8, _: []const [2][]const u8) anyerror!Stream {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        try self.bodies.append(self.gpa, try self.gpa.dupe(u8, body));
        const i = @min(self.next_index, self.responses.len - 1);
        self.next_index += 1;
        const open = try req.arena.create(Open);
        open.reader = .fixed(self.responses[i]);
        return .{ .status = self.status, .reader = &open.reader, .ctx = open, .closeFn = noClose };
    }

    fn noClose(_: *anyopaque) void {}

    fn fakeGet(ptr: *anyopaque, _: std.Io, arena: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        return arena.dupe(u8, self.models_json);
    }
};
