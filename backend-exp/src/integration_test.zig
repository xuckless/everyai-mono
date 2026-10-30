//! The routes in memory (`anole.testing`) against a fake OpenRouter that
//! serves recorded SSE.
const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");
const openrouter = app_main.openrouter;
const config = @import("app").config;

const alloc = std.testing.allocator;
const Server = anole.Server(app_main.App);

const Env = struct {
    state: app_main.App,
    fake: openrouter.Fake,
    /// Anthropic's API (raw Messages replies), behind the real adapter.
    anth: openrouter.Fake,
    adapter: app_main.anthropic.Adapter,
    server: Server,
    t: anole.testing.Client(Server),

    fn deinit(self: *Env) void {
        self.t.deinit();
        self.server.deinit();
        self.state.catalog.deinit();
        self.fake.deinit();
        self.anth.deinit();
    }
};

fn start(env: *Env, responses: []const []const u8, dev_auth: bool) !void {
    env.fake = .{ .responses = responses, .gpa = alloc, .models_json = models_json };
    env.anth = .{ .responses = &.{""}, .gpa = alloc };
    var cfg: config.Config = .{
        .jwt_secret = .init("test-secret-0123456789abcdef0123456789"),
        .openrouter_api_key = .init("sk-or-test"),
        .dev_auth = dev_auth,
    };
    cfg.max_tool_steps = 4;
    env.state = .{
        .gpa = alloc,
        .cfg = cfg,
        .db = undefined,
        .jwt_keys = .{.{ .kid = "k1", .alg = .HS256, .material = .{ .hmac = cfg.jwt_secret.expose() } }},
        .upstream = env.fake.upstream(),
        .catalog = .init(alloc),
    };
    env.adapter = .{ .inner = env.anth.upstream(), .catalog = &env.state.catalog };
    env.state.anthropic = env.adapter.upstream();
    env.server = try Server.init(alloc, .{ .executors = .exact(2), .limits = .{ .body_max = app_main.body_max } }, &env.state);
    env.state.db = try env.server.sqlite(":memory:");
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    try app_main.prepare(&env.state, &c);
    try app_main.routes(&env.server, &env.state);
    env.t = try anole.testing.client(&env.server);
}

const models_json =
    \\{"data":[
    \\{"id":"anthropic/claude-haiku-5.5","name":"Anthropic: Claude Haiku 5.5","description":"Fast. Small.","context_length":1000000,
    \\ "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
    \\ "pricing":{"prompt":"0.0000001","completion":"0.0000005","web_search":"0.01"},"supported_parameters":["tools","reasoning"]},
    \\{"id":"dots-studio/dots-3-note-preview:free","name":"dots: note","description":"Free.","context_length":512000,
    \\ "architecture":{"input_modalities":["text"],"output_modalities":["text"]},"pricing":{"prompt":"0","completion":"0"},"supported_parameters":["tools"]},
    \\{"id":"openai/gpt-6.1-sol:batch","name":"batch","pricing":{"prompt":"1","completion":"1"}}
    \\]}
;

const Tokens = struct { access_token: []const u8, refresh_token: []const u8, user: struct { id: []const u8, plan: []const u8 } };

fn bearer(arena: std.mem.Allocator, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "Bearer {s}", .{token});
}

test "migrations run once" {
    var env: Env = undefined;
    try start(&env, &.{""}, false);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    const migrate = @import("app").migrate;
    try std.testing.expectEqual(@as(usize, 0), try migrate.run(env.state.db, &c, &migrate.all));
}

test "auth: signup, login, refresh rotation, me, 401 without dev auth" {
    var env: Env = undefined;
    try start(&env, &.{""}, false);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var anon = try env.t.get("/v1/me", .{});
    defer anon.deinit();
    try anon.expectStatus(.unauthorized);

    var up = try env.t.post("/v1/auth/signup", .{ .json = .{ .name = "Ada", .email = "ada@example.com", .password = "correct horse" } });
    defer up.deinit();
    try up.expectStatus(.created);
    const tokens = try up.json(Tokens);
    try std.testing.expectEqualStrings("free", tokens.user.plan);

    var dup = try env.t.post("/v1/auth/signup", .{ .json = .{ .name = "Ada", .email = "ADA@example.com", .password = "correct horse" } });
    defer dup.deinit();
    try dup.expectStatus(.conflict);

    var bad = try env.t.post("/v1/auth/login", .{ .json = .{ .email = "ada@example.com", .password = "wrong password" } });
    defer bad.deinit();
    try bad.expectStatus(.unauthorized);

    var me = try env.t.get("/v1/me", .{ .headers = &.{.{ "Authorization", try bearer(a, tokens.access_token) }} });
    defer me.deinit();
    try me.expectStatus(.ok);

    var r1 = try env.t.post("/v1/auth/refresh", .{ .json = .{ .refresh_token = tokens.refresh_token } });
    defer r1.deinit();
    try r1.expectStatus(.ok);
    var r2 = try env.t.post("/v1/auth/refresh", .{ .json = .{ .refresh_token = tokens.refresh_token } });
    defer r2.deinit();
    try r2.expectStatus(.unauthorized); // rotated: the old one is spent
}

test "models: shop excludes batch variants, marks free and default, applies markup" {
    var env: Env = undefined;
    try start(&env, &.{""}, true);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var res = try env.t.get("/v1/models", .{});
    defer res.deinit();
    try res.expectStatus(.ok);
    const list = try res.json(struct { object: []const u8, data: []const struct { id: []const u8, free: bool, default: bool, prompt_per_mtok: f64, name: []const u8 } });
    try std.testing.expectEqual(@as(usize, 2), list.data.len);
    try std.testing.expectEqualStrings("Claude Haiku 5.5", list.data[0].name);
    try std.testing.expect(list.data[0].default and !list.data[0].free);
    try std.testing.expectApproxEqAbs(@as(f64, 0.115), list.data[0].prompt_per_mtok, 1e-9);
    try std.testing.expect(list.data[1].free);
}

