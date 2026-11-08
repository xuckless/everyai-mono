//! Webhooks: hook CRUD and signed deliveries over the routes in memory, and
//! delivery to the host over a loopback WebSocket (`anole.testing` cannot
//! upgrade).
const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");
const kit = @import("test_kit.zig");
const openrouter = app_main.openrouter;
const config = app_main.config;

const alloc = std.testing.allocator;
const Server = anole.Server(app_main.App);
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

const Env = struct {
    state: app_main.App,
    fake: openrouter.Fake,
    mails: app_main.mail.Fake,
    server: Server,
    t: anole.testing.Client(Server),

    fn deinit(self: *Env) void {
        self.t.deinit();
        self.server.deinit();
        self.state.limiter.deinit();
        self.state.global_limiter.deinit();
        self.state.egress.deinit();
        self.state.relay.deinit();
        self.state.catalog.deinit();
        self.fake.deinit();
        self.mails.deinit();
    }

    fn count(self: *Env, a: std.mem.Allocator, sql: []const u8) !i64 {
        var c: anole.db.Ctx = .{ .io = self.server.io(), .arena = a };
        return self.state.db.one(i64, &c, sql, .{});
    }
};

fn start(env: *Env, dev_auth: bool) !void {
    env.fake = .{ .responses = &.{""}, .gpa = alloc };
    const cfg: config.Config = .{
        .jwt_secret = .init("test-secret-0123456789abcdef0123456789"),
        .openrouter_api_key = .init("sk-or-test"),
        .dev_auth = dev_auth,
        .public_url = "https://api.example.test/",
    };
    env.state = .{
        .gpa = alloc,
        .cfg = cfg,
        .db = undefined,
        .jwt_keys = .{.{ .kid = "k1", .alg = .HS256, .material = .{ .hmac = cfg.jwt_secret.?.expose() } }},
        .upstream = env.fake.upstream(),
        .catalog = .init(alloc),
    };
    env.mails = .{ .gpa = alloc };
    env.state.mailer = env.mails.mailer();
    env.server = try Server.init(alloc, .{ .executors = .exact(2) }, &env.state);
    env.state.db = try env.server.sqlite(":memory:");
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    try app_main.prepare(&env.state, &c);
    try app_main.routes(&env.server, &env.state);
    env.t = try anole.testing.client(&env.server);
}

const Tokens = struct { access_token: []const u8 };
const NewHost = struct { id: []const u8, host_token: []const u8 };
const NewHook = struct { id: []const u8, name: []const u8, host_id: []const u8, url: []const u8, secret: []const u8 };
const Accepted = struct { delivery_id: []const u8 };
const Duplicate = struct { ok: bool, duplicate: bool = false };

fn signUp(env: *Env, a: std.mem.Allocator, email: []const u8) ![]const u8 {
    return kit.signIn(&env.t, &env.mails, a, email);
}

fn hostFor(env: *Env, a: std.mem.Allocator, auth_header: ?[]const u8) !NewHost {
    var made = if (auth_header) |h|
        try env.t.post("/v1/remote/hosts", .{ .headers = &.{.{ "Authorization", h }}, .json = .{ .name = "Studio Mac", .public_key = "aG9zdA" } })
    else
        try env.t.post("/v1/remote/hosts", .{ .json = .{ .name = "Studio Mac", .public_key = "aG9zdA" } });
    defer made.deinit();
    try made.expectStatus(.created);
    const h = try made.json(NewHost);
    return .{ .id = try a.dupe(u8, h.id), .host_token = try a.dupe(u8, h.host_token) };
}

/// A hook for the dev user's `host`.
fn hookFor(env: *Env, a: std.mem.Allocator, host: NewHost, name: []const u8) !NewHook {
    var made = try env.t.post("/v1/hooks", .{ .headers = &.{.{ "X-Remote-Host-Token", host.host_token }}, .json = .{ .name = name, .host_id = host.id } });
    defer made.deinit();
    try made.expectStatus(.created);
    const h = try made.json(NewHook);
    return .{ .id = try a.dupe(u8, h.id), .name = try a.dupe(u8, h.name), .host_id = try a.dupe(u8, h.host_id), .url = try a.dupe(u8, h.url), .secret = try a.dupe(u8, h.secret) };
}

