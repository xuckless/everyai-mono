//! Remote hosts: pairing over the routes in memory, and the relay over
//! loopback WebSockets (`anole.testing` cannot upgrade).
const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");
const kit = @import("test_kit.zig");
const openrouter = app_main.openrouter;
const config = app_main.config;

const alloc = std.testing.allocator;
const Server = anole.Server(app_main.App);

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
};

fn start(env: *Env, dev_auth: bool) !void {
    env.fake = .{ .responses = &.{""}, .gpa = alloc };
    const cfg: config.Config = .{
        .jwt_secret = .init("test-secret-0123456789abcdef0123456789"),
        .openrouter_api_key = .init("sk-or-test"),
        .dev_auth = dev_auth,
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
const Code = struct { id: []const u8, code: []const u8, expires_at: i64 };
const Redeemed = struct { id: []const u8, status: []const u8, device_id: []const u8, device_token: []const u8, host: struct { id: []const u8, public_key: []const u8 } };
const Status = struct { status: []const u8 };
const HostList = []const struct { id: []const u8, online: bool, devices: []const struct { id: []const u8, name: []const u8 } };

fn signUp(env: *Env, a: std.mem.Allocator, email: []const u8) ![]const u8 {
    return kit.signIn(&env.t, &env.mails, a, email);
}

test "remote: pairing is single use, the host's token is its identity, and needs the host's approval" {
    var env: Env = undefined;
    try start(&env, false);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const ada = try signUp(&env, a, "ada@example.com");
    const bob = try signUp(&env, a, "bob@example.com");

    var made = try env.t.post("/v1/remote/hosts", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .name = "Studio Mac", .platform = "macos", .public_key = "aG9zdC1wdWJsaWMta2V5" } });
    defer made.deinit();
    try made.expectStatus(.created);
    const host = try made.json(NewHost);
    try std.testing.expect(std.mem.startsWith(u8, host.host_token, "rh_"));

    // The account alone can't hand out codes: only the host's own token can.
    var tokenless = try env.t.post("/v1/remote/pair", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .host_id = host.id } });
    defer tokenless.deinit();
    try tokenless.expectStatus(.unauthorized);
    var other_made = try env.t.post("/v1/remote/hosts", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .name = "Laptop", .public_key = "b3RoZXI" } });
    defer other_made.deinit();
    const other_host = try other_made.json(NewHost);
    var cross = try env.t.post("/v1/remote/pair", .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", other_host.host_token } }, .json = .{ .host_id = host.id } });
    defer cross.deinit();
    try cross.expectStatus(.not_found);

    var paired = try env.t.post("/v1/remote/pair", .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } }, .json = .{ .host_id = host.id } });
    defer paired.deinit();
    try paired.expectStatus(.created);
    const code = try paired.json(Code);
    try std.testing.expectEqual(@as(usize, 9), code.code.len);
    try std.testing.expectEqual(@as(u8, '-'), code.code[4]);

    // A wrong code finds nothing.
    var other = try env.t.post("/v1/remote/pair/redeem", .{ .json = .{ .code = "ZZZZ-ZZZZ", .device_name = "Bob's phone", .public_key = "Ym9i" } });
    defer other.deinit();
    try other.expectStatus(.not_found);

    // Typed in lower case without the dash.
    const typed = try std.ascii.allocLowerString(a, try std.mem.replaceOwned(u8, a, code.code, "-", ""));
    var red = try env.t.post("/v1/remote/pair/redeem", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .code = typed, .device_name = "Ada's phone", .public_key = "cGhvbmU" } });
    defer red.deinit();
    try red.expectStatus(.ok);
    const redeemed = try red.json(Redeemed);
    try std.testing.expectEqualStrings("pending", redeemed.status);
    try std.testing.expectEqualStrings("aG9zdC1wdWJsaWMta2V5", redeemed.host.public_key);
    try std.testing.expect(std.mem.startsWith(u8, redeemed.device_token, "rd_"));

    var again = try env.t.post("/v1/remote/pair/redeem", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .code = code.code, .device_name = "Twice", .public_key = "eA" } });
    defer again.deinit();
    try again.expectStatus(.not_found);

    const status_path = try std.fmt.allocPrint(a, "/v1/remote/pair/{s}", .{redeemed.id});
    // Only the redeeming device (its token) or the host reads the status.
    var nosy = try env.t.get(status_path, .{ .headers = &.{.{ "Authorization", ada }} });
    defer nosy.deinit();
    try nosy.expectStatus(.not_found);
    var pending = try env.t.get(status_path, .{ .headers = &.{.{ "X-Remote-Device-Token", redeemed.device_token }} });
    defer pending.deinit();
    try std.testing.expectEqualStrings("pending", (try pending.json(Status)).status);

    // A pending device is not listed and cannot open a socket yet; the
    // client cannot approve itself without the host's token.
    const approve_path = try std.fmt.allocPrint(a, "/v1/remote/pair/{s}/approve", .{redeemed.id});
    var self_approve = try env.t.post(approve_path, .{ .headers = &.{.{ "Authorization", ada }} });
    defer self_approve.deinit();
    try self_approve.expectStatus(.unauthorized);
    var wrong_host = try env.t.post(approve_path, .{ .headers = &.{.{ "X-Remote-Host-Token", other_host.host_token }} });
    defer wrong_host.deinit();
    try wrong_host.expectStatus(.not_found);

    var ok = try env.t.post(approve_path, .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } } });
    defer ok.deinit();
    try ok.expectStatus(.ok);
    try std.testing.expectEqualStrings("approved", (try ok.json(Status)).status);
    var twice = try env.t.post(approve_path, .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } } });
    defer twice.deinit();
    try twice.expectStatus(.not_found);

    var approved = try env.t.get(status_path, .{ .headers = &.{.{ "X-Remote-Host-Token", host.host_token }} });
    defer approved.deinit();
    try std.testing.expectEqualStrings("approved", (try approved.json(Status)).status);

    var list = try env.t.get("/v1/remote/hosts", .{ .headers = &.{.{ "Authorization", ada }} });
    defer list.deinit();
    const hosts = try list.json(HostList);
    try std.testing.expectEqual(@as(usize, 2), hosts.len);
    const studio = if (std.mem.eql(u8, hosts[0].id, host.id)) hosts[0] else hosts[1];
    try std.testing.expect(!studio.online);
    try std.testing.expectEqual(@as(usize, 1), studio.devices.len);
    try std.testing.expectEqualStrings("Ada's phone", studio.devices[0].name);
    var bobs = try env.t.get("/v1/remote/hosts", .{ .headers = &.{.{ "Authorization", bob }} });
    defer bobs.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try bobs.json(HostList)).len);

    // An expired code is refused; a denied pairing leaves no device.
    var p2 = try env.t.post("/v1/remote/pair", .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } }, .json = .{ .host_id = host.id } });
    defer p2.deinit();
    const code2 = try p2.json(Code);
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = a };
    _ = try env.state.db.exec(&c, "UPDATE remote_pairings SET expires_at = 0 WHERE id = ?", .{code2.id});
    var late = try env.t.post("/v1/remote/pair/redeem", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .code = code2.code, .device_name = "Late", .public_key = "eA" } });
    defer late.deinit();
    try late.expectStatus(.not_found);

    var p3 = try env.t.post("/v1/remote/pair", .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } }, .json = .{ .host_id = host.id } });
    defer p3.deinit();
    var r3 = try env.t.post("/v1/remote/pair/redeem", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .code = (try p3.json(Code)).code, .device_name = "Tablet", .public_key = "eA" } });
    defer r3.deinit();
    const deny_path = try std.fmt.allocPrint(a, "/v1/remote/pair/{s}/deny", .{(try r3.json(Redeemed)).id});
    var denied = try env.t.post(deny_path, .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } } });
    defer denied.deinit();
    try std.testing.expectEqualStrings("denied", (try denied.json(Status)).status);
    try std.testing.expectEqual(@as(i64, 1), try env.state.db.one(i64, &c, "SELECT COUNT(*) FROM remote_devices", .{}));

    // Unpairing and removing the host.
    const dev_path = try std.fmt.allocPrint(a, "/v1/remote/devices/{s}", .{redeemed.device_id});
    var gone = try env.t.delete(dev_path, .{ .headers = &.{.{ "Authorization", bob }} });
    defer gone.deinit();
    try gone.expectStatus(.unauthorized);
    // The account alone can't: the host's or the device's own token has to come with it.
    var tokenless_unpair = try env.t.delete(dev_path, .{ .headers = &.{.{ "Authorization", ada }} });
    defer tokenless_unpair.deinit();
    try tokenless_unpair.expectStatus(.unauthorized);
    var wrong_device = try env.t.delete(dev_path, .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Device-Token", "rd_nope" } } });
    defer wrong_device.deinit();
    try wrong_device.expectStatus(.unauthorized);
    var unpair = try env.t.delete(dev_path, .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Device-Token", redeemed.device_token } } });
    defer unpair.deinit();
    try std.testing.expect(unpair.status == .no_content or unpair.status == .ok);
    const host_path = try std.fmt.allocPrint(a, "/v1/remote/hosts/{s}", .{host.id});
    var tokenless_drop = try env.t.delete(host_path, .{ .headers = &.{.{ "Authorization", ada }} });
    defer tokenless_drop.deinit();
    try tokenless_drop.expectStatus(.unauthorized);
    var cross_drop = try env.t.delete(host_path, .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", other_host.host_token } } });
    defer cross_drop.deinit();
    try cross_drop.expectStatus(.not_found);
    var drop = try env.t.delete(host_path, .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } } });
    defer drop.deinit();
    try std.testing.expect(drop.status == .no_content or drop.status == .ok);
    try std.testing.expectEqual(@as(i64, 0), try env.state.db.one(i64, &c, "SELECT COUNT(*) FROM remote_pairings", .{}));
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