const quiz_turn =
    \\data: {"model":"anthropic/claude-haiku-5.5","choices":[{"index":0,"delta":{"role":"assistant","content":"Here's a quiz."}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"toolu_1","type":"function","function":{"name":"make_quiz","arguments":""}}]}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"title\": \"Zig\", \"questions\": [{\"question\": \"Who makes Zig?\", \"options\": [\"ZSF\", \"ACME\"], \"answer_index\": 0, \"explanation\": \"The Zig Software Foundation.\"}]}"}}]}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1000,"completion_tokens":50,"cost":0.0001,"prompt_tokens_details":{"cached_tokens":800,"cache_write_tokens":0}}}
    \\
    \\data: [DONE]
    \\
    \\
;

const bad_chart_turn =
    \\data: {"model":"anthropic/claude-haiku-5.5","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"toolu_9","type":"function","function":{"name":"render_chart","arguments":"{\"type\": \"donut\", \"series\": []}"}}]}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.00001}}
    \\
    \\data: [DONE]
    \\
    \\
;

const final_turn =
    \\: OPENROUTER PROCESSING
    \\
    \\data: {"choices":[{"index":0,"delta":{"content":"Good luck [1]","annotations":[{"type":"url_citation","url_citation":{"url":"https://ziglang.org","title":"Zig","content":"Zig is a language"}}]}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1100,"completion_tokens":5,"cost":0.0002}}
    \\
    \\data: [DONE]
    \\
    \\
;

const followups_reply =
    \\{"choices":[{"message":{"role":"assistant","content":"```json\n[\"What is comptime?\", \"Why Zig?\", \"How fast?\"]\n```"}}],"usage":{"prompt_tokens":100,"completion_tokens":20,"cost":0.00001}}
;

test "chat: UI tool, citations, usage with cache, follow-ups, billing" {
    var env: Env = undefined;
    try start(&env, &.{ quiz_turn, final_turn, followups_reply }, true);
    defer env.deinit();

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .mode = "search",
        .messages = .{.{ .role = "user", .content = "Quiz me on Zig" }},
        .session = "conv-1",
    } });
    defer res.deinit();
    try res.expectStatus(.ok);
    const body = res.body;
    const order = [_][]const u8{ "event: delta", "event: usage", "event: tool\n", "event: sources", "event: followups", "event: done" };
    var at: usize = 0;
    for (order) |needle| {
        const i = std.mem.indexOfPos(u8, body, at, needle) orelse {
            std.debug.print("missing {s} after {d} in:\n{s}\n", .{ needle, at, body });
            return error.TestUnexpectedResult;
        };
        at = i;
    }
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cached_tokens\":800") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "What is comptime?") != null);

    // Second upstream call carried the tool result and cache breakpoints.
    const second = env.fake.bodies.items[1];
    try std.testing.expect(std.mem.indexOf(u8, second, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "Shown to the user: quiz \\\"Zig\\\" with 1 question(s).") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "cache_control") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"plugins\":[{\"id\":\"web\"") != null);

    // Billed: three calls, each cost x 1.15, rounded up.
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    const total = try env.state.db.one(i64, &c, "SELECT SUM(charged_micros) FROM usage_events WHERE user_id = 'dev-user'", .{});
    try std.testing.expectEqual(@as(i64, 115 + 230 + 12), total);
    const cached = try env.state.db.one(i64, &c, "SELECT SUM(cached_tokens) FROM usage_events", .{});
    try std.testing.expectEqual(@as(i64, 800), cached);

    // The follow-ups call is pinned to the user's language (none clear here).
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[2], "Write in the same language") != null);
}

test "chat: invalid UI tool arguments go back to the model, not the app" {
    var env: Env = undefined;
    try start(&env, &.{ bad_chart_turn, final_turn, followups_reply }, true);
    defer env.deinit();

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "Chart it" }},
    } });
    defer res.deinit();
    try res.expectStatus(.ok);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: tool\n") == null);
    const second = env.fake.bodies.items[1];
    try std.testing.expect(std.mem.indexOf(u8, second, "render_chart arguments are invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "not one of") != null);
}

test "billing: paid models answer 402 when quota and wallet are spent; free models still work" {
    var env: Env = undefined;
    try start(&env, &.{final_turn}, true);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    _ = try env.state.db.exec(&c, "UPDATE quota_periods SET used_micros = included_micros", .{});
    _ = try env.state.db.exec(&c, "DELETE FROM wallet_ledger", .{});

    var models = try env.t.get("/v1/models", .{});
    models.deinit();

    var paid = try env.t.post("/v1/chat/stream", .{ .json = .{ .model = "anthropic/claude-haiku-5.5", .messages = .{.{ .role = "user", .content = "hi" }} } });
    defer paid.deinit();
    try paid.expectStatus(.payment_required);

    var free = try env.t.post("/v1/chat/stream", .{ .json = .{ .model = "dots-studio/dots-3-note-preview:free", .messages = .{.{ .role = "user", .content = "hi" }}, .tools_enabled = false } });
    defer free.deinit();
    try free.expectStatus(.ok);
}

test "billing: mock checkout credits the wallet and switches plans" {
    var env: Env = undefined;
    try start(&env, &.{""}, true);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var top = try env.t.post("/v1/billing/checkout", .{ .json = .{ .kind = "topup", .amount_cents = 1000 } });
    defer top.deinit();
    try top.expectJson(.{ .url = null, .mock = true });
    var sub = try env.t.post("/v1/billing/checkout", .{ .json = .{ .kind = "subscription", .plan = "max" } });
    defer sub.deinit();
    var summary = try env.t.get("/v1/billing", .{});
    defer summary.deinit();
    const s = try summary.json(struct { plan: struct { id: []const u8 }, wallet_micros: i64, included_micros: i64 });
    try std.testing.expectEqualStrings("max", s.plan.id);
    try std.testing.expectEqual(@as(i64, 30_000_000), s.wallet_micros); // $20 dev seed + $10
    try std.testing.expectEqual(@as(i64, 100_000_000), s.included_micros);
}

test "gateway: API key auth, LiteLLM prefix stripped, breakpoints injected, metered" {
    const reply =
        \\{"id":"gen-1","choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"cost":0.001}}
    ;
    var env: Env = undefined;
    try start(&env, &.{reply}, true);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var made = try env.t.post("/v1/keys", .{ .json = .{ .name = "openhands" } });
    defer made.deinit();
    try made.expectStatus(.created);
    const key = (try made.json(struct { key: []const u8 })).key;

    var bad = try env.t.post("/v1/chat/completions", .{ .headers = &.{.{ "Authorization", "Bearer sk-eai-nope" }}, .json = .{ .model = "x" } });
    defer bad.deinit();
    try bad.expectStatus(.unauthorized);

    var res = try env.t.post("/v1/chat/completions", .{
        .headers = &.{ .{ "Authorization", try bearer(a, key) }, .{ "X-EveryAI-Session", "code-7" } },
        .json = .{ .model = "openai/anthropic/claude-sonnet-5.5", .messages = .{ .{ .role = "system", .content = "You are an agent" }, .{ .role = "user", .content = "fix it" } } },
    });
    defer res.deinit();
    try res.expectStatus(.ok);
    const sent = env.fake.bodies.items[0];
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"model\":\"anthropic/claude-sonnet-5.5\"") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, sent, "cache_control"));

    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = a };
    const row = try env.state.db.one(struct { session: []const u8, charged_micros: i64, api_key_id: []const u8 }, &c, "SELECT session, charged_micros, api_key_id FROM usage_events", .{});
    try std.testing.expectEqualStrings("code-7", row.session);
    try std.testing.expectEqual(@as(i64, 1150), row.charged_micros);
}