/// `sha256=<hex HMAC(secret, parts...)>`.
fn mac(a: std.mem.Allocator, secret: []const u8, parts: []const []const u8) ![]const u8 {
    var out: [32]u8 = undefined;
    var h = HmacSha256.init(secret);
    for (parts) |p| h.update(p);
    h.final(&out);
    return std.fmt.allocPrint(a, "sha256={s}", .{&std.fmt.bytesToHex(out, .lower)});
}

/// An EveryAI-form signed POST at `ts`.
fn postSigned(env: *Env, a: std.mem.Allocator, hook: NewHook, secret: []const u8, ts: i64, body: []const u8) !anole.testing.Response {
    const ts_text = try std.fmt.allocPrint(a, "{d}", .{ts});
    const path = try std.fmt.allocPrint(a, "/v1/hooks/{s}", .{hook.id});
    return env.t.post(path, .{ .headers = &.{
        .{ "X-EveryAI-Timestamp", ts_text },
        .{ "X-EveryAI-Signature", try mac(a, secret, &.{ ts_text, ".", body }) },
        .{ "Content-Type", "application/json" },
    }, .body = body });
}

fn now(env: *Env) i64 {
    return app_main.util.now(env.server.io());
}

test "hooks: created for the caller's own host, secret shown once, capped, deleted with the host" {
    var env: Env = undefined;
    try start(&env, false);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const ada = try signUp(&env, a, "ada@example.com");
    const bob = try signUp(&env, a, "bob@example.com");
    const host = try hostFor(&env, a, ada);

    var made = try env.t.post("/v1/hooks", .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } }, .json = .{ .name = "CI", .host_id = host.id } });
    defer made.deinit();
    try made.expectStatus(.created);
    const hook = try made.json(NewHook);
    try std.testing.expect(std.mem.startsWith(u8, hook.secret, "whk_"));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "https://api.example.test/v1/hooks/{s}", .{hook.id}), hook.url);

    // Someone else's host.
    var stranger = try env.t.post("/v1/hooks", .{ .headers = &.{ .{ "Authorization", bob }, .{ "X-Remote-Host-Token", host.host_token } }, .json = .{ .name = "Mine", .host_id = host.id } });
    defer stranger.deinit();
    try stranger.expectStatus(.unauthorized);
    // The account without the host's own token.
    var tokenless = try env.t.post("/v1/hooks", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .name = "Mine", .host_id = host.id } });
    defer tokenless.deinit();
    try tokenless.expectStatus(.unauthorized);
    var anon = try env.t.post("/v1/hooks", .{ .json = .{ .name = "Mine", .host_id = host.id } });
    defer anon.deinit();
    try anon.expectStatus(.unauthorized);

    var list = try env.t.get("/v1/hooks", .{ .headers = &.{.{ "Authorization", ada }} });
    defer list.deinit();
    try list.expectStatus(.ok);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, list.body, hook.secret) == null);
    const listed = try list.json([]const struct { id: []const u8, url: []const u8, pending: i64 });
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings(hook.url, listed[0].url);
    var bobs = try env.t.get("/v1/hooks", .{ .headers = &.{.{ "Authorization", bob }} });
    defer bobs.deinit();
    try std.testing.expectEqualStrings("[]", bobs.body);

    // Ten per account.
    for (1..10) |_| {
        var more = try env.t.post("/v1/hooks", .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } }, .json = .{ .name = "More", .host_id = host.id } });
        defer more.deinit();
        try more.expectStatus(.created);
    }
    var eleventh = try env.t.post("/v1/hooks", .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } }, .json = .{ .name = "One too many", .host_id = host.id } });
    defer eleventh.deinit();
    try eleventh.expectStatus(.conflict);
    try std.testing.expect(std.mem.indexOf(u8, eleventh.body, "too_many_hooks") != null);

    const path = try std.fmt.allocPrint(a, "/v1/hooks/{s}", .{hook.id});
    var not_bobs = try env.t.delete(path, .{ .headers = &.{ .{ "Authorization", bob }, .{ "X-Remote-Host-Token", host.host_token } } });
    defer not_bobs.deinit();
    try not_bobs.expectStatus(.unauthorized);
    var tokenless_del = try env.t.delete(path, .{ .headers = &.{.{ "Authorization", ada }} });
    defer tokenless_del.deinit();
    try tokenless_del.expectStatus(.unauthorized);
    const ada_token = .{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } };
    var del = try env.t.delete(path, .{ .headers = &ada_token });
    defer del.deinit();
    try std.testing.expect(del.status == .no_content or del.status == .ok);
    var again = try env.t.delete(path, .{ .headers = &ada_token });
    defer again.deinit();
    try again.expectStatus(.not_found);
    try std.testing.expectEqual(@as(i64, 9), try env.count(a, "SELECT COUNT(*) FROM hooks"));

    // Removing the host removes its hooks.
    var drop = try env.t.delete(try std.fmt.allocPrint(a, "/v1/remote/hosts/{s}", .{host.id}), .{ .headers = &ada_token });
    defer drop.deinit();
    try std.testing.expect(drop.status == .no_content or drop.status == .ok);
    try std.testing.expectEqual(@as(i64, 0), try env.count(a, "SELECT COUNT(*) FROM hooks"));
}

