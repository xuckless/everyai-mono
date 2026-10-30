//! POST /v1/chat/stream: one assistant turn over Server-Sent Events.
//!
//! The server runs the tool loop. UI tools (artifacts, SVG, diagrams, charts,
//! quizzes, flashcards, slides) are streamed to the app as `tool` events and
//! acknowledged to the model; server tools (web_fetch, generate_image) run
//! here. Every upstream call is metered (billing.charge).
//!
//! Events: delta {text}, reasoning {text}, sources {sources} (new ones, appended), tool {id, name,
//! arguments}, tool_status {id, name, status, detail?}, image {id, mime, data},
//! usage {kind: chat|followups, model, tokens..., charged_micros}, followups {questions}, done {},
//! error {message, retryable}.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const billing = @import("billing.zig");
const openrouter = @import("openrouter.zig");
const tools = @import("tools.zig");
const util = @import("util.zig");
const images = @import("images.zig");

const Events = @typeInfo(@typeInfo(@TypeOf(anole.Response.startEventStream)).@"fn".return_type.?).error_union.payload;

pub const Mode = enum { chat, search, research };

pub const InMessage = struct {
    role: []const u8,
    /// A string, or OpenAI content parts (`text`, `image_url`, `file`,
    /// `input_audio`) for attachments, passed through to the model.
    content: std.json.Value,
};

pub const ChatRequest = struct {
    model: ?[]const u8 = null,
    mode: Mode = .chat,
    messages: []const InMessage,
    tools_enabled: bool = true,
    /// Client conversation id, for usage attribution.
    session: ?[]const u8 = null,
};

/// A message in the upstream conversation. `raw_tool_calls` is the assistant's
/// tool_calls array as JSON.
const Msg = struct {
    role: []const u8,
    content: []const u8 = "",
    /// Content parts instead of `content` (a message with attachments).
    parts: ?[]const std.json.Value = null,
    tool_call_id: ?[]const u8 = null,
    raw_tool_calls: ?[]const u8 = null,
};

// ------------------------------------------------------------------ prompt caching

/// Providers that need explicit `cache_control` breakpoints. Others (OpenAI,
/// DeepSeek, Grok, ...) cache stable prefixes on their own.
pub fn wantsBreakpoints(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "anthropic/") or std.mem.startsWith(u8, model, "google/gemini");
}

fn writeCacheControl(s: *std.json.Stringify, ttl: []const u8) !void {
    try s.objectField("cache_control");
    try s.beginObject();
    try s.objectField("type");
    try s.write("ephemeral");
    if (std.mem.eql(u8, ttl, "1h")) {
        try s.objectField("ttl");
        try s.write("1h");
    }
    try s.endObject();
}

/// Text content, as a plain string or (with a breakpoint) a one-part array.
/// Parts go through as they are, the breakpoint on the last text part.
fn writeContent(s: *std.json.Stringify, text: []const u8, parts: ?[]const std.json.Value, breakpoint: bool, ttl: []const u8) !void {
    try s.objectField("content");
    if (parts) |list| {
        var mark: ?usize = null;
        if (breakpoint) for (list, 0..) |p, i| {
            if (p == .object and std.mem.eql(u8, openrouter.jsonStr(p.object.get("type")) orelse "", "text")) mark = i;
        };
        try s.beginArray();
        for (list, 0..) |p, i| {
            if (p != .object or mark != i) {
                try s.write(p);
                continue;
            }
            try s.beginObject();
            var it = p.object.iterator();
            while (it.next()) |e| {
                try s.objectField(e.key_ptr.*);
                try s.write(e.value_ptr.*);
            }
            try writeCacheControl(s, ttl);
            try s.endObject();
        }
        return s.endArray();
    }
    if (!breakpoint) return s.write(text);
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(text);
    try writeCacheControl(s, ttl);
    try s.endObject();
    try s.endArray();
}