const anthropic_turn =
    \\event: message_start
    \\data: {"type":"message_start","message":{"id":"msg_1","model":"claude-haiku-5-5","usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}
    \\
    \\event: content_block_start
    \\data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"A cat."}}
    \\
    \\event: content_block_start
    \\data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"That's a cat."}}
    \\
    \\event: message_delta
    \\data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":100}}
    \\
    \\event: message_stop
    \\data: {"type":"message_stop"}
    \\
    \\
;

test "dev switch: Claude on Anthropic's API, attachments, provider billed, session totals" {
    var env: Env = undefined;
    try start(&env, &.{followups_reply}, true);
    defer env.deinit();
    env.anth.responses = &.{anthropic_turn};
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var before = try env.t.get("/v1/dev/upstream", .{});
    defer before.deinit();
    try before.expectJson(.{ .anthropic = "openrouter", .keys = .{ .openrouter = true, .anthropic = true } });
    var bad = try env.t.put("/v1/dev/upstream", .{ .json = .{ .anthropic = "bedrock" } });
    defer bad.deinit();
    try std.testing.expect(@backingInt(bad.status) >= 400);
    var sw = try env.t.put("/v1/dev/upstream", .{ .json = .{ .anthropic = "anthropic" } });
    defer sw.deinit();
    try sw.expectStatus(.ok);
    // Search keeps OpenRouter's web plugin.
    try std.testing.expectEqualStrings("openrouter", env.state.route("anthropic/claude-haiku-5.5", false).provider);

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = .{
            .{ .type = "image_url", .image_url = .{ .url = "data:image/png;base64,iVBORw0KGgo=" } },
            .{ .type = "text", .text = "What is this?" },
        } }},
        .tools_enabled = false,
        .session = "conv-a",
    } });
    defer res.deinit();
    try res.expectStatus(.ok);
    for ([_][]const u8{ "event: reasoning", "That's a cat.", "event: usage", "\"prompt_tokens\":1000", "event: followups", "event: done" }) |needle| {
        if (std.mem.indexOf(u8, res.body, needle) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ needle, res.body });
            return error.TestUnexpectedResult;
        }
    }
    const sent = env.anth.bodies.items[0];
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"model\":\"claude-haiku-5-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"type\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"usage\"") == null);
    // Follow-ups (Gemini) still went to OpenRouter.
    try std.testing.expectEqual(@as(usize, 1), env.fake.bodies.items.len);

    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = a };
    const row = try env.state.db.one(struct { provider: []const u8, charged_micros: i64 }, &c, "SELECT provider, charged_micros FROM usage_events WHERE kind = 'chat'", .{});
    try std.testing.expectEqualStrings("anthropic", row.provider);
    // 1000 × $0.1/M + 100 × $0.5/M = $0.00015, × 1.15
    try std.testing.expect(row.charged_micros >= 172 and row.charged_micros <= 175);

    var totals = try env.t.get("/v1/usage/session/conv-a", .{});
    defer totals.deinit();
    try totals.expectStatus(.ok);
    const t = try totals.json(struct { calls: i64, prompt_tokens: i64, last_prompt_tokens: i64, last_completion_tokens: i64, charged_micros: i64 });
    try std.testing.expectEqual(@as(i64, 2), t.calls);
    try std.testing.expectEqual(@as(i64, 1100), t.prompt_tokens);
    try std.testing.expectEqual(@as(i64, 1000), t.last_prompt_tokens);
    try std.testing.expectEqual(@as(i64, 100), t.last_completion_tokens);

    // The gateway (OpenHands) on the same route, non-streamed.
    env.anth.responses = &.{
        \\{"id":"msg_2","model":"claude-haiku-5-5","content":[{"type":"text","text":"Reading it."},{"type":"tool_use","id":"toolu_2","name":"terminal","input":{"command":"ls"}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"cache_read_input_tokens":90,"cache_creation_input_tokens":0,"output_tokens":5}}
    };
    env.anth.next_index = 0;
    var made = try env.t.post("/v1/keys", .{ .json = .{ .name = "openhands" } });
    defer made.deinit();
    const key = (try made.json(struct { key: []const u8 })).key;
    var gw = try env.t.post("/v1/chat/completions", .{
        .headers = &.{ .{ "Authorization", try bearer(a, key) }, .{ "X-EveryAI-Session", "code-9" } },
        .json = .{ .model = "openai/anthropic/claude-haiku-5.5", .temperature = 0, .messages = .{.{ .role = "user", .content = "list files" }} },
    });
    defer gw.deinit();
    try gw.expectStatus(.ok);
    const reply = try gw.json(struct {
        choices: []const struct { message: struct { content: ?[]const u8, tool_calls: []const struct { id: []const u8, function: struct { name: []const u8, arguments: []const u8 } } }, finish_reason: []const u8 },
        usage: struct { prompt_tokens: i64, prompt_tokens_details: struct { cached_tokens: i64 } },
    });
    try std.testing.expectEqualStrings("tool_calls", reply.choices[0].finish_reason);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", reply.choices[0].message.tool_calls[0].function.arguments);
    try std.testing.expectEqual(@as(i64, 100), reply.usage.prompt_tokens);
    try std.testing.expectEqual(@as(i64, 90), reply.usage.prompt_tokens_details.cached_tokens);
    try std.testing.expect(std.mem.indexOf(u8, env.anth.bodies.items[1], "temperature") == null);
    const gw_row = try env.state.db.one(struct { provider: []const u8, session: []const u8 }, &c, "SELECT provider, session FROM usage_events WHERE kind = 'gateway'", .{});
    try std.testing.expectEqualStrings("anthropic", gw_row.provider);
    try std.testing.expectEqualStrings("code-9", gw_row.session);
}