test "hooks: deliveries need a valid, fresh signature, and replays are recognised" {
    var env: Env = undefined;
    try start(&env, true);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const host = try hostFor(&env, a, null);
    const hook = try hookFor(&env, a, host, "CI");
    const path = try std.fmt.allocPrint(a, "/v1/hooks/{s}", .{hook.id});

    // The EveryAI form.
    var good = try postSigned(&env, a, hook, hook.secret, now(&env), "{\"ref\":\"main\"}");
    defer good.deinit();
    try good.expectStatus(.accepted);
    try std.testing.expect((try good.json(Accepted)).delivery_id.len > 0);
    try std.testing.expectEqual(@as(i64, 1), try env.count(a, "SELECT COUNT(*) FROM hook_deliveries WHERE acked_at IS NULL AND body IS NOT NULL"));

    // GitHub's form.
    const gh_body = "{\"action\":\"opened\"}";
    var gh = try env.t.post(path, .{ .headers = &.{
        .{ "X-Hub-Signature-256", try mac(a, hook.secret, &.{gh_body}) },
        .{ "X-GitHub-Delivery", "d-1" },
        .{ "X-GitHub-Event", "issues" },
    }, .body = gh_body });
    defer gh.deinit();
    try gh.expectStatus(.accepted);
    // The same GitHub delivery again (a redelivery): accepted once.
    var gh_again = try env.t.post(path, .{ .headers = &.{
        .{ "X-Hub-Signature-256", try mac(a, hook.secret, &.{gh_body}) },
        .{ "X-GitHub-Delivery", "d-1" },
        .{ "X-GitHub-Event", "issues" },
    }, .body = gh_body });
    defer gh_again.deinit();
    try gh_again.expectStatus(.ok);
    try std.testing.expect((try gh_again.json(Duplicate)).duplicate);
    // A captured one replayed under another (unsigned) delivery id and event: still the same delivery.
    var gh_relabelled = try env.t.post(path, .{ .headers = &.{
        .{ "X-Hub-Signature-256", try mac(a, hook.secret, &.{gh_body}) },
        .{ "X-GitHub-Delivery", "x1" },
        .{ "X-GitHub-Event", "push" },
    }, .body = gh_body });
    defer gh_relabelled.deinit();
    try gh_relabelled.expectStatus(.ok);
    try std.testing.expect((try gh_relabelled.json(Duplicate)).duplicate);

    // GitHub's ping when the hook is set up: answered, not queued.
    var ping = try env.t.post(path, .{ .headers = &.{
        .{ "X-Hub-Signature-256", try mac(a, hook.secret, &.{"{\"zen\":\"hi\"}"}) },
        .{ "X-GitHub-Delivery", "d-ping" },
        .{ "X-GitHub-Event", "ping" },
    }, .body = "{\"zen\":\"hi\"}" });
    defer ping.deinit();
    try ping.expectStatus(.ok);
    try std.testing.expectEqual(@as(i64, 2), try env.count(a, "SELECT COUNT(*) FROM hook_deliveries"));

    // Bad signatures: another secret, a changed digit, none at all, a body changed after signing.
    const ts = now(&env);
    var wrong = try postSigned(&env, a, hook, "whk_not-the-secret", ts, "{}");
    defer wrong.deinit();
    try wrong.expectStatus(.unauthorized);
    const ts_text = try std.fmt.allocPrint(a, "{d}", .{ts});
    var sig = try a.dupe(u8, try mac(a, hook.secret, &.{ ts_text, ".", "{}" }));
    sig[sig.len - 1] = if (sig[sig.len - 1] == '0') '1' else '0';
    var flipped = try env.t.post(path, .{ .headers = &.{ .{ "X-EveryAI-Timestamp", ts_text }, .{ "X-EveryAI-Signature", sig } }, .body = "{}" });
    defer flipped.deinit();
    try flipped.expectStatus(.unauthorized);
    var unsigned = try env.t.post(path, .{ .body = "{}" });
    defer unsigned.deinit();
    try unsigned.expectStatus(.unauthorized);
    var changed = try env.t.post(path, .{ .headers = &.{
        .{ "X-EveryAI-Timestamp", ts_text },
        .{ "X-EveryAI-Signature", try mac(a, hook.secret, &.{ ts_text, ".", "{}" }) },
    }, .body = "{\"evil\":1}" });
    defer changed.deinit();
    try changed.expectStatus(.unauthorized);

    // Out of the 5-minute window either way.
    var stale = try postSigned(&env, a, hook, hook.secret, ts - 301, "{}");
    defer stale.deinit();
    try stale.expectStatus(.unauthorized);
    var future = try postSigned(&env, a, hook, hook.secret, ts + 301, "{}");
    defer future.deinit();
    try future.expectStatus(.unauthorized);
    try std.testing.expectEqual(@as(i64, 2), try env.count(a, "SELECT COUNT(*) FROM hook_deliveries"));

    // The identical request twice: accepted once.
    var first = try postSigned(&env, a, hook, hook.secret, ts, "{\"n\":1}");
    defer first.deinit();
    try first.expectStatus(.accepted);
    var replay = try postSigned(&env, a, hook, hook.secret, ts, "{\"n\":1}");
    defer replay.deinit();
    try replay.expectStatus(.ok);
    try std.testing.expect((try replay.json(Duplicate)).duplicate);

    // Too big, and an unknown hook.
    const big = try a.alloc(u8, (1 << 20) + 1);
    @memset(big, 'x');
    var too_big = try postSigned(&env, a, hook, hook.secret, ts, big);
    defer too_big.deinit();
    try too_big.expectStatus(.payload_too_large);
    var unknown = try postSigned(&env, a, .{ .id = "no-such-hook", .name = "", .host_id = "", .url = "", .secret = "" }, hook.secret, ts, "{}");
    defer unknown.deinit();
    try unknown.expectStatus(.not_found);

    var list = try env.t.get("/v1/hooks", .{});
    defer list.deinit();
    const listed = try list.json([]const struct { pending: i64, last_delivery_at: ?i64 });
    try std.testing.expectEqual(@as(i64, 3), listed[0].pending);
    try std.testing.expect(listed[0].last_delivery_at != null);
}