test "remote: the relay carries opaque frames between host and client, and unpairing cuts the client off" {
    var env: Env = undefined;
    try start(&env, true); // the dev user, no tokens on the REST calls
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var made = try env.t.post("/v1/remote/hosts", .{ .json = .{ .name = "Studio Mac", .public_key = "aG9zdA" } });
    defer made.deinit();
    const host = try made.json(NewHost);
    var p = try env.t.post("/v1/remote/pair", .{ .headers = &.{.{ "X-Remote-Host-Token", host.host_token }}, .json = .{ .host_id = host.id } });
    defer p.deinit();
    var r = try env.t.post("/v1/remote/pair/redeem", .{ .json = .{ .code = (try p.json(Code)).code, .device_name = "Phone", .public_key = "cGhvbmU" } });
    defer r.deinit();
    const device = try r.json(Redeemed);
    var ok = try env.t.post(try std.fmt.allocPrint(a, "/v1/remote/pair/{s}/approve", .{device.id}), .{ .headers = &.{.{ "X-Remote-Host-Token", host.host_token }} });
    defer ok.deinit();
    try ok.expectStatus(.ok);

    const Check = struct {
        fn run(srv: *Server, st: *app_main.App, ar: std.mem.Allocator, host_id: []const u8, host_token: []const u8, dev: Redeemed) !void {
            defer srv.stop();
            try srv.waitReady();
            const io = srv.io();
            const port = srv.addresses()[0].ip.getPort();
            var client = anole.client(io).http;

            // The host, with its token in a header.
            var keys: [1][]const u8 = undefined;
            var values: [1][]const u8 = undefined;
            var hashes: [1]u8 = undefined;
            var headers: anole.http.Headers = .{ .keys = &keys, .values = &values, .hashes = &hashes };
            try headers.put("Authorization", try std.fmt.allocPrint(ar, "Bearer {s}", .{host_token}));
            var h = try client.connectWebSocket(try std.fmt.allocPrint(ar, "ws://127.0.0.1:{d}/v1/remote/host", .{port}), .{ .headers = &headers });
            defer h.deinit();
            const hello = try expectNotice(&h, ar, "hello");
            try std.testing.expectEqual(@as(usize, 0), hello.object.get("clients").?.array.items.len);
            try std.testing.expect(st.relay.online(io, host_id));

            // A wrong device token is refused before the upgrade.
            try std.testing.expectError(error.WebSocketUpgradeFailed, client.connectWebSocket(try std.fmt.allocPrint(ar, "ws://127.0.0.1:{d}/v1/remote/client/{s}?token=rd_nope", .{ port, host_id }), .{}));

            // The device token is the device's identity (an account is optional).
            const base = try std.fmt.allocPrint(ar, "ws://127.0.0.1:{d}/v1/remote/client/{s}?token={s}", .{ port, host_id, dev.device_token });

            // The client, with its token in the query.
            var c = try client.connectWebSocket(base, .{});
            defer c.deinit();
            const chello = try expectNotice(&c, ar, "hello");
            try std.testing.expect(chello.object.get("host_online").?.bool);
            const channel: u32 = @intCast(chello.object.get("channel").?.integer);
            const open = try expectNotice(&h, ar, "client_open");
            try std.testing.expectEqual(@as(i64, channel), open.object.get("channel").?.integer);
            try std.testing.expectEqualStrings(dev.device_id, open.object.get("device_id").?.string);
            try std.testing.expectEqualStrings("cGhvbmU", open.object.get("public_key").?.string);

            // Client to host: the payload, untouched, behind its channel.
            const sealed = "\x00\xffsealed box\x01";
            try c.send(.binary, sealed);
            const up = try h.receive();
            try std.testing.expect(up.type == .binary);
            try std.testing.expectEqual(channel, std.mem.readInt(u32, up.data[0..4], .big));
            try std.testing.expectEqualStrings(sealed, up.data[4..]);

            // Host to client: the channel is stripped.
            var down: [4 + 5]u8 = undefined;
            std.mem.writeInt(u32, down[0..4], channel, .big);
            @memcpy(down[4..], "reply");
            try h.send(.binary, &down);
            const got = try c.receive();
            try std.testing.expect(got.type == .binary);
            try std.testing.expectEqualStrings("reply", got.data);

            // A control frame too big to be one is skipped unread; the socket carries on.
            const big = try ar.alloc(u8, app_main.remote.max_control + 1);
            @memset(big, 'x');
            try h.send(.text, big);
            try c.send(.binary, sealed);
            const still = try h.receive();
            try std.testing.expect(still.type == .binary);

            // Unpairing: the client is told and cut off, the host sees it go.
            var del = try anole.client(io).fetch(try std.fmt.allocPrint(ar, "http://127.0.0.1:{d}/v1/remote/devices/{s}", .{ port, dev.device_id }), .{ .method = .delete, .headers = &.{.{ "X-Remote-Host-Token", host_token }} });
            defer del.deinit();
            try std.testing.expect(del.status() == .no_content or del.status() == .ok);
            _ = try expectNotice(&c, ar, "revoked");
            const closed = try expectNotice(&h, ar, "client_close");
            try std.testing.expectEqual(@as(i64, channel), closed.object.get("channel").?.integer);
            try c.send(.binary, "after");
            const end = try c.receive();
            try std.testing.expect(end.type == .close);

            try h.close(.normal, "");
            _ = h.receive() catch {};
        }
    };
    var checking = try env.server.io().concurrent(Check.run, .{ &env.server, &env.state, a, host.id, host.host_token, device });
    try env.server.listen("127.0.0.1:0");
    try checking.await(env.server.io());
}

