//! Local mode: this server bundled in the app as a loopback sidecar, for chats
//! on the user's local models (Ollama, Apple `fm serve`, LM Studio, llama.cpp …)
//! and on their own keys. Off on the deployed server, which ignores every
//! header below.
//!
//! - `LOCAL_MODE=true` needs `LOCAL_TOKEN` and a loopback `HOST`; every route
//!   but the probes needs `X-EveryAI-Local: <token>` ([Guard]). Nothing is charged.
//! - A model id `local/<name>` runs on the OpenAI-compatible server the app
//!   names per request: `X-Local-Base-Url` (e.g. `http://127.0.0.1:11434/v1`),
//!   optional `X-Local-Api-Key`, `X-Local-Caps` (`tools,vision,reasoning`) and
//!   `X-Local-Context` (tokens). `<name>` (it may hold `/` or `:`) is what the
//!   server is asked for.
//! - Side jobs with no OpenRouter key: `X-Local-Aux-Model` (`local/<name>`),
//!   `X-Local-Aux-Base-Url`, optional `X-Local-Aux-Api-Key`; without them the
//!   jobs are skipped.
//! - Web search with no OpenRouter key: Brave (`X-Search-Brave-Key`), Tavily
//!   (`X-Search-Tavily-Key`) or SearXNG (`X-Search-Searxng-Url`), the first one
//!   sent, else DuckDuckGo's HTML results (keyless; see [parseDuckDuckGo]).
const std = @import("std");
const anole = @import("anole");
const openrouter = @import("openrouter.zig");
const models = @import("models.zig");
const config = @import("config.zig");
const safe_fetch = @import("net/safe_fetch.zig");

pub const token_header = "X-EveryAI-Local";
pub const base_header = "X-Local-Base-Url";
pub const key_header = "X-Local-Api-Key";
pub const caps_header = "X-Local-Caps";
pub const context_header = "X-Local-Context";
pub const aux_model_header = "X-Local-Aux-Model";
pub const aux_base_header = "X-Local-Aux-Base-Url";
pub const aux_key_header = "X-Local-Aux-Api-Key";
pub const brave_header = "X-Search-Brave-Key";
pub const tavily_header = "X-Search-Tavily-Key";
pub const searxng_header = "X-Search-Searxng-Url";

pub const prefix = "local/";

pub fn isLocalId(model: []const u8) bool {
    return std.mem.startsWith(u8, model, prefix) and model.len > prefix.len;
}

/// Why local mode can't start with `cfg`, or null when it can (or is off).
pub fn startProblem(cfg: config.Config) ?[]const u8 {
    if (!cfg.local_mode) return null;
    if (cfg.local_token == null or cfg.local_token.?.expose().len < 16) return "LOCAL_MODE needs LOCAL_TOKEN (16+ characters)";
    if (!config.isLoopback(cfg.host)) return "LOCAL_MODE serves loopback only: set HOST=127.0.0.1";
    if (cfg.tls_cert_path != null) return "LOCAL_MODE serves plain HTTP on loopback; unset TLS_CERT_PATH";
    return null;
}

/// Every route but the probes needs the launch token: other programs and web
/// pages on this computer can reach loopback too.
pub const Guard = struct {
    token: []const u8,

    pub const no_wait = true;

    pub fn execute(self: *const Guard, req: *anole.Request, res: *anole.Response, next: anytype) !void {
        const path = if (std.mem.indexOfScalar(u8, req.url, '?')) |q| req.url[0..q] else req.url;
        if (std.mem.eql(u8, path, "/v1/ping") or std.mem.eql(u8, path, "/readyz") or std.mem.eql(u8, path, "/healthz"))
            return next.call();
        const got = req.headers.get(token_header) orelse "";
        if (!sameSecret(got, self.token)) {
            res.status = .unauthorized;
            return res.json(.{ .message = "This local server only answers the EveryAI app.", .code = "local_token" });
        }
        return next.call();
    }
};