test "hooks: a host that doesn't pick up gets 503 after 20, and a hook takes 30 requests a minute" {
    var env: Env = undefined;
    try start(&env, true);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const host = try hostFor(&env, a, null);
    const hook = try hookFor(&env, a, host, "Busy");
    const ts = now(&env);
    for (0..20) |i| {
        var ok = try postSigned(&env, a, hook, hook.secret, ts, try std.fmt.allocPrint(a, "{{\"n\":{d}}}", .{i}));
        defer ok.deinit();
        try ok.expectStatus(.accepted);
    }
    for (20..30) |i| {
        var full = try postSigned(&env, a, hook, hook.secret, ts, try std.fmt.allocPrint(a, "{{\"n\":{d}}}", .{i}));
        defer full.deinit();
        try full.expectStatus(.service_unavailable);
        try std.testing.expect(std.mem.indexOf(u8, full.body, "host_backlog") != null);
        try std.testing.expectEqualStrings("3600", full.header("Retry-After").?);
    }
    var limited = try postSigned(&env, a, hook, hook.secret, ts, "{\"n\":31}");
    defer limited.deinit();
    try limited.expectStatus(.too_many_requests);
    // Another hook has its own bucket.
    const other = try hookFor(&env, a, host, "Quiet");
    var fine = try postSigned(&env, a, other, other.secret, ts, "{}");
    defer fine.deinit();
    try fine.expectStatus(.accepted);
}