const diagram_turn =
    \\data: {"model":"anthropic/claude-haiku-5.5","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"toolu_d1","type":"function","function":{"name":"render_diagram","arguments":"{\"title\": \"Flow\", \"mermaid\": \"graph TD; A-->B\"}"}}]}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.00001}}
    \\
    \\data: [DONE]
    \\
    \\
;

/// Reads events until one named `name`; its data.
fn untilEvent(s: *anole.testing.Stream, name: []const u8) ![]const u8 {
    while (try s.nextEvent()) |e| {
        if (std.mem.eql(u8, e.event orelse "", name)) return e.data;
    }
    std.debug.print("stream ended before event {s}\n", .{name});
    return error.TestUnexpectedResult;
}

test "chat: a client-executed tool waits for the app's result" {
    var env: Env = undefined;
    try start(&env, &.{ diagram_turn, final_turn, followups_reply }, true);
    defer env.deinit();

    var s = try env.t.open(.post, "/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "Draw it" }},
        .client_tools = .{"render_diagram"},
    } });
    defer s.deinit();
    try std.testing.expect(s.status == .ok);
    const wait = try untilEvent(s, "tool_wait");
    try std.testing.expect(std.mem.indexOf(u8, wait, "\"id\":\"toolu_d1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wait, "graph TD") != null);
    try std.testing.expectEqual(@as(usize, 1), env.state.waits.count(env.server.io()));

    // Unknown calls are refused; the real one resumes the turn.
    var miss = try env.t.post("/v1/chat/tool_result", .{ .json = .{ .call_id = "toolu_nope", .result = "x" } });
    defer miss.deinit();
    try miss.expectStatus(.not_found);
    var ok = try env.t.post("/v1/chat/tool_result", .{ .json = .{ .call_id = "toolu_d1", .result = "Parse error on line 1: expected arrow", .is_error = true } });
    defer ok.deinit();
    try ok.expectStatus(.ok);

    const status = try untilEvent(s, "tool_status");
    try std.testing.expect(std.mem.indexOf(u8, status, "\"status\":\"failed\"") != null);
    _ = try untilEvent(s, "done");
    try std.testing.expectEqual(@as(usize, 0), env.state.waits.count(env.server.io()));
    // The model saw the app's answer, not an acknowledgement.
    const second = env.fake.bodies.items[1];
    try std.testing.expect(std.mem.indexOf(u8, second, "Error: Parse error on line 1: expected arrow") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "Shown to the user") == null);
}

test "chat: an unanswered client tool times out with a typed error; undeclared tools don't wait" {
    var env: Env = undefined;
    try start(&env, &.{ diagram_turn, final_turn, followups_reply, diagram_turn, final_turn, followups_reply }, true);
    defer env.deinit();
    env.state.cfg.client_tool_timeout_ms = 50;

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "Draw it" }},
        .client_tools = .{"render_diagram"},
    } });
    defer res.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: tool_wait") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"detail\":\"timed out\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: done") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[1], "Error (timeout): the app did not answer this render_diagram call") != null);
    try std.testing.expectEqual(@as(usize, 0), env.state.waits.count(env.server.io()));

    var late = try env.t.post("/v1/chat/tool_result", .{ .json = .{ .call_id = "toolu_d1", .result = "ok" } });
    defer late.deinit();
    try late.expectStatus(.not_found);

    // Without client_tools the same call is a plain UI tool.
    var plain = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "Draw it" }},
    } });
    defer plain.deinit();
    try std.testing.expect(std.mem.indexOf(u8, plain.body, "event: tool_wait") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain.body, "event: tool\n") != null);
}

// ------------------------------------------------------------------ cut-off replies

const cut_quiz_turn =
    \\data: {"model":"anthropic/claude-haiku-5.5","choices":[{"index":0,"delta":{"role":"assistant","content":"Here's a quiz."}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"toolu_c","type":"function","function":{"name":"make_quiz","arguments":"{\"title\": \"Zig\", \"questions\": [{\"question\": \"Who ma"}}]}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}],"usage":{"prompt_tokens":1000,"completion_tokens":4096,"cost":0.0001}}
    \\
    \\data: [DONE]
    \\
    \\