/// Constant-time over the digests, so neither length nor content leaks.
fn sameSecret(a: []const u8, b: []const u8) bool {
    var da: [32]u8 = undefined;
    var db: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(a, &da, .{});
    std.crypto.hash.sha2.Sha256.hash(b, &db, .{});
    return std.crypto.timing_safe.eql([32]u8, da, db) and a.len > 0;
}

/// An OpenAI-compatible server the app named.
pub const Server = struct { base_url: []const u8, api_key: []const u8 = "" };

pub const Which = enum { chat, aux };

/// The server for this request's local model (or side jobs), when the app sent
/// a usable one: http(s), no control characters, no trailing slash.
pub fn serverOf(req: *anole.Request, which: Which) ?Server {
    const base = cleanUrl(req.headers.get(if (which == .chat) base_header else aux_base_header)) orelse return null;
    const key = req.headers.get(if (which == .chat) key_header else aux_key_header) orelse "";
    return .{ .base_url = base, .api_key = if (printable(key)) key else "" };
}

pub fn cleanUrl(raw: ?[]const u8) ?[]const u8 {
    var u = std.mem.trim(u8, raw orelse return null, " \t");
    while (u.len > 0 and u[u.len - 1] == '/') u = u[0 .. u.len - 1];
    if (u.len < 10 or u.len > 512 or !printable(u)) return null;
    if (!std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://")) return null;
    _ = std.Uri.parse(u) catch return null;
    return u;
}

fn printable(s: []const u8) bool {
    for (s) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// The side-job model the app named (`local/<name>`), when it also named its server.
pub fn auxModel(req: *anole.Request) ?[]const u8 {
    const m = std.mem.trim(u8, req.headers.get(aux_model_header) orelse return null, " \t");
    if (!isLocalId(m) or m.len > 256) return null;
    return m;
}

/// What the app says the local model can do.
pub const Caps = struct {
    tools: bool = false,
    vision: bool = false,
    reasoning: bool = false,
    context: ?i64 = null,
};

pub fn capsOf(req: *anole.Request) Caps {
    var caps: Caps = .{};
    var it = std.mem.tokenizeAny(u8, req.headers.get(caps_header) orelse "", ", ");
    while (it.next()) |c| {
        if (std.ascii.eqlIgnoreCase(c, "tools")) caps.tools = true;
        if (std.ascii.eqlIgnoreCase(c, "vision")) caps.vision = true;
        if (std.ascii.eqlIgnoreCase(c, "reasoning")) caps.reasoning = true;
    }
    if (req.headers.get(context_header)) |raw| caps.context = std.fmt.parseInt(i64, std.mem.trim(u8, raw, " "), 10) catch null;
    return caps;
}

/// The catalog facts of a local model: free, tools/vision/reasoning as told.
pub fn facts(caps: Caps) models.Catalog.Facts {
    return .{
        .known = true,
        .free = true,
        .tools = caps.tools,
        .web_search = false,
        .reasoning = caps.reasoning,
        .max_output = if (caps.context) |c| @max(0, @divTrunc(c, 4)) else 0,
        .inputs = .{ .image = caps.vision, .file = false, .audio = false },
    };
}

// ------------------------------------------------------------------ upstream

/// Asks the local server for `model` (the name without `local/`) whatever the
/// body says, and drops what only OpenRouter understands (plugins, provider
/// routing, `usage.include`, cache breakpoints, reasoning blocks).
pub const Rewrite = struct {
    inner: openrouter.Upstream,
    model: []const u8,

    pub fn upstream(self: *Rewrite) openrouter.Upstream {
        return .{ .ptr = self, .vtable = &.{ .post = post, .get = get } };
    }

    fn post(ptr: *anyopaque, cx: openrouter.Ctx, path: []const u8, body: []const u8, extra: []const [2][]const u8) anyerror!openrouter.Stream {
        const self: *Rewrite = @ptrCast(@alignCast(ptr));
        return self.inner.post(cx, path, try rewriteBody(cx.arena, body, self.model), extra);
    }

    fn get(ptr: *anyopaque, io: std.Io, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        const self: *Rewrite = @ptrCast(@alignCast(ptr));
        return self.inner.get(io, arena, path);
    }
};

/// `model` without the `local/` prefix.
pub fn nameOf(model: []const u8) []const u8 {
    return if (isLocalId(model)) model[prefix.len..] else model;
}

pub fn rewriteBody(arena: std.mem.Allocator, body: []const u8, model: []const u8) ![]const u8 {
    var v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return body;
    if (v != .object) return body;
    const o = &v.object;
    try o.put(arena, "model", .{ .string = nameOf(model) });
    inline for (.{ "plugins", "provider", "usage", "transforms", "models", "route", "fallbacks" }) |k| _ = o.orderedRemove(k);
    if (o.get("reasoning")) |r| {
        if (r == .object) if (r.object.get("effort")) |e| if (e == .string) try o.put(arena, "reasoning_effort", e);
        _ = o.orderedRemove("reasoning");
    }
    if (o.get("stream")) |s| if (s == .bool and s.bool) {
        var opts: std.json.ObjectMap = .empty;
        try opts.put(arena, "include_usage", .{ .bool = true });
        try o.put(arena, "stream_options", .{ .object = opts });
    };
    if (o.getPtr("messages")) |msgs| if (msgs.* == .array) for (msgs.array.items) |*m| {
        if (m.* != .object) continue;
        inline for (.{ "cache_control", "reasoning", "reasoning_details" }) |k| _ = m.object.orderedRemove(k);
        if (m.object.getPtr("content")) |c| if (c.* == .array) for (c.array.items) |*part| {
            if (part.* == .object) _ = part.object.orderedRemove("cache_control");
        };
    };
    return std.json.Stringify.valueAlloc(arena, v, .{});
}

// ------------------------------------------------------------------ search

/// Which keyless or keyed engine a search goes to.
pub const Engine = union(enum) {
    brave: []const u8,
    tavily: []const u8,
    searxng: []const u8,
    duckduckgo,
};

pub fn engineOf(req: *anole.Request) Engine {
    if (clean(req.headers.get(brave_header))) |k| return .{ .brave = k };
    if (clean(req.headers.get(tavily_header))) |k| return .{ .tavily = k };
    if (cleanUrl(req.headers.get(searxng_header))) |u| return .{ .searxng = u };
    return .duckduckgo;
}

fn clean(raw: ?[]const u8) ?[]const u8 {
    const k = std.mem.trim(u8, raw orelse return null, " \t");
    if (k.len < 8 or k.len > 512 or !printable(k)) return null;
    return k;
}

/// Tests: answers a search without the network (the raw reply body for the
/// engine's URL).
pub const SearchFake = *const fn (arena: std.mem.Allocator, url: []const u8) anyerror![]const u8;

/// Runs `query` on `engine`, at most `limit` results. DuckDuckGo goes through
/// `fetcher` (no private addresses, every hop checked); the keyed engines are
/// the user's own services, SearXNG possibly on this computer.
pub fn search(io: std.Io, arena: std.mem.Allocator, fetcher: ?*const safe_fetch.Fetcher, fake: ?SearchFake, engine: Engine, query: []const u8, limit: usize) ![]const openrouter.Source {
    const q = try percentEncode(arena, query);
    switch (engine) {
        .duckduckgo => {
            const url = try std.fmt.allocPrint(arena, "https://html.duckduckgo.com/html/?q={s}", .{q});
            const raw = if (fake) |f| try f(arena, url) else blk: {
                const f = fetcher orelse return error.SearchUnavailable;
                const page = try f.get(io, arena, url, "text/html", null);
                if (page.status >= 300) return error.SearchFailed;
                break :blk page.body;
            };
            return parseDuckDuckGo(arena, raw, limit);
        },
        .brave => |key| {
            const url = try std.fmt.allocPrint(arena, "https://api.search.brave.com/res/v1/web/search?q={s}&count={d}", .{ q, limit });
            const raw = if (fake) |f| try f(arena, url) else try fetchJson(io, arena, url, .get, &.{ .{ "Accept", "application/json" }, .{ "X-Subscription-Token", key } }, null);
            return parseBrave(arena, raw, limit);
        },
        .tavily => |key| {
            const url = "https://api.tavily.com/search";
            const body = try std.json.Stringify.valueAlloc(arena, .{ .query = query, .max_results = limit }, .{});
            const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{key});
            const raw = if (fake) |f| try f(arena, url) else try fetchJson(io, arena, url, .post, &.{ .{ "Content-Type", "application/json" }, .{ "Authorization", auth } }, body);
            return parseTavily(arena, raw, limit);
        },
        .searxng => |base| {
            const url = try std.fmt.allocPrint(arena, "{s}/search?q={s}&format=json", .{ base, q });
            const raw = if (fake) |f| try f(arena, url) else try fetchJson(io, arena, url, .get, &.{.{ "Accept", "application/json" }}, null);
            return parseSearxng(arena, raw, limit);
        },
    }
}

fn fetchJson(io: std.Io, arena: std.mem.Allocator, url: []const u8, method: anole.http.Method, headers: []const [2][]const u8, body: ?[]const u8) ![]const u8 {
    var h = try anole.http.Headers.init(arena, headers.len);
    for (headers) |kv| try h.put(kv[0], kv[1]);
    var res = try anole.client(io).http.fetch(url, .{ .method = method, .headers = &h, .body = body });
    defer res.deinit();
    const status: u16 = @intCast(@backingInt(res.status()));
    if (status >= 300) return error.SearchFailed;
    return arena.dupe(u8, (try res.body()) orelse "");
}

fn percentEncode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(arena, c);
        } else if (c == ' ') {
            try out.append(arena, '+');
        } else try out.print(arena, "%{X:0>2}", .{c});
    }
    return out.items;
}