/// The upstream request body. Prefix order (tools, system, history) never
/// varies, so caches hit; breakpoints go on the system prompt and the last
/// message (the conversation so far, reused by the next turn).
fn buildBody(arena: std.mem.Allocator, model: []const u8, mode: Mode, with_tools: bool, messages: []const Msg, ttl: []const u8, engine: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    const bp = wantsBreakpoints(model);

    try s.beginObject();
    try s.objectField("model");
    try s.write(model);
    try s.objectField("stream");
    try s.write(true);
    try s.objectField("usage");
    try s.print("{{\"include\":true}}", .{});
    if (with_tools) {
        try s.objectField("tools");
        try s.print("{s}", .{tools.definitions});
    }
    if (mode == .search) {
        try s.objectField("plugins");
        try s.print("[{{\"id\":\"web\",\"engine\":\"{s}\",\"max_results\":5}}]", .{engine});
    }
    try s.objectField("messages");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("role");
    try s.write("system");
    try writeContent(&s, tools.system_prompt, null, bp, ttl);
    try s.endObject();
    for (messages, 0..) |m, i| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(m.role);
        try writeContent(&s, m.content, m.parts, bp and i == messages.len - 1 and (m.content.len > 0 or m.parts != null), ttl);
        if (m.tool_call_id) |id| {
            try s.objectField("tool_call_id");
            try s.write(id);
        }
        if (m.raw_tool_calls) |raw| {
            try s.objectField("tool_calls");
            try s.print("{s}", .{raw});
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return out.written();
}

// ------------------------------------------------------------------ the turn

const Sink = struct {
    ev: *Events,
    scratch: *std.Io.Writer.Allocating,

    fn send(self: Sink, name: []const u8, value: anytype) !void {
        self.scratch.clearRetainingCapacity();
        try std.json.Stringify.value(value, .{}, &self.scratch.writer);
        try self.ev.send(self.scratch.written(), .{ .event = name });
    }

    pub fn onDelta(self: Sink, d: openrouter.Delta) !void {
        switch (d) {
            .text => |t| try self.send("delta", .{ .text = t }),
            .reasoning => |t| try self.send("reasoning", .{ .text = t }),
            .sources => |list| try self.send("sources", .{ .sources = list }),
        }
    }
};

fn stream(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const who = try auth.identity(req);
    // std.json directly: content may be a string or an array of parts.
    const raw = (try req.body()) orelse return res.fail(.bad_request, "missing body");
    const body = std.json.parseFromSliceLeaky(ChatRequest, req.arena, raw, .{ .ignore_unknown_fields = true }) catch
        return res.fail(.unprocessable_entity, "body must be {model?, mode, messages: [{role, content}], tools_enabled, session?}");
    if (body.messages.len == 0) return res.fail(.unprocessable_entity, "messages must not be empty");
    for (body.messages) |m| if (m.content != .string and m.content != .array)
        return res.fail(.unprocessable_entity, "content must be a string or an array of parts");

    const model = switch (body.mode) {
        .research => app.cfg.research_model,
        else => body.model orelse app.cfg.default_model,
    };
    app.catalog.ensureFresh(app.upstream, req.io, app.cfg.markup);
    const facts = app.catalog.facts(req.io, model);
    billing.preflight(app, req, who.user_id, facts.free) catch {
        res.status = .payment_required;
        return res.json(.{ .message = "You're out of credits. Top up or upgrade your plan to keep using paid models.", .code = "out_of_credits" });
    };

    var buf: [16 * 1024]u8 = undefined;
    var ev = try res.startEventStream(&buf);
    var scratch: std.Io.Writer.Allocating = .init(req.arena);
    const sink: Sink = .{ .ev = &ev, .scratch = &scratch };

    run(app, req, who, model, body, facts.tools, sink) catch |err| switch (err) {
        error.Upstream, error.OutOfCredits => {}, // already reported
        else => {
            std.log.err("chat turn failed: {t}", .{err});
            sink.send("error", .{ .message = "Something went wrong while answering.", .retryable = true }) catch {};
        },
    };
    try ev.end();
}

fn run(app: *App, req: *anole.Request, who: auth.Identity, model: []const u8, body: ChatRequest, model_has_tools: bool, sink: Sink) !void {
    const arena = req.arena;
    var messages: std.ArrayList(Msg) = .empty;
    for (body.messages) |m| {
        const role = if (std.mem.eql(u8, m.role, "assistant")) "assistant" else "user";
        switch (m.content) {
            .array => |a| try messages.append(arena, .{ .role = role, .parts = a.items }),
            else => try messages.append(arena, .{ .role = role, .content = textOf(m.content) }),
        }
    }
    const with_tools = body.tools_enabled and model_has_tools and body.mode != .research;
    var final_text: std.Io.Writer.Allocating = .init(arena);
    // Search needs OpenRouter's web plugin.
    const route = app.route(model, body.mode == .chat);

    var step: u8 = 0;
    while (step < app.cfg.max_tool_steps) : (step += 1) {
        const request_body = try buildBody(arena, model, body.mode, with_tools, messages.items, app.cfg.cache_ttl, app.cfg.search_engine);
        var up_err: openrouter.UpstreamError = .{ .status = 0, .message = "" };
        const result = openrouter.complete(route.up, req, arena, request_body, &.{}, sink, &up_err) catch |err| switch (err) {
            error.Upstream => {
                try sink.send("error", .{ .message = up_err.message, .retryable = up_err.status == 429 or up_err.status >= 500, .status = up_err.status });
                return err;
            },
            else => return err,
        };
        try final_text.writer.writeAll(result.text);

        const c = try billing.charge(app, req, who.user_id, .{
            .kind = "chat",
            .model = model,
            .prompt_tokens = result.usage.prompt_tokens,
            .completion_tokens = result.usage.completion_tokens,
            .cached_tokens = result.usage.cached_tokens,
            .cache_write_tokens = result.usage.cache_write_tokens,
            .cost_usd = result.usage.cost_usd,
            .session = body.session,
            .provider = route.provider,
        });
        try sink.send("usage", .{
            .kind = "chat",
            .model = model,
            .prompt_tokens = result.usage.prompt_tokens,
            .completion_tokens = result.usage.completion_tokens,
            .cached_tokens = result.usage.cached_tokens,
            .cache_write_tokens = result.usage.cache_write_tokens,
            .charged_micros = c.charged_micros,
        });

        if (result.tool_calls.len == 0) break;

        // The assistant turn with its tool calls, then one result per call.
        try messages.append(arena, .{ .role = "assistant", .content = result.text, .raw_tool_calls = try toolCallsJson(arena, result.tool_calls) });
        for (result.tool_calls) |call| {
            const output = try runTool(app, req, who, body.session, call, sink);
            try messages.append(arena, .{ .role = "tool", .tool_call_id = call.id, .content = output });
        }
        // A model that stopped for another reason than tools is done.
        if (!std.mem.eql(u8, result.finish_reason, "tool_calls") and result.text.len > 0) break;
    }

    if (body.mode != .research and final_text.written().len > 0) {
        followUps(app, req, who, body, final_text.written(), sink) catch |err| std.log.warn("follow-ups failed: {t}", .{err});
    }
    try sink.send("done", .{});
}

/// The text of a message's content: the string, or its text parts joined.
fn textOf(content: std.json.Value) []const u8 {
    return switch (content) {
        .string => |t| t,
        .array => |a| blk: {
            // The app puts the typed text last, after attachments.
            var i = a.items.len;
            while (i > 0) {
                i -= 1;
                const p = a.items[i];
                if (p == .object and std.mem.eql(u8, openrouter.jsonStr(p.object.get("type")) orelse "", "text"))
                    break :blk openrouter.jsonStr(p.object.get("text")) orelse "";
            }
            break :blk "";
        },
        else => "",
    };
}

fn toolCallsJson(arena: std.mem.Allocator, calls: []const openrouter.ToolCall) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginArray();
    for (calls) |c| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(c.id);
        try s.objectField("type");
        try s.write("function");
        try s.objectField("function");
        try s.beginObject();
        try s.objectField("name");
        try s.write(c.name);
        try s.objectField("arguments");
        try s.write(if (c.arguments.len == 0) "{}" else c.arguments);
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();
    return out.written();
}