;

const cut_text_turn =
    \\data: {"choices":[{"index":0,"delta":{"content":"Part one, "}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}],"usage":{"prompt_tokens":1100,"completion_tokens":32768,"cost":0.0001}}
    \\
    \\data: [DONE]
    \\
    \\
;

const rest_text_turn =
    \\data: {"choices":[{"index":0,"delta":{"content":"part two."}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1200,"completion_tokens":5,"cost":0.0001}}
    \\
    \\data: [DONE]
    \\
    \\
;

test "chat: a cut-off tool call is asked for again with a bigger cap; cut-off text is continued" {
    var env: Env = undefined;
    try start(&env, &.{ cut_quiz_turn, quiz_turn, cut_text_turn, rest_text_turn, followups_reply }, true);
    defer env.deinit();

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "Quiz me on Zig" }},
    } });
    defer res.deinit();
    try res.expectStatus(.ok);
    const body = res.body;
    // The retry repeated "Here's a quiz." and the app saw it once; the quiz ran once.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "Here's a quiz."));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "event: tool\n"));
    try std.testing.expect(std.mem.indexOf(u8, body, "Part one, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "part two.") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "event: done") != null);

    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[0], "max_tokens") == null);
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[1], "\"max_tokens\":32768") != null);
    // The continuation carries the cut-off text and the nudge.
    const cont = env.fake.bodies.items[3];
    try std.testing.expect(std.mem.indexOf(u8, cont, "\"content\":\"Part one, \"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cont, "output length limit") != null);
}

test "chat: a call still cut off after the retry is not run, and the model is told why" {
    var env: Env = undefined;
    try start(&env, &.{ cut_quiz_turn, cut_quiz_turn, final_turn, followups_reply }, true);
    defer env.deinit();

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "Quiz me on Zig" }},
    } });
    defer res.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: tool\n") == null);
    const third = env.fake.bodies.items[2];
    try std.testing.expect(std.mem.indexOf(u8, third, "this make_quiz call was not run") != null);
    // The cut-off arguments are not sent back as history.
    try std.testing.expect(std.mem.indexOf(u8, third, "Who ma") == null);
}

test "chat: out of tool steps, one last call without tools asks for a summary" {
    var env: Env = undefined;
    try start(&env, &.{ quiz_turn, quiz_turn, quiz_turn, quiz_turn, final_turn, followups_reply }, true);
    defer env.deinit();

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "Quiz me on Zig" }},
    } });
    defer res.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res.body, "Good luck") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: done") != null);
    const last = env.fake.bodies.items[4];
    try std.testing.expect(std.mem.indexOf(u8, last, "\"tool_choice\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "used all of its tool steps") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[3], "tool_choice") == null);
}

const gw_cut_call =
    \\{"id":"gen-1","choices":[{"finish_reason":"length","message":{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"file_editor","arguments":"{\"command\":\"create\",\"path\":\"/a.txt\",\"file_text\":\"hel"}}]}}],"usage":{"prompt_tokens":10,"completion_tokens":16384,"cost":0.001}}
;
const gw_cut_text =
    \\{"id":"gen-2","choices":[{"finish_reason":"length","message":{"role":"assistant","content":"Hello"}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.001}}
;
const gw_rest_text =
    \\{"id":"gen-3","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":" world"}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.001}}
;

fn gatewayKey(env: *Env) ![]const u8 {
    var made = try env.t.post("/v1/keys", .{ .json = .{ .name = "openhands" } });
    defer made.deinit();
    return std.testing.allocator.dupe(u8, (try made.json(struct { key: []const u8 })).key);
}

test "gateway: a cut-off tool call is retried with a bigger cap, then made unparseable" {
    var env: Env = undefined;
    try start(&env, &.{ gw_cut_call, gw_cut_call }, true);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const key = try gatewayKey(&env);
    defer alloc.free(key);

    var res = try env.t.post("/v1/chat/completions", .{
        .headers = &.{.{ "Authorization", try bearer(a, key) }},
        .json = .{ .model = "openai/anthropic/claude-haiku-5.5", .max_tokens = 16384, .messages = .{.{ .role = "user", .content = "write a.txt" }} },
    });
    defer res.deinit();
    try res.expectStatus(.ok);
    try std.testing.expectEqual(@as(usize, 2), env.fake.bodies.items.len);
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[1], "\"max_tokens\":32768") != null);
    const reply = try std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{});
    const args = reply.object.get("choices").?.array.items[0].object.get("message").?.object.get("tool_calls").?.array.items[0].object.get("function").?.object.get("arguments").?.string;
    try std.testing.expect(std.mem.endsWith(u8, args, "not run]"));
    try std.testing.expectError(error.SyntaxError, std.json.parseFromSliceLeaky(std.json.Value, a, args, .{}));
    // Both attempts are billed.
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = a };
    try std.testing.expectEqual(@as(i64, 2), try env.state.db.one(i64, &c, "SELECT COUNT(*) FROM usage_events", .{}));
}

test "gateway: cut-off text is continued and returned as one reply" {
    var env: Env = undefined;
    try start(&env, &.{ gw_cut_text, gw_rest_text }, true);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const key = try gatewayKey(&env);
    defer alloc.free(key);

    var res = try env.t.post("/v1/chat/completions", .{
        .headers = &.{.{ "Authorization", try bearer(a, key) }},
        .json = .{ .model = "openai/gpt-6.1-sol", .messages = .{.{ .role = "user", .content = "hi" }} },
    });
    defer res.deinit();
    try res.expectStatus(.ok);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"content\":\"Hello world\"") != null);
    const second = env.fake.bodies.items[1];
    try std.testing.expect(std.mem.indexOf(u8, second, "{\"role\":\"assistant\",\"content\":\"Hello\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "output length limit") != null);
}

const gw_cut_stream =
    \\data: {"id":"g1","model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"Writing it."}}]}
    \\
    \\data: {"id":"g1","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"file_editor","arguments":"{\"command\":\"cre"}}]}}]}
    \\
    \\data: {"id":"g1","model":"m","choices":[{"index":0,"delta":{},"finish_reason":"length"}]}
    \\
    \\data: {"id":"g1","model":"m","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":16384,"cost":0.001}}
    \\
    \\data: [DONE]
    \\
    \\