test "remote: no account needed; a host is claimed by signing in, limited per network, and pruned when idle" {
    var env: Env = undefined;
    try start(&env, false);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = a };

    // Signed out: a host, a code, a redeem, the device's status, an approval.
    var made = try env.t.post("/v1/remote/hosts", .{ .json = .{ .name = "Studio Mac", .public_key = "aG9zdA" } });
    defer made.deinit();
    try made.expectStatus(.created);
    const host = try made.json(NewHost);
    try std.testing.expectEqualStrings("anonymous", try env.state.db.one([]const u8, &c, "SELECT user_id FROM remote_hosts WHERE id = ?", .{host.id}));
    var p = try env.t.post("/v1/remote/pair", .{ .headers = &.{.{ "X-Remote-Host-Token", host.host_token }}, .json = .{ .host_id = host.id } });
    defer p.deinit();
    try p.expectStatus(.created);
    var r = try env.t.post("/v1/remote/pair/redeem", .{ .json = .{ .code = (try p.json(Code)).code, .device_name = "Phone", .public_key = "cGhvbmU" } });
    defer r.deinit();
    try r.expectStatus(.ok);
    const device = try r.json(Redeemed);
    var st = try env.t.get(try std.fmt.allocPrint(a, "/v1/remote/pair/{s}", .{device.id}), .{ .headers = &.{.{ "X-Remote-Device-Token", device.device_token }} });
    defer st.deinit();
    try std.testing.expectEqualStrings("pending", (try st.json(Status)).status);
    var ok = try env.t.post(try std.fmt.allocPrint(a, "/v1/remote/pair/{s}/approve", .{device.id}), .{ .headers = &.{.{ "X-Remote-Host-Token", host.host_token }} });
    defer ok.deinit();
    try ok.expectStatus(.ok);

    // Listing needs an account; claiming needs the account and the host's token.
    var list = try env.t.get("/v1/remote/hosts", .{});
    defer list.deinit();
    try list.expectStatus(.unauthorized);
    const ada = try signUp(&env, a, "ada@example.com");
    const bob = try signUp(&env, a, "bob@example.com");
    const claim_path = try std.fmt.allocPrint(a, "/v1/remote/hosts/{s}/claim", .{host.id});
    var tokenless = try env.t.post(claim_path, .{ .headers = &.{.{ "Authorization", ada }} });
    defer tokenless.deinit();
    try tokenless.expectStatus(.unauthorized);
    var claimed = try env.t.post(claim_path, .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } } });
    defer claimed.deinit();
    try claimed.expectStatus(.ok);
    var again = try env.t.post(claim_path, .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } } });
    defer again.deinit();
    try again.expectStatus(.ok);
    var taken = try env.t.post(claim_path, .{ .headers = &.{ .{ "Authorization", bob }, .{ "X-Remote-Host-Token", host.host_token } } });
    defer taken.deinit();
    try taken.expectStatus(.conflict);
    var mine = try env.t.get("/v1/remote/hosts", .{ .headers = &.{.{ "Authorization", ada }} });
    defer mine.deinit();
    const hosts = try mine.json(HostList);
    try std.testing.expectEqual(@as(usize, 1), hosts.len);
    try std.testing.expectEqual(@as(usize, 1), hosts[0].devices.len);

    // The reserved owner can't be signed into.
    var reserved = try env.t.post("/v1/auth/magic", .{ .json = .{ .email = "anonymous@everyai.invalid" } });
    defer reserved.deinit();
    try std.testing.expectEqual(anole.http.Status.unprocessable_entity, reserved.status);

    // Anonymous hosts per network per hour (the claimed one doesn't count).
    for (0..@intCast(env.state.cfg.anon_hosts_per_hour)) |_| {
        var more = try env.t.post("/v1/remote/hosts", .{ .json = .{ .name = "x", .public_key = "eA" } });
        defer more.deinit();
        try more.expectStatus(.created);
    }
    var over = try env.t.post("/v1/remote/hosts", .{ .json = .{ .name = "x", .public_key = "eA" } });
    defer over.deinit();
    try over.expectStatus(.too_many_requests);

    // Idle anonymous hosts go; the claimed one stays.
    _ = try env.state.db.exec(&c, "UPDATE remote_hosts SET created_at = 0, last_seen_at = NULL", .{});
    try app_main.remote.prune(&env.state, &c);
    try std.testing.expectEqual(@as(i64, 1), try env.state.db.one(i64, &c, "SELECT COUNT(*) FROM remote_hosts", .{}));
    try std.testing.expectEqual(@as(i64, 1), try env.state.db.one(i64, &c, "SELECT COUNT(*) FROM remote_devices", .{}));
}

