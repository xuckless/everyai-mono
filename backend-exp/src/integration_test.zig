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
    \\ "architecture":{"input_modalities":["text"],"output_modalities":["text"]},"pricing":{"prompt":"0","completion":"0"},"supported_parameters":[]},
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
    try std.testing.expect(@intFromEnum(bad.status) >= 400);
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