;
const gw_full_stream =
    \\data: {"id":"g2","model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"Writing it."}}]}
    \\
    \\data: {"id":"g2","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c2","type":"function","function":{"name":"file_editor","arguments":"{\"command\":\"view\",\"path\":\"/a\"}"}}]}}]}
    \\
    \\data: {"id":"g2","model":"m","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
    \\
    \\data: {"id":"g2","model":"m","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":20,"cost":0.001}}
    \\
    \\data: [DONE]
    \\
    \\
;

test "gateway: streamed, a cut-off tool call is held back and replaced by the retry's" {
    var env: Env = undefined;
    try start(&env, &.{ gw_cut_stream, gw_full_stream }, true);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const key = try gatewayKey(&env);
    defer alloc.free(key);

    var res = try env.t.post("/v1/chat/completions", .{
        .headers = &.{.{ "Authorization", try bearer(a, key) }},
        .json = .{ .model = "openai/gpt-6.1-sol", .stream = true, .messages = .{.{ .role = "user", .content = "go" }} },
    });
    defer res.deinit();
    try res.expectStatus(.ok);
    const body = res.body;
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "Writing it."));
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"cre\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"c2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"finish_reason\":\"length\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"finish_reason\":\"tool_calls\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, body, "\n"), "data: [DONE]"));
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[1], "\"max_tokens\":32768") != null);
}

const image_turn =
    \\data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_img","type":"function","function":{"name":"generate_image","arguments":"{\"prompt\":\"make the cat blue\",\"edit_of\":\"img_1\",\"references\":[\"upload_1\"]}"}}]}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":900,"completion_tokens":30,"cost":0.0001}}
    \\
    \\data: [DONE]
    \\
    \\
;

const image_reply =
    \\{"data":[{"b64_json":"iVBORw0KGgoNEW","media_type":"image/png"}],"usage":{"cost":0.04}}
;

test "chat: generate_image edits an earlier image by id with references and reports the new id" {
    var env: Env = undefined;
    try start(&env, &.{ image_turn, image_reply, final_turn, followups_reply }, true);
    defer env.deinit();

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "Make it blue, like my photo" }},
        .images = .{ .{ .id = "img_1", .url = "data:image/png;base64,OLDCAT" }, .{ .id = "upload_1", .url = "data:image/jpeg;base64,PHOTO" } },
    } });
    defer res.deinit();
    try res.expectStatus(.ok);
    const body = res.body;
    try std.testing.expect(std.mem.indexOf(u8, body, "event: image") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"image_id\":\"img_2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"revises\":\"img_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"data\":\"iVBORw0KGgoNEW\"") != null);

    // The image request: the edited image first, then the reference.
    const up = env.fake.bodies.items[1];
    try std.testing.expect(std.mem.indexOf(u8, up, "\"input_references\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,OLDCAT\"}},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,PHOTO\"}}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, up, "\"model\":\"google/gemini-3.1-flash-image\"") != null);
    // The model learns the new id.
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[2], "Generated an image, img_2,") != null);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    try std.testing.expectEqual(@as(i64, 46_000), try env.state.db.one(i64, &c, "SELECT charged_micros FROM usage_events WHERE kind = 'image'", .{}));
}

test "chat: generate_image with an unknown id tells the model which ids exist" {
    var env: Env = undefined;
    try start(&env, &.{ image_turn, final_turn, followups_reply }, true);
    defer env.deinit();

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "Make it blue" }},
        .images = .{.{ .id = "upload_1", .url = "data:image/jpeg;base64,PHOTO" }},
    } });
    defer res.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: image") == null);
    try std.testing.expectEqual(@as(usize, 3), env.fake.bodies.items.len);
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[1], "there is no image \\\"img_1\\\" in this chat. Known images: upload_1.") != null);
}

const search_turn =
    \\data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_s","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"zig release\",\"max_results\":3}"}}]}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":900,"completion_tokens":20,"cost":0.0001}}
    \\
    \\data: [DONE]
    \\
    \\
;

const search_reply =
    \\{"choices":[{"message":{"role":"assistant","content":"ok","annotations":[
    \\{"type":"url_citation","url_citation":{"url":"https://ziglang.org/","title":"Zig","content":"Zig is a language"}},
    \\{"type":"url_citation","url_citation":{"url":"https://ziglang.org/download","title":"Download","content":"0.17.0 released"}}]}}],
    \\"usage":{"prompt_tokens":400,"completion_tokens":3,"cost":0.02}}
;