test "remote: pairings left undecided don't use up a host's devices, and prune spares live hosts" {
    var env: Env = undefined;
    try start(&env, false);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = a };
    env.state.cfg.devices_per_host = 1;

    var made = try env.t.post("/v1/remote/hosts", .{ .json = .{ .name = "Mac", .public_key = "aG9zdA" } });
    defer made.deinit();
    const host = try made.json(NewHost);
    for (0..2) |_| {
        var p = try env.t.post("/v1/remote/pair", .{ .headers = &.{.{ "X-Remote-Host-Token", host.host_token }}, .json = .{ .host_id = host.id } });
        defer p.deinit();
        var r = try env.t.post("/v1/remote/pair/redeem", .{ .json = .{ .code = (try p.json(Code)).code, .device_name = "Phone", .public_key = "cGhvbmU" } });
        defer r.deinit();
        try r.expectStatus(.ok);
        // Nobody approves it; its window passes.
        _ = try env.state.db.exec(&c, "UPDATE remote_devices SET created_at = created_at - 3600", .{});
        _ = try env.state.db.exec(&c, "UPDATE remote_pairings SET decide_by = decide_by - 3600", .{});
    }

    // An idle anonymous host stays while it is online, or while its devices connect.
    _ = try env.state.db.exec(&c, "UPDATE remote_hosts SET created_at = 0, last_seen_at = 1", .{});
    try env.state.relay.hosts.put(std.heap.smp_allocator, try std.heap.smp_allocator.dupe(u8, host.id), 1);
    try app_main.remote.prune(&env.state, &c);
    try std.testing.expectEqual(@as(i64, 1), try env.state.db.one(i64, &c, "SELECT COUNT(*) FROM remote_hosts", .{}));
    env.state.relay.revokeHost(env.server.io(), host.id);
    _ = try env.state.db.exec(&c, "UPDATE remote_devices SET last_seen_at = ?", .{std.Io.Clock.real.now(env.server.io()).toSeconds()});
    try app_main.remote.prune(&env.state, &c);
    try std.testing.expectEqual(@as(i64, 1), try env.state.db.one(i64, &c, "SELECT COUNT(*) FROM remote_hosts", .{}));
    // Unapproved devices go a day after their window.
    _ = try env.state.db.exec(&c, "UPDATE remote_devices SET created_at = 0, last_seen_at = NULL", .{});
    try app_main.remote.prune(&env.state, &c);
    try std.testing.expectEqual(@as(i64, 0), try env.state.db.one(i64, &c, "SELECT COUNT(*) FROM remote_hosts", .{}));
}