/// The next text notice whose `type` is `want`, skipping others.
fn expectNotice(ws: *anole.websocket.Client, a: std.mem.Allocator, want: []const u8) !std.json.Value {
    for (0..8) |_| {
        const msg = try ws.receive();
        if (msg.type != .text) return error.UnexpectedBinary;
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, try a.dupe(u8, msg.data), .{});
        if (std.mem.eql(u8, v.object.get("type").?.string, want)) return v;
    }
    return error.NoSuchNotice;
}

test "hooks: deliveries wait for an offline host and arrive one per hook, each after the ack of the one before" {
    var env: Env = undefined;
    try start(&env, true);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const host = try hostFor(&env, a, null);
    const other_host = try hostFor(&env, a, null);
    const hook = try hookFor(&env, a, host, "CI");

    const Check = struct {
        fn post(io: std.Io, ar: std.mem.Allocator, port: u16, h: NewHook, body: []const u8) ![]const u8 {
            const ts_text = try std.fmt.allocPrint(ar, "{d}", .{app_main.util.now(io)});
            var r = try anole.client(io).fetch(try std.fmt.allocPrint(ar, "http://127.0.0.1:{d}/v1/hooks/{s}", .{ port, h.id }), .{
                .method = .post,
                .headers = &.{
                    .{ "X-EveryAI-Timestamp", ts_text },
                    .{ "X-EveryAI-Signature", try mac(ar, h.secret, &.{ ts_text, ".", body }) },
                    .{ "X-EveryAI-Event", "deploy" },
                    // Not passed on.
                    .{ "Authorization", "Bearer sender-credential" },
                },
                .body = body,
            });
            defer r.deinit();
            try std.testing.expectEqual(anole.http.Status.accepted, r.status());
            const got = try std.json.parseFromSliceLeaky(Accepted, ar, try ar.dupe(u8, try r.body()), .{ .ignore_unknown_fields = true });
            return got.delivery_id;
        }

        fn connect(io: std.Io, ar: std.mem.Allocator, port: u16, token: []const u8) !anole.websocket.Client {
            var client = anole.client(io).http;
            return client.connectWebSocket(try std.fmt.allocPrint(ar, "ws://127.0.0.1:{d}/v1/remote/host?token={s}", .{ port, token }), .{});
        }

        /// Closes and waits for the relay's answer, so everything sent before is handled.
        fn hangUp(ws: *anole.websocket.Client) void {
            ws.close(.normal, "") catch {};
            _ = ws.receive() catch {};
        }

        fn ackText(ar: std.mem.Allocator, id: []const u8) ![]const u8 {
            return std.fmt.allocPrint(ar, "{{\"type\":\"webhook_ack\",\"delivery_id\":\"{s}\"}}", .{id});
        }

        fn run(srv: *Server, ar: std.mem.Allocator, h_info: NewHost, other: NewHost, h: NewHook) !void {
            defer srv.stop();
            try srv.waitReady();
            const io = srv.io();
            const port = srv.addresses()[0].ip.getPort();

            // The host is away: all three are kept.
            const d1 = try post(io, ar, port, h, "{\"n\":1}");
            const d2 = try post(io, ar, port, h, "{\"n\":2}");
            const d3 = try post(io, ar, port, h, "{\"n\":3}");

            // After hello only the oldest; each ack sends the next.
            var ws = try connect(io, ar, port, h_info.host_token);
            _ = try expectNotice(&ws, ar, "hello");
            const n1 = try expectNotice(&ws, ar, "webhook");
            try std.testing.expectEqualStrings(d1, n1.object.get("delivery_id").?.string);
            try ws.send(.text, try ackText(ar, d1));
            const n2 = try expectNotice(&ws, ar, "webhook");
            try std.testing.expectEqualStrings(d2, n2.object.get("delivery_id").?.string);
            try std.testing.expectEqualStrings(h.id, n1.object.get("hook_id").?.string);
            try std.testing.expectEqualStrings("CI", n1.object.get("hook_name").?.string);
            var decoded: [16]u8 = undefined;
            const b64 = n1.object.get("body_b64").?.string;
            const len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
            try std.base64.standard.Decoder.decode(decoded[0..len], b64);
            try std.testing.expectEqualStrings("{\"n\":1}", decoded[0..len]);
            const headers = n1.object.get("headers").?.object;
            try std.testing.expectEqualStrings("deploy", headers.get("x-everyai-event").?.string);
            try std.testing.expect(headers.get("authorization") == null);
            try std.testing.expect(headers.get("x-everyai-signature") == null);

            // d2 isn't acked: it comes again on the next connect, and d3 waits behind it.
            hangUp(&ws);
            ws.deinit();

            // Another host's ack for it changes nothing.
            var intruder = try connect(io, ar, port, other.host_token);
            _ = try expectNotice(&intruder, ar, "hello");
            try intruder.send(.text, try ackText(ar, d2));
            hangUp(&intruder);
            intruder.deinit();

            var again = try connect(io, ar, port, h_info.host_token);
            defer again.deinit();
            _ = try expectNotice(&again, ar, "hello");
            const resent = try expectNotice(&again, ar, "webhook");
            try std.testing.expectEqualStrings(d2, resent.object.get("delivery_id").?.string);
            try again.send(.text, try ackText(ar, d2));
            const third = try expectNotice(&again, ar, "webhook");
            try std.testing.expectEqualStrings(d3, third.object.get("delivery_id").?.string);
            // Acking one twice sends nothing more.
            try again.send(.text, try ackText(ar, d2));

            // Online: a delivery behind an unacked one waits for its ack; then it comes.
            const d4 = try post(io, ar, port, h, "{\"n\":4}");
            try again.send(.text, try ackText(ar, d3));
            const fourth = try expectNotice(&again, ar, "webhook");
            try std.testing.expectEqualStrings(d4, fourth.object.get("delivery_id").?.string);
            // With nothing in flight, a new delivery arrives as it comes.
            try again.send(.text, try ackText(ar, d4));
            const d5 = try post(io, ar, port, h, "{\"n\":5}");
            const live = try expectNotice(&again, ar, "webhook");
            try std.testing.expectEqualStrings(d5, live.object.get("delivery_id").?.string);
            hangUp(&again);
        }
    };
    var checking = try env.server.io().concurrent(Check.run, .{ &env.server, a, host, other_host, hook });
    try env.server.listen("127.0.0.1:0");
    try checking.await(env.server.io());
}