test "chat: web_search numbers results in the source ledger, sends each source once, and is metered" {
    var env: Env = undefined;
    try start(&env, &.{ search_turn, search_reply, final_turn, followups_reply }, true);
    defer env.deinit();

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "What's new in Zig?" }},
        .session = "conv-s",
    } });
    defer res.deinit();
    try res.expectStatus(.ok);
    const body = res.body;
    // One sources event with both results; the final reply's annotation for
    // the same page (no trailing slash) is not sent again.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "event: sources"));
    try std.testing.expect(std.mem.indexOf(u8, body, "\"url\":\"https://ziglang.org/download\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"kind\":\"search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"detail\":\"zig release\"") != null);

    // The search call: the web plugin on the utility model.
    const search = env.fake.bodies.items[1];
    try std.testing.expect(std.mem.indexOf(u8, search, "\"plugins\":[{\"id\":\"web\",\"engine\":\"exa\",\"max_results\":3}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"model\":\"google/gemini-3.5-flash-lite\"") != null);
    // The model reads numbered, fenced results.
    const next = env.fake.bodies.items[2];
    try std.testing.expect(std.mem.indexOf(u8, next, "2 result(s) for \\\"zig release\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, next, "[2] Download\\nhttps://ziglang.org/download") != null);
    try std.testing.expect(std.mem.indexOf(u8, next, "untrusted_tool_result source=\\\"web_search\\\"") != null);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    try std.testing.expectEqual(@as(i64, 23_000), try env.state.db.one(i64, &c, "SELECT charged_micros FROM usage_events WHERE kind = 'search'", .{}));
}

test "chat: with no credit left, a free model's web_search and follow-ups are skipped, not charged" {
    var env: Env = undefined;
    try start(&env, &.{ search_turn, final_turn, followups_reply }, true);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    _ = try env.state.db.exec(&c, "UPDATE quota_periods SET used_micros = included_micros", .{});
    _ = try env.state.db.exec(&c, "DELETE FROM wallet_ledger", .{});
    var models = try env.t.get("/v1/models", .{});
    models.deinit();

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "dots-studio/dots-3-note-preview:free",
        .messages = .{.{ .role = "user", .content = "What's new in Zig?" }},
    } });
    defer res.deinit();
    try res.expectStatus(.ok);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: done") != null);
    // The turn, then the model's next call: no search call, no follow-ups.
    try std.testing.expectEqual(@as(usize, 2), env.fake.bodies.items.len);
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[1], "out of credits, so web_search is unavailable") != null);
    try std.testing.expectEqual(@as(i64, 0), try env.state.db.one(i64, &c, "SELECT COUNT(*) FROM usage_events WHERE kind = 'search'", .{}));
}

test "images: the vector engine asks a Recraft vector model for SVG" {
    var env: Env = undefined;
    try start(&env, &.{"{\"data\":[{\"b64_json\":\"PHN2ZyB2aWV3Qm94PSIwIDAgMSAxIi8+\"}],\"usage\":{\"cost\":0.08}}"}, true);
    defer env.deinit();

    var res = try env.t.post("/v1/images", .{ .json = .{ .prompt = "a fox mascot", .engine = "vector" } });
    defer res.deinit();
    try res.expectStatus(.ok);
    const Out = struct { mime: []const u8, images: []const struct { mime: []const u8, data: []const u8 } };
    const out = try res.json(Out);
    try std.testing.expectEqualStrings("image/svg+xml", out.mime);
    try std.testing.expectEqual(@as(usize, 1), out.images.len);
    const up = env.fake.bodies.items[0];
    try std.testing.expect(std.mem.indexOf(u8, up, "\"model\":\"recraft/recraft-v4.1-vector\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, up, "\"output_format\":\"svg\"") != null);
}

test "images: a request that could cost more than what is left answers 402 before calling upstream" {
    var env: Env = undefined;
    try start(&env, &.{"{\"data\":[{\"b64_json\":\"iVBORw0K\"}],\"usage\":{\"cost\":0.04}}"}, true);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    _ = try env.state.db.exec(&c, "UPDATE quota_periods SET used_micros = included_micros - 50000", .{});
    _ = try env.state.db.exec(&c, "DELETE FROM wallet_ledger", .{});

    var res = try env.t.post("/v1/images", .{ .json = .{ .prompt = "ten cats", .n = 10, .quality = "high" } });
    defer res.deinit();
    try res.expectStatus(.payment_required);
    try std.testing.expectEqual(@as(usize, 0), env.fake.bodies.items.len);
}

// ------------------------------------------------------------------ memory

const memory_turn =
    \\data: {"model":"anthropic/claude-haiku-5.5","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"toolu_m1","type":"function","function":{"name":"memory","arguments":"{\"action\": \"add\", \"target\": \"user\", \"text\": \"Prefers metric units.\"}"}}]}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.00001}}
    \\
    \\data: [DONE]
    \\
    \\
;

test "chat: memory rides after the system prompt; undeclared memory calls get an error" {
    var env: Env = undefined;
    try start(&env, &.{ memory_turn, final_turn, followups_reply }, true);
    defer env.deinit();

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "Remember I use metric" }},
        .memory = "<memory>Name: Sam</memory>",
    } });
    defer res.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: done") != null);
    // The app never declared memory, so nothing was shown or awaited.
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: tool_wait") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: tool\n") == null);

    const first = env.fake.bodies.items[0];
    const sys = std.mem.indexOf(u8, first, "You are EveryAI").?;
    const mem = std.mem.indexOf(u8, first, "<memory>Name: Sam</memory>").?;
    const user = std.mem.indexOf(u8, first, "Remember I use metric").?;
    try std.testing.expect(sys < mem and mem < user);
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[1], "Error: memory is turned off in the user's app") != null);
}

// ------------------------------------------------------------------ reasoning

const thinking_tool_turn =
    \\data: {"model":"anthropic/claude-haiku-5.5","choices":[{"index":0,"delta":{"reasoning":"Need a diagram.","reasoning_details":[{"type":"reasoning.text","text":"Need a diagram.","format":"anthropic-claude-v1","index":0}]}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.text","signature":"SIG1","index":0}],"tool_calls":[{"index":0,"id":"toolu_r1","type":"function","function":{"name":"render_diagram","arguments":"{\"title\": \"Flow\", \"mermaid\": \"graph TD; A-->B\"}"}}]}}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.00001}}
    \\
    \\data: [DONE]
    \\
    \\
;