/// Results from DuckDuckGo's HTML page: each `result__a` link (its `uddg`
/// redirect decoded to the real URL) with the `result__snippet` after it.
/// Ads (`y.js` links) are skipped.
pub fn parseDuckDuckGo(arena: std.mem.Allocator, html: []const u8, limit: usize) ![]const openrouter.Source {
    var out: std.ArrayList(openrouter.Source) = .empty;
    var rest = html;
    while (out.items.len < limit) {
        const at = std.mem.indexOf(u8, rest, "class=\"result__a\"") orelse break;
        // The anchor's start: back to its `<a`.
        const open = std.mem.lastIndexOf(u8, rest[0..at], "<a") orelse {
            rest = rest[at + 1 ..];
            continue;
        };
        const tag_end = std.mem.indexOfScalarPos(u8, rest, at, '>') orelse break;
        const tag = rest[open..tag_end];
        const close = std.mem.indexOfPos(u8, rest, tag_end, "</a>") orelse break;
        const title = try textOf(arena, rest[tag_end + 1 .. close]);
        const href = attr(tag, "href") orelse "";
        rest = rest[close + 4 ..];
        const url = try resultUrl(arena, href) orelse continue;
        var snippet: ?[]const u8 = null;
        if (std.mem.indexOf(u8, rest, "class=\"result__snippet\"")) |s_at| {
            const next_result = std.mem.indexOf(u8, rest, "class=\"result__a\"") orelse rest.len;
            if (s_at < next_result) if (std.mem.indexOfScalarPos(u8, rest, s_at, '>')) |s_open| {
                const s_close = std.mem.indexOfPos(u8, rest, s_open, "</a>") orelse std.mem.indexOfPos(u8, rest, s_open, "</") orelse rest.len;
                snippet = try textOf(arena, rest[s_open + 1 .. s_close]);
            };
        }
        try out.append(arena, .{ .url = url, .title = if (title.len > 0) title else url, .snippet = snippet });
    }
    return out.items;
}

fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "{s}=\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, tag, needle) orelse return null;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
    return tag[start..end];
}

/// The real target of a result link: `//duckduckgo.com/l/?uddg=<encoded>&rut=…`,
/// or a direct http(s) link. Null for ads and anything else.
fn resultUrl(arena: std.mem.Allocator, href_raw: []const u8) !?[]const u8 {
    const href = try entities(arena, href_raw);
    if (std.mem.indexOf(u8, href, "uddg=")) |at| {
        const v = href[at + 5 ..];
        const end = std.mem.indexOfScalar(u8, v, '&') orelse v.len;
        const url = try safe_fetch.percentDecoded(arena, v[0..end]);
        if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) return url;
        return null;
    }
    if (std.mem.indexOf(u8, href, "duckduckgo.com/y.js") != null) return null;
    if (std.mem.startsWith(u8, href, "http://") or std.mem.startsWith(u8, href, "https://")) return href;
    return null;
}

/// Inner text: tags removed, common entities decoded, whitespace collapsed.
fn textOf(arena: std.mem.Allocator, html: []const u8) ![]const u8 {
    var plain: std.ArrayList(u8) = .empty;
    var in_tag = false;
    for (html) |c| {
        if (c == '<') in_tag = true else if (c == '>') in_tag = false else if (!in_tag) try plain.append(arena, c);
    }
    const decoded = try entities(arena, plain.items);
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (std.mem.trim(u8, decoded, " \t\r\n")) |c| {
        if (c == ' ' or c == '\n' or c == '\t' or c == '\r') {
            space = true;
            continue;
        }
        if (space and out.items.len > 0) try out.append(arena, ' ');
        space = false;
        try out.append(arena, c);
    }
    return out.items;
}

