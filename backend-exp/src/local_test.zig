//! Local mode (local.zig) in memory: the launch token, local models on the
//! server the app names, side jobs on a local model or skipped, and web
//! search without OpenRouter.
const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");
const openrouter = app_main.openrouter;
const config = app_main.config;
const local = app_main.local;
const local_models = app_main.local_models;

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
        self.state.local_models.deinit(self.state.gpa);
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
    env.state.local_control = Servers.control;
    Servers.reset();
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

// ------------------------------------------------------------------ model states

/// Ollama on :11434 and LM Studio on :1234, answered in memory: what each call
/// asked for, and which models each server holds.
const Servers = struct {
    var calls: [16][256]u8 = undefined;
    var call_lens: [16]usize = undefined;
    var n: usize = 0;
    var ollama_loaded: [4][]const u8 = undefined;
    var ollama_n: usize = 0;
    var fail_next: bool = false;

    fn reset() void {
        n = 0;
        ollama_n = 0;
        fail_next = false;
    }

    fn record(url: []const u8, body: ?[]const u8) void {
        const line = std.fmt.bufPrint(&calls[n], "{s} {s}", .{ url, body orelse "" }) catch calls[n][0..0];
        call_lens[n] = line.len;
        n += 1;
    }

    fn call(i: usize) []const u8 {
        return calls[i][0..call_lens[i]];
    }

    fn control(_: std.Io, arena: std.mem.Allocator, _: anole.http.Method, url: []const u8, body: ?[]const u8, _: []const u8, _: u32) anyerror!local_models.Reply {
        record(url, body);
        if (fail_next) {
            fail_next = false;
            return .{ .status = 500, .body = "{\"error\":\"out of memory\"}" };
        }
        if (std.mem.endsWith(u8, url, "/api/ps")) {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(arena, "{\"models\":[");
            for (ollama_loaded[0..ollama_n], 0..) |m, i| try out.print(arena, "{s}{{\"name\":\"{s}\"}}", .{ if (i > 0) "," else "", m });
            try out.appendSlice(arena, "]}");
            return .{ .status = 200, .body = out.items };
        }
        if (std.mem.endsWith(u8, url, "/api/v0/models"))
            return .{ .status = 200, .body = "{\"data\":[{\"id\":\"qwen3-coder\",\"state\":\"loaded\"},{\"id\":\"gemma\",\"state\":\"not-loaded\"}]}" };
        return .{ .status = 200, .body = "{}" };
    }
};

const Listed = struct {
    models: []const struct { kind: []const u8, base_url: []const u8, name: []const u8, state: []const u8, ours: bool, reason: ?[]const u8 = null, controllable: bool },
};

