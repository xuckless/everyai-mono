//! Local mode (local.zig) in memory: the launch token, local models on the
//! server the app names, side jobs on a local model or skipped, and web
//! search without OpenRouter.
const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");
const openrouter = app_main.openrouter;
const config = app_main.config;
const local = app_main.local;

const alloc = std.testing.allocator;
const Server = anole.Server(app_main.App);
const token = "local-token-0123456789abcdef";

const Env = struct {
    state: app_main.App,
    /// OpenRouter: must never be called in these tests.
    fake: openrouter.Fake,
    /// The local server the app names.
    lan: openrouter.Fake,
    server: Server,
    t: anole.testing.Client(Server),

    fn deinit(self: *Env) void {
        self.t.deinit();
        self.server.deinit();
        self.state.limiter.deinit();
        self.state.global_limiter.deinit();
        self.state.catalog.deinit();
        self.state.searches.deinit(self.state.gpa);
        self.fake.deinit();
        self.lan.deinit();
    }
};

fn start(env: *Env, lan: []const []const u8, local_mode: bool) !void {
    env.fake = .{ .responses = &.{"{}"}, .gpa = alloc };
    env.lan = .{ .responses = lan, .gpa = alloc };
    var cfg: config.Config = .{
        .jwt_secret = .init("test-secret-0123456789abcdef0123456789"),
        .openrouter_api_key = null,
        .dev_auth = true,
        .local_mode = local_mode,
    };
    if (local_mode) cfg.local_token = .init(token);
    env.state = .{
        .gpa = alloc,
        .cfg = cfg,
        .db = undefined,
        .jwt_keys = .{.{ .kid = "k1", .alg = .HS256, .material = .{ .hmac = cfg.jwt_secret.?.expose() } }},
        .upstream = env.fake.upstream(),
        .catalog = .init(alloc),
    };
    env.state.local_transport = env.lan.upstream();
    env.state.search_fake = fakeSearch;
    env.server = try Server.init(alloc, .{ .executors = .exact(2), .limits = .{ .body_max = app_main.body_max } }, &env.state);
    env.state.db = try env.server.sqlite(":memory:");
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    try app_main.prepare(&env.state, &c);
    try app_main.routes(&env.server, &env.state);
    env.t = try anole.testing.client(&env.server);
}

fn fakeSearch(arena: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    if (std.mem.startsWith(u8, url, "https://html.duckduckgo.com/html/?q=")) return arena.dupe(u8, local.ddg_fixture);
    if (std.mem.startsWith(u8, url, "https://api.search.brave.com/"))
        return arena.dupe(u8, "{\"web\":{\"results\":[{\"url\":\"https://brave.example/r\",\"title\":\"Brave hit\",\"description\":\"b\"}]}}");
    return error.Unexpected;
}

const answer =
    \\data: {"choices":[{"index":0,"delta":{"content":"Hello from the local model."}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":40,"completion_tokens":6}}
    \\
    \\data: [DONE]
    \\
    \\
;

const search_call =
    \\data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_s","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"zig release\",\"max_results\":3}"}}]}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":9}}
    \\
    \\data: [DONE]
    \\
    \\
;

const followups =
    \\{"choices":[{"message":{"role":"assistant","content":"[\"One?\", \"Two?\", \"Three?\"]"}}],"usage":{"prompt_tokens":10,"completion_tokens":5}}
;

const on_server = [_][2][]const u8{
    .{ local.token_header, token },
    .{ local.base_header, "http://127.0.0.1:11434/v1" },
    .{ local.caps_header, "reasoning" },
    .{ local.context_header, "8192" },
};