fn entities(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    const pairs = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#x27;", "'" }, .{ "&#39;", "'" }, .{ "&nbsp;", " " } };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < s.len) {
        if (s[i] == '&') for (pairs) |p| if (std.mem.startsWith(u8, s[i..], p[0])) {
            try out.appendSlice(arena, p[1]);
            i += p[0].len;
            continue :outer;
        };
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn listOf(arena: std.mem.Allocator, items: []const std.json.Value, limit: usize, url_key: []const u8, title_key: []const u8, snippet_key: []const u8) ![]const openrouter.Source {
    var out: std.ArrayList(openrouter.Source) = .empty;
    for (items) |it| {
        if (out.items.len >= limit) break;
        const url = str(it, url_key) orelse continue;
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) continue;
        const snippet = if (str(it, snippet_key)) |s| try textOf(arena, s) else null;
        try out.append(arena, .{ .url = url, .title = if (str(it, title_key)) |t| try textOf(arena, t) else url, .snippet = snippet });
    }
    return out.items;
}

fn arrayAt(v: std.json.Value, path: []const []const u8) []const std.json.Value {
    var cur = v;
    for (path) |k| {
        if (cur != .object) return &.{};
        cur = cur.object.get(k) orelse return &.{};
    }
    return if (cur == .array) cur.array.items else &.{};
}

pub fn parseBrave(arena: std.mem.Allocator, raw: []const u8, limit: usize) ![]const openrouter.Source {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return error.SearchFailed;
    return listOf(arena, arrayAt(v, &.{ "web", "results" }), limit, "url", "title", "description");
}

pub fn parseTavily(arena: std.mem.Allocator, raw: []const u8, limit: usize) ![]const openrouter.Source {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return error.SearchFailed;
    return listOf(arena, arrayAt(v, &.{"results"}), limit, "url", "title", "content");
}

pub fn parseSearxng(arena: std.mem.Allocator, raw: []const u8, limit: usize) ![]const openrouter.Source {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return error.SearchFailed;
    return listOf(arena, arrayAt(v, &.{"results"}), limit, "url", "title", "content");
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

pub const ddg_fixture =
    \\<div class="result results_links results_links_deep web-result ">
    \\<h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2Fdownload%2F&amp;rut=abc">Download &amp; install <b>Zig</b></a></h2>
    \\<a class="result__snippet" href="//duckduckgo.com/l/?uddg=x">The <b>Zig</b> compiler, 0.17.0.</a>
    \\</div>
    \\<div class="result result--ad"><a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad_domain=ads.example">An ad</a></div>
    \\<div class="result"><h2><a rel="nofollow" class="result__a" href="https://example.org/direct">Direct</a></h2></div>
;

test "DuckDuckGo results: redirects decoded, ads dropped, snippets kept" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const got = try parseDuckDuckGo(a.allocator(), ddg_fixture, 5);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("https://ziglang.org/download/", got[0].url);
    try testing.expectEqualStrings("Download & install Zig", got[0].title);
    try testing.expectEqualStrings("The Zig compiler, 0.17.0.", got[0].snippet.?);
    try testing.expectEqualStrings("https://example.org/direct", got[1].url);
    try testing.expect(got[1].snippet == null);
    try testing.expectEqual(@as(usize, 1), (try parseDuckDuckGo(a.allocator(), ddg_fixture, 1)).len);
}