fn find(list: Listed, name: []const u8) ?@TypeOf(list.models[0]) {
    for (list.models) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

const auth_only = [_][2][]const u8{.{ local.token_header, token }};

test "load and unload on Ollama: states, ours, and unload_ours at quit" {
    var env: Env = undefined;
    try start(&env, &.{answer}, true);
    defer env.deinit();
    const target = .{ .kind = "ollama", .base_url = "http://127.0.0.1:11434/v1", .name = "qwen3:8b" };
    var res = try env.t.post("/v1/local/models/load", .{ .headers = &auth_only, .json = target });
    defer res.deinit();
    try res.expectStatus(.ok);
    try std.testing.expect(hasText(res.body, "\"state\":\"loaded\"") and hasText(res.body, "\"ours\":true"));
    // The server is asked first whether it holds it already, then told to load it.
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/api/ps ", Servers.call(0));
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/api/generate {\"model\":\"qwen3:8b\",\"keep_alive\":\"30m\",\"stream\":false}", Servers.call(1));

    // Loading it again calls nothing.
    var again = try env.t.post("/v1/local/models/load", .{ .headers = &auth_only, .json = target });
    defer again.deinit();
    try again.expectStatus(.ok);
    try std.testing.expectEqual(@as(usize, 2), Servers.n);

    var ours = try env.t.post("/v1/local/models/unload_ours", .{ .headers = &auth_only });
    defer ours.deinit();
    try ours.expectStatus(.ok);
    try std.testing.expectEqualStrings("{\"unloaded\":[\"qwen3:8b\"],\"failed\":[]}", ours.body);
    try std.testing.expect(hasText(Servers.call(2), "\"keep_alive\":0"));

    // A failed unload keeps the reason and shows as failed.
    var load2 = try env.t.post("/v1/local/models/load", .{ .headers = &auth_only, .json = target });
    defer load2.deinit();
    Servers.fail_next = true;
    var bad = try env.t.post("/v1/local/models/unload", .{ .headers = &auth_only, .json = target });
    defer bad.deinit();
    try bad.expectStatus(.bad_gateway);
    try std.testing.expect(hasText(bad.body, "\"code\":\"unload_failed\"") and hasText(bad.body, "out of memory") and hasText(bad.body, "\"state\":\"failed\""));
}

test "a model the user loaded is seen, not claimed: Load and a chat turn leave it out of unload_ours" {
    var env: Env = undefined;
    try start(&env, &.{answer}, true);
    defer env.deinit();
    Servers.ollama_loaded[0] = "qwen3:8b";
    Servers.ollama_n = 1;
    const target = .{ .kind = "ollama", .base_url = "http://127.0.0.1:11434/v1", .name = "qwen3:8b" };
    var res = try env.t.post("/v1/local/models/load", .{ .headers = &auth_only, .json = target });
    defer res.deinit();
    try res.expectStatus(.ok);
    try std.testing.expect(hasText(res.body, "\"state\":\"loaded\"") and hasText(res.body, "\"ours\":false"));
    // Only the check: no load call.
    try std.testing.expectEqual(@as(usize, 1), Servers.n);

    // A chat turn on another model the user holds: not claimed either.
    Servers.ollama_loaded[1] = "llama3.2:3b";
    Servers.ollama_n = 2;
    const headers = on_server ++ [_][2][]const u8{.{ local_models.kind_header, "ollama" }};
    var chat = try env.t.post("/v1/chat/stream", .{
        .headers = &headers,
        .json = .{ .model = "local/llama3.2:3b", .messages = .{.{ .role = "user", .content = "hi" }}, .tools_enabled = false },
    });
    defer chat.deinit();
    try chat.expectStatus(.ok);

    var ours = try env.t.post("/v1/local/models/unload_ours", .{ .headers = &auth_only });
    defer ours.deinit();
    try std.testing.expectEqualStrings("{\"unloaded\":[],\"failed\":[]}", ours.body);
    for (0..Servers.n) |i| try std.testing.expect(!hasText(Servers.call(i), "/api/generate"));
}

test "LM Studio: load/unload calls, and the list reconciles with what each server holds" {
    var env: Env = undefined;
    try start(&env, &.{answer}, true);
    defer env.deinit();
    var res = try env.t.post("/v1/local/models/load", .{ .headers = &auth_only, .json = .{ .kind = "lmstudio", .base_url = "http://127.0.0.1:1234/v1", .name = "gemma" } });
    defer res.deinit();
    try res.expectStatus(.ok);
    try std.testing.expectEqualStrings("http://127.0.0.1:1234/api/v0/models ", Servers.call(0));
    try std.testing.expectEqualStrings("http://127.0.0.1:1234/api/v1/models/load {\"model\":\"gemma\"}", Servers.call(1));
    var un = try env.t.post("/v1/local/models/unload", .{ .headers = &auth_only, .json = .{ .kind = "lmstudio", .base_url = "http://127.0.0.1:1234/v1", .name = "gemma" } });
    defer un.deinit();
    try un.expectStatus(.ok);
    try std.testing.expectEqualStrings("http://127.0.0.1:1234/api/v1/models/unload {\"instance_id\":\"gemma\"}", Servers.call(2));

    // Ollama, named in the query, holds a model nobody here loaded.
    Servers.ollama_loaded[0] = "llama3.2:3b";
    Servers.ollama_n = 1;
    var list = try env.t.get("/v1/local/models?server=ollama%7Chttp%3A%2F%2F127.0.0.1%3A11434%2Fv1&server=ollama%7Chttp%3A%2F%2F10.1.1.1%3A11434", .{ .headers = &auth_only });
    defer list.deinit();
    try list.expectStatus(.ok);
    const got = try list.json(Listed);
    const llama = find(got, "llama3.2:3b").?;
    try std.testing.expectEqualStrings("loaded", llama.state);
    try std.testing.expect(!llama.ours and llama.controllable);
    const coder = find(got, "qwen3-coder").?;
    try std.testing.expectEqualStrings("loaded", coder.state);
    try std.testing.expectEqualStrings("unloaded", find(got, "gemma").?.state);
    // The LAN server in the query was never asked.
    for (0..Servers.n) |i| try std.testing.expect(!hasText(Servers.call(i), "10.1.1.1"));

    // The server let it go: the next list says so.
    Servers.ollama_n = 0;
    var later = try env.t.get("/v1/local/models", .{ .headers = &auth_only });
    defer later.deinit();
    try std.testing.expectEqualStrings("unloaded", find(try later.json(Listed), "llama3.2:3b").?.state);
}

test "other kinds can't be loaded (409) and LAN URLs are refused" {
    var env: Env = undefined;
    try start(&env, &.{answer}, true);
    defer env.deinit();
    var fm = try env.t.post("/v1/local/models/load", .{ .headers = &auth_only, .json = .{ .kind = "fm", .base_url = "http://127.0.0.1:40001/v1", .name = "system" } });
    defer fm.deinit();
    try fm.expectStatus(.conflict);
    try std.testing.expect(hasText(fm.body, "\"code\":\"unsupported\""));
    var lan = try env.t.post("/v1/local/models/load", .{ .headers = &auth_only, .json = .{ .kind = "ollama", .base_url = "http://192.168.1.9:11434/v1", .name = "x" } });
    defer lan.deinit();
    try lan.expectStatus(.unprocessable_entity);
    try std.testing.expectEqual(@as(usize, 0), Servers.n);
}

test "the model and shutdown routes don't exist off local mode" {
    var off: Env = undefined;
    try start(&off, &.{answer}, false);
    defer off.deinit();
    var none = try off.t.get("/v1/local/models", .{});
    defer none.deinit();
    try none.expectStatus(.not_found);
    var nope = try off.t.post("/v1/local/shutdown", .{});
    defer nope.deinit();
    try nope.expectStatus(.not_found);
}

test "a chat turn on a local model marks it loaded and ours; Apple's model gets no tools" {
    var env: Env = undefined;
    try start(&env, &.{ answer, answer }, true);
    defer env.deinit();
    const headers = on_server ++ [_][2][]const u8{.{ local_models.kind_header, "ollama" }};
    var res = try env.t.post("/v1/chat/stream", .{
        .headers = &headers,
        .json = .{ .model = "local/qwen3:8b", .messages = .{.{ .role = "user", .content = "hi" }}, .tools_enabled = false },
    });
    defer res.deinit();
    try res.expectStatus(.ok);
    // The server reports it held (a list reconciles with it).
    Servers.ollama_loaded[0] = "qwen3:8b";
    Servers.ollama_n = 1;
    var list2 = try env.t.get("/v1/local/models", .{ .headers = &auth_only });
    defer list2.deinit();
    const q = find(try list2.json(Listed), "qwen3:8b").?;
    try std.testing.expectEqualStrings("loaded", q.state);
    try std.testing.expect(q.ours);

    const fm_headers = [_][2][]const u8{
        .{ local.token_header, token },
        .{ local.base_header, "http://127.0.0.1:40001/v1" },
        .{ local.caps_header, "tools" },
        .{ local_models.kind_header, "fm" },
    };
    var fm = try env.t.post("/v1/chat/stream", .{
        .headers = &fm_headers,
        .json = .{ .model = "local/system", .messages = .{.{ .role = "user", .content = "hi" }}, .tools_enabled = true },
    });
    defer fm.deinit();
    try fm.expectStatus(.ok);
    const sent = env.lan.bodies.items[env.lan.bodies.items.len - 1];
    try std.testing.expect(hasText(sent, "\"model\":\"system\""));
    try std.testing.expect(!hasText(sent, "\"tools\"") and !hasText(sent, "tool_choice"));
}