/// Runs or forwards one tool call; returns the text the model sees.
fn runTool(app: *App, req: *anole.Request, who: auth.Identity, session: ?[]const u8, call: openrouter.ToolCall, sink: Sink) ![]const u8 {
    const args_text = if (call.arguments.len == 0) "{}" else call.arguments;
    const args = std.json.parseFromSliceLeaky(std.json.Value, req.arena, args_text, .{}) catch {
        return "Error: the tool arguments were not valid JSON. Call the tool again with valid JSON.";
    };
    switch (tools.kindOf(call.name) orelse return "Error: unknown tool.") {
        .ui => {
            try sink.send("tool", .{ .id = call.id, .name = call.name, .arguments = args });
            return "Shown to the user.";
        },
        .server => {
            try sink.send("tool_status", .{ .id = call.id, .name = call.name, .status = "running", .detail = openrouter.jsonString(args, "url") orelse openrouter.jsonString(args, "prompt") });
            const output = (if (std.mem.eql(u8, call.name, "web_fetch"))
                webFetch(req, openrouter.jsonString(args, "url") orelse "")
            else
                generateImage(app, req, who, session, call.id, args, sink)) catch |err| blk: {
                break :blk try std.fmt.allocPrint(req.arena, "Error: {t}", .{err});
            };
            try sink.send("tool_status", .{ .id = call.id, .name = call.name, .status = if (std.mem.startsWith(u8, output, "Error")) "failed" else "done" });
            return output;
        },
    }
}