fn hasText(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "local mode: every route but the probes needs the launch token" {
    var env: Env = undefined;
    try start(&env, &.{answer}, true);
    defer env.deinit();
    var ping = try env.t.get("/v1/ping", .{});
    defer ping.deinit();
    try ping.expectStatus(.ok);
    var none = try env.t.get("/v1/me", .{});
    defer none.deinit();
    try none.expectStatus(.unauthorized);
    var wrong = try env.t.get("/v1/me", .{ .headers = &.{.{ local.token_header, "local-token-0123456789abcdeX" }} });
    defer wrong.deinit();
    try wrong.expectStatus(.unauthorized);
    var right = try env.t.get("/v1/me", .{ .headers = &.{.{ local.token_header, token }} });
    defer right.deinit();
    try right.expectStatus(.ok);
}

test "local model: runs on the named server under its own name, without tools, never charged" {
    var env: Env = undefined;
    try start(&env, &.{answer}, true);
    defer env.deinit();
    var res = try env.t.post("/v1/chat/stream", .{
        .headers = &on_server,
        .json = .{ .model = "local/qwen3:8b", .messages = .{.{ .role = "user", .content = "hi" }}, .tools_enabled = true, .session = "s-local" },
    });
    defer res.deinit();
    try res.expectStatus(.ok);
    try std.testing.expect(hasText(res.body, "Hello from the local model."));
    // No side-job model named: no follow-ups, and OpenRouter is never called.
    try std.testing.expect(!hasText(res.body, "event: followups"));
    try std.testing.expectEqual(@as(usize, 0), env.fake.bodies.items.len);
    try std.testing.expectEqual(@as(usize, 1), env.lan.bodies.items.len);
    const sent = env.lan.bodies.items[0];
    try std.testing.expect(hasText(sent, "\"model\":\"qwen3:8b\""));
    try std.testing.expect(!hasText(sent, "\"tools\""));
    try std.testing.expect(!hasText(sent, "\"usage\"") and !hasText(sent, "cache_control"));

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    const rows = try env.state.db.all(struct { provider: []const u8, charged_micros: i64 }, &c, "SELECT provider, charged_micros FROM usage_events", .{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("local", rows[0].provider);
    try std.testing.expectEqual(@as(i64, 0), rows[0].charged_micros);
}

test "local model: the side-job model writes follow-ups; a missing server is a clear 422" {
    var env: Env = undefined;
    try start(&env, &.{ answer, followups }, true);
    defer env.deinit();
    var headers = on_server ++ [_][2][]const u8{
        .{ local.aux_model_header, "local/llama3.2:3b" },
        .{ local.aux_base_header, "http://127.0.0.1:11434/v1" },
    };
    var res = try env.t.post("/v1/chat/stream", .{
        .headers = &headers,
        .json = .{ .model = "local/qwen3:8b", .messages = .{.{ .role = "user", .content = "hi" }}, .tools_enabled = false },
    });
    defer res.deinit();
    try res.expectStatus(.ok);
    try std.testing.expect(hasText(res.body, "event: followups"));
    try std.testing.expectEqual(@as(usize, 2), env.lan.bodies.items.len);
    try std.testing.expect(hasText(env.lan.bodies.items[1], "\"model\":\"llama3.2:3b\""));

    var bad = try env.t.post("/v1/chat/stream", .{
        .headers = &.{.{ local.token_header, token }},
        .json = .{ .model = "local/qwen3:8b", .messages = .{.{ .role = "user", .content = "hi" }} },
    });
    defer bad.deinit();
    try bad.expectStatus(.unprocessable_entity);
}

test "Search without tools on a local model: the question is searched first (keyless)" {
    var env: Env = undefined;
    try start(&env, &.{answer}, true);
    defer env.deinit();
    var res = try env.t.post("/v1/chat/stream", .{
        .headers = &on_server,
        .json = .{ .model = "local/qwen3:8b", .mode = "search", .messages = .{.{ .role = "user", .content = "latest zig" }}, .tools_enabled = true },
    });
    defer res.deinit();
    try res.expectStatus(.ok);
    try std.testing.expect(hasText(res.body, "event: sources"));
    try std.testing.expect(hasText(res.body, "https://ziglang.org/download/"));
    const sent = env.lan.bodies.items[0];
    try std.testing.expect(hasText(sent, "Web results for the question that follows"));
    try std.testing.expect(hasText(sent, "untrusted-content"));
    try std.testing.expect(!hasText(sent, "plugins"));
}

test "web_search on a local model with tools uses the user's search service when named" {
    var env: Env = undefined;
    try start(&env, &.{ search_call, answer }, true);
    defer env.deinit();
    const headers = [_][2][]const u8{
        .{ local.token_header, token },
        .{ local.base_header, "http://127.0.0.1:1234/v1" },
        .{ local.caps_header, "tools" },
        .{ local.brave_header, "brave-key-0123456789" },
    };
    var res = try env.t.post("/v1/chat/stream", .{
        .headers = &headers,
        .json = .{ .model = "local/qwen3-coder", .messages = .{.{ .role = "user", .content = "zig news" }}, .tools_enabled = true },
    });
    defer res.deinit();
    try res.expectStatus(.ok);
    try std.testing.expect(hasText(res.body, "https://brave.example/r"));
    try std.testing.expect(hasText(env.lan.bodies.items[0], "\"tools\""));
    try std.testing.expect(hasText(env.lan.bodies.items[1], "Brave hit"));
    try std.testing.expectEqual(@as(usize, 0), env.fake.bodies.items.len);
}

test "the deployed server ignores local headers" {
    var env: Env = undefined;
    try start(&env, &.{answer}, false);
    defer env.deinit();
    var res = try env.t.post("/v1/chat/stream", .{
        .headers = &.{.{ local.base_header, "http://127.0.0.1:11434/v1" }},
        .json = .{ .model = "local/qwen3:8b", .messages = .{.{ .role = "user", .content = "hi" }}, .tools_enabled = false },
    });
    defer res.deinit();
    // No OpenRouter key and none of the user's: the usual "add a key".
    try res.expectStatus(.bad_request);
    try std.testing.expectEqual(@as(usize, 0), env.lan.bodies.items.len);
}