test "chat: reasoning goes back within the tool loop; effort only for reasoning models" {
    var env: Env = undefined;
    try start(&env, &.{ thinking_tool_turn, final_turn, followups_reply, final_turn, followups_reply }, true);
    defer env.deinit();

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "Draw the flow" }},
        .effort = "max",
    } });
    defer res.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: done") != null);
    const first = env.fake.bodies.items[0];
    try std.testing.expect(std.mem.indexOf(u8, first, "\"reasoning\":{\"effort\":\"xhigh\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "reasoning_details") == null);
    const second = env.fake.bodies.items[1];
    try std.testing.expect(std.mem.indexOf(u8, second, "\"reasoning\":{\"effort\":\"xhigh\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, second,
        \\"reasoning_details":[{"type":"reasoning.text","format":"anthropic-claude-v1","signature":"SIG1","text":"Need a diagram.","index":0}]
    ) != null);
    // The follow-ups call is not the user's model: no effort.
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[2], "effort") == null);

    // A model without reasoning in the catalog ignores the effort.
    var free = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "dots-studio/dots-3-note-preview:free",
        .messages = .{.{ .role = "user", .content = "hi" }},
        .effort = "high",
    } });
    defer free.deinit();
    try std.testing.expect(std.mem.indexOf(u8, free.body, "event: done") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[3], "effort") == null);
}

test "aux: follow-ups pin the user's language and use the routed model; titles" {
    var env: Env = undefined;
    try start(&env, &.{
        final_turn,
        \\{"choices":[{"message":{"role":"assistant","content":"[\"a\",\"b\",\"c\"]"}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.00001}}
        ,
        \\{"choices":[{"message":{"role":"assistant","content":"\"Zigについて学ぶ。\"\n"}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.00001}}
    }, true);
    defer env.deinit();
    env.state.cfg.aux_followups_model = "openai/gpt-5.4-mini";

    var res = try env.t.post("/v1/chat/stream", .{ .json = .{
        .model = "anthropic/claude-haiku-5.5",
        .messages = .{.{ .role = "user", .content = "Zigについて教えてください" }},
    } });
    defer res.deinit();
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: followups") != null);
    const f = env.fake.bodies.items[1];
    try std.testing.expect(std.mem.indexOf(u8, f, "\"model\":\"openai/gpt-5.4-mini\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, f, "Write in Japanese") != null);

    var t = try env.t.post("/v1/aux/title", .{ .json = .{
        .messages = .{ .{ .role = "user", .content = "Zigについて教えてください" }, .{ .role = "assistant", .content = "Zigは..." } },
    } });
    defer t.deinit();
    try t.expectStatus(.ok);
    try std.testing.expect(std.mem.indexOf(u8, t.body, "\"title\":\"Zigについて学ぶ\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.fake.bodies.items[2], "Write in Japanese") != null);
}

// ------------------------------------------------------------------ polish

test "polish: one look at the render returns defects and a checked revision; 402 and bad revisions" {
    var env: Env = undefined;
    try start(&env, &.{
        \\{"choices":[{"message":{"role":"assistant","content":"DEFECTS:\n- #sun is hidden behind #hill\nSVG:\n<svg viewBox=\"0 0 9 9\"><g id=\"hill\"/><circle id=\"sun\"/></svg>"}}],"usage":{"prompt_tokens":1500,"completion_tokens":200,"cost":0.0004}}
        ,
        \\{"choices":[{"message":{"role":"assistant","content":"DEFECTS:\n- too dark\nSVG:\n<svg><rect/></svg>"}}],"usage":{"prompt_tokens":1500,"completion_tokens":20,"cost":0.0001}}
    }, true);
    defer env.deinit();
    var models_res = try env.t.get("/v1/models", .{});
    models_res.deinit();
    const svg = "<svg viewBox=\"0 0 9 9\"><circle id=\"sun\"/><g id=\"hill\"/></svg>";

    var res = try env.t.post("/v1/figures/polish", .{ .json = .{ .svg = svg, .png_base64 = "data:image/png;base64,iVBORw0K", .brief = "a sunrise", .session = "conv-1" } });
    defer res.deinit();
    try res.expectStatus(.ok);
    const Out = struct { svg: []const u8, defects: []const []const u8, changed: bool, kept_original: ?[]const u8, charged_micros: i64 };
    const out = try res.json(Out);
    try std.testing.expect(out.changed);
    try std.testing.expect(out.kept_original == null);
    try std.testing.expectEqualStrings("#sun is hidden behind #hill", out.defects[0]);
    try std.testing.expect(std.mem.indexOf(u8, out.svg, "<g id=\"hill\"/><circle id=\"sun\"/>") != null);
    try std.testing.expectEqual(@as(i64, 460), out.charged_micros);
    const up = env.fake.bodies.items[0];
    try std.testing.expect(std.mem.indexOf(u8, up, "\"model\":\"anthropic/claude-haiku-5.5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, up, "data:image/png;base64,iVBORw0K") != null);
    try std.testing.expect(std.mem.indexOf(u8, up, "Brief: a sunrise") != null);
    try std.testing.expect(std.mem.indexOf(u8, up, "\"max_tokens\":") != null);

    // A revision without a viewBox is dropped; the original comes back.
    var bad = try env.t.post("/v1/figures/polish", .{ .json = .{ .svg = svg, .png_base64 = "iVBORw0K" } });
    defer bad.deinit();
    try bad.expectStatus(.ok);
    const kept = try bad.json(Out);
    try std.testing.expect(!kept.changed);
    try std.testing.expectEqualStrings(svg, kept.svg);
    try std.testing.expect(kept.kept_original != null);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    _ = try env.state.db.exec(&c, "UPDATE quota_periods SET used_micros = included_micros", .{});
    _ = try env.state.db.exec(&c, "DELETE FROM wallet_ledger", .{});
    var broke = try env.t.post("/v1/figures/polish", .{ .json = .{ .svg = svg, .png_base64 = "iVBORw0K" } });
    defer broke.deinit();
    try broke.expectStatus(.payment_required);
    try std.testing.expectEqual(@as(usize, 2), env.fake.bodies.items.len);

    var no_png = try env.t.post("/v1/figures/polish", .{ .json = .{ .svg = svg, .png_base64 = "" } });
    defer no_png.deinit();
    try no_png.expectStatus(.unprocessable_entity);
}