test "keyed engines parse their replies" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const brave = try parseBrave(a.allocator(), "{\"web\":{\"results\":[{\"url\":\"https://a.io\",\"title\":\"A <strong>x</strong>\",\"description\":\"d\"},{\"url\":\"ftp://no\"}]}}", 5);
    try testing.expectEqual(@as(usize, 1), brave.len);
    try testing.expectEqualStrings("A x", brave[0].title);
    const tav = try parseTavily(a.allocator(), "{\"results\":[{\"url\":\"https://t.io\",\"title\":\"T\",\"content\":\"c\"}]}", 5);
    try testing.expectEqualStrings("c", tav[0].snippet.?);
    const sx = try parseSearxng(a.allocator(), "{\"results\":[{\"url\":\"https://s.io\",\"title\":\"S\"}]}", 5);
    try testing.expectEqualStrings("https://s.io", sx[0].url);
}

test "rewriteBody asks for the local name and drops OpenRouter-only fields" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const out = try rewriteBody(a.allocator(),
        \\{"model":"local/qwen3:8b","stream":true,"usage":{"include":true},"reasoning":{"effort":"high"},"plugins":[{"id":"web"}],
        \\ "messages":[{"role":"system","content":[{"type":"text","text":"s","cache_control":{"type":"ephemeral"}}]},
        \\ {"role":"assistant","content":"x","reasoning_details":[]}]}
    , "local/qwen3:8b");
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), out, .{});
    try testing.expectEqualStrings("qwen3:8b", v.object.get("model").?.string);
    try testing.expect(v.object.get("usage") == null and v.object.get("plugins") == null and v.object.get("reasoning") == null);
    try testing.expectEqualStrings("high", v.object.get("reasoning_effort").?.string);
    try testing.expect(v.object.get("stream_options").?.object.get("include_usage").?.bool);
    const msgs = v.object.get("messages").?.array.items;
    try testing.expect(msgs[0].object.get("content").?.array.items[0].object.get("cache_control") == null);
    try testing.expect(msgs[1].object.get("reasoning_details") == null);
    // A side job's body names the utility model: the local one is asked for instead.
    const aux = try rewriteBody(a.allocator(), "{\"model\":\"google/gemini-3.5-flash-lite\",\"messages\":[]}", "local/llama3.2:3b");
    try testing.expect(std.mem.indexOf(u8, aux, "\"llama3.2:3b\"") != null);
}

test "urls, ids and the start check" {
    try testing.expect(isLocalId("local/qwen/qwen3-coder:30b") and !isLocalId("local/") and !isLocalId("openai/x"));
    try testing.expectEqualStrings("http://127.0.0.1:11434/v1", cleanUrl(" http://127.0.0.1:11434/v1/ ").?);
    try testing.expect(cleanUrl("file:///etc/passwd") == null);
    try testing.expect(cleanUrl("http://x.io/v1\r\nX: 1") == null);
    var cfg: config.Config = .{ .local_mode = true };
    try testing.expect(startProblem(cfg) != null);
    cfg.local_token = .init("0123456789abcdef0123");
    try testing.expect(startProblem(cfg) == null);
    cfg.host = "0.0.0.0";
    try testing.expect(startProblem(cfg) != null);
    try testing.expect(sameSecret("abc", "abc") and !sameSecret("abc", "abd") and !sameSecret("", ""));
    const f = facts(.{ .tools = true, .vision = false, .context = 8192 });
    try testing.expect(f.free and f.tools and !f.inputs.image and f.max_output == 2048);
}