test "remote: egress gate queues sockets past the limit and closes one over its quota" {
    var env: Env = undefined;
    try start(&env, false);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var made = try env.t.post("/v1/remote/hosts", .{ .json = .{ .name = "Mac", .public_key = "aG9zdA" } });
    defer made.deinit();
    const host = try made.json(NewHost);
    var p = try env.t.post("/v1/remote/pair", .{ .headers = &.{.{ "X-Remote-Host-Token", host.host_token }}, .json = .{ .host_id = host.id } });
    defer p.deinit();
    var r = try env.t.post("/v1/remote/pair/redeem", .{ .json = .{ .code = (try p.json(Code)).code, .device_name = "Phone", .public_key = "cGhvbmU" } });
    defer r.deinit();
    const device = try r.json(Redeemed);
    var ok = try env.t.post(try std.fmt.allocPrint(a, "/v1/remote/pair/{s}/approve", .{device.id}), .{ .headers = &.{.{ "X-Remote-Host-Token", host.host_token }} });
    defer ok.deinit();
    try ok.expectStatus(.ok);

    // One socket at a time, and an anonymous host may relay 16 bytes a day.
    env.state.egress.cfg.max_live = 1;
    env.state.egress_quotas.host.daily_bytes = 16;

    const Check = struct {
        fn run(srv: *Server, st: *app_main.App, ar: std.mem.Allocator, host_id: []const u8, host_token: []const u8, dev: Redeemed) !void {
            defer srv.stop();
            try srv.waitReady();
            const io = srv.io();
            const port = srv.addresses()[0].ip.getPort();
            var client = anole.client(io).http;
            var h = try client.connectWebSocket(try std.fmt.allocPrint(ar, "ws://127.0.0.1:{d}/v1/remote/host?token={s}", .{ port, host_token }), .{});
            defer h.deinit();
            _ = try expectNotice(&h, ar, "hello");

            // The client waits its turn behind the host.
            var c = try client.connectWebSocket(try std.fmt.allocPrint(ar, "ws://127.0.0.1:{d}/v1/remote/client/{s}?token={s}", .{ port, host_id, dev.device_token }), .{});
            defer c.deinit();
            const queued = try expectNotice(&c, ar, "queued");
            try std.testing.expectEqual(@as(i64, 1), queued.object.get("position").?.integer);

            // A slot opens: it's admitted. Then 20 bytes are over its 16.
            st.egress.cfg.max_live = 2;
            _ = try expectNotice(&c, ar, "hello");
            try c.send(.binary, "0123456789abcdef");
            var up = try h.receive();
            while (up.type == .text) up = try h.receive(); // client_open first
            try std.testing.expect(up.type == .binary);
            try c.send(.binary, "more");
            const budget = try expectNotice(&c, ar, "budget");
            try std.testing.expect(budget.object.get("resets_at").?.integer > 0);
            const end = try c.receive();
            try std.testing.expect(end.type == .close);
            try h.close(.normal, "");
            _ = h.receive() catch {};
        }
    };
    var checking = try env.server.io().concurrent(Check.run, .{ &env.server, &env.state, a, host.id, host.host_token, device });
    try env.server.listen("127.0.0.1:0");
    try checking.await(env.server.io());

    // The bytes reached the ledger.
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = a };
    try std.testing.expect(try env.state.db.one(i64, &c, "SELECT COALESCE(SUM(bytes), 0) FROM egress_usage WHERE period LIKE 'd%'", .{}) >= 16);
}