/// The page's readable text: tags, scripts and styles removed, whitespace
/// collapsed, at most 20k characters.
fn webFetch(req: *anole.Request, url: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return error.InvalidUrl;
    var r = try anole.client(req).fetch(url, .{ .headers = &.{ .{ "User-Agent", "EveryAI/0.1 (+https://everyai.app)" }, .{ "Accept", "text/html,text/plain,*/*" } } });
    defer r.deinit();
    if (@backingInt(r.status()) >= 400) return std.fmt.allocPrint(req.arena, "Error: HTTP {d}", .{@backingInt(r.status())});
    return readableText(req.arena, try r.body(), 20_000);
}

pub fn readableText(arena: std.mem.Allocator, html: []const u8, limit: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var space = true;
    while (i < html.len and out.items.len < limit) {
        const c = html[i];
        if (c == '<') {
            const rest = html[i..];
            inline for (.{ "script", "style", "noscript", "svg" }) |tag| {
                if (rest.len > tag.len + 1 and std.ascii.eqlIgnoreCase(rest[1 .. tag.len + 1], tag)) {
                    const close = "</" ++ tag;
                    if (indexOfIgnoreCase(rest, close)) |end| {
                        i += end + close.len;
                        break;
                    }
                }
            }
            const gt = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
            i = gt + 1;
            if (!space) {
                try out.append(arena, ' ');
                space = true;
            }
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            if (!space) try out.append(arena, ' ');
            space = true;
        } else {
            try out.append(arena, c);
            space = false;
        }
        i += 1;
    }
    return std.mem.trim(u8, out.items, " ");
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Calls the image model; streams the image to the app as an `image` event.
fn generateImage(app: *App, req: *anole.Request, who: auth.Identity, session: ?[]const u8, id: []const u8, args: std.json.Value, sink: Sink) ![]const u8 {
    const prompt = openrouter.jsonString(args, "prompt") orelse return error.MissingPrompt;
    const img = try images.generate(app, req, who, session, app.cfg.image_model, prompt, openrouter.jsonString(args, "aspect_ratio") orelse "1:1");
    try sink.send("image", .{ .id = id, .mime = img.mime, .data = img.data });
    return "The image was generated and shown to the user.";
}

/// Three short follow-up questions from the utility model.
fn followUps(app: *App, req: *anole.Request, who: auth.Identity, body: ChatRequest, answer: []const u8, sink: Sink) !void {
    const question = textOf(body.messages[body.messages.len - 1].content);
    const prompt = try std.fmt.allocPrint(req.arena,
        \\Question: {s}
        \\
        \\Answer (excerpt): {s}
        \\
        \\Suggest 3 short follow-up questions the user is likely to ask next, in the user's language.
        \\Reply with only a JSON array of 3 strings.
    , .{ question[0..@min(question.len, 2000)], answer[0..@min(answer.len, 3000)] });
    const req_body = try std.json.Stringify.valueAlloc(req.arena, .{
        .model = app.cfg.utility_model,
        .usage = .{ .include = true },
        .max_tokens = 200,
        .messages = .{.{ .role = "user", .content = prompt }},
    }, .{});
    const s = try app.upstream.post(req, "/chat/completions", req_body, &.{});
    defer s.close();
    const raw = try s.reader.allocRemaining(req.arena, .limited(1024 * 1024));
    if (s.status >= 300) return error.UpstreamFailed;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, req.arena, raw, .{});
    if (v.object.get("usage")) |u| if (u == .object) {
        const usage = openrouter.parseUsage(u.object);
        const c = try billing.charge(app, req, who.user_id, .{ .kind = "followups", .model = app.cfg.utility_model, .prompt_tokens = usage.prompt_tokens, .completion_tokens = usage.completion_tokens, .cost_usd = usage.cost_usd, .session = body.session });
        // Counted in the conversation's cost, not its context window.
        try sink.send("usage", .{ .kind = "followups", .model = app.cfg.utility_model, .prompt_tokens = usage.prompt_tokens, .completion_tokens = usage.completion_tokens, .cached_tokens = 0, .cache_write_tokens = 0, .charged_micros = c.charged_micros });
    };
    const content = v.object.get("choices").?.array.items[0].object.get("message").?.object.get("content").?.string;
    const start = std.mem.indexOfScalar(u8, content, '[') orelse return;
    const end = std.mem.lastIndexOfScalar(u8, content, ']') orelse return;
    if (end <= start) return;
    const list = std.json.parseFromSliceLeaky([]const []const u8, req.arena, content[start .. end + 1], .{}) catch return;
    try sink.send("followups", .{ .questions = list[0..@min(list.len, 3)] });
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    app.group("/v1", .{auth.Authenticate{ .app = state }}).post("/chat/stream", stream);
}

test buildBody {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Msg{ .{ .role = "user", .content = "hi" }, .{ .role = "assistant", .content = "hello" }, .{ .role = "user", .content = "again" } };
    const anthropic = try buildBody(a, "anthropic/claude-haiku-5.5", .search, true, &msgs, "5m", "exa");
    // System and last message carry breakpoints; the middle one does not.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, anthropic, "cache_control"));
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"plugins\":[{\"id\":\"web\"") != null);
    const openai = try buildBody(a, "openai/gpt-6.1-sol", .chat, true, &msgs, "5m", "exa");
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, openai, "cache_control"));
    // The prefix (everything before the messages) is identical across turns.
    const turn2 = try buildBody(a, "openai/gpt-6.1-sol", .chat, true, msgs[0..1], "5m", "exa");
    const cut = std.mem.indexOf(u8, openai, "\"role\":\"user\"").?;
    try std.testing.expectEqualStrings(openai[0..cut], turn2[0..cut]);
}

test readableText {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = try readableText(arena.allocator(), "<html><head><style>x{}</style><script>var a=1</script></head><body><h1>Hi</h1>\n<p>there  you</p></body></html>", 100);
    try std.testing.expectEqualStrings("Hi there you", text);
}
