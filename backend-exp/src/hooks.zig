//! Webhooks that start Code sessions: a signed POST to a hook's URL is queued
//! for the paired host it belongs to and relayed to that host's socket, where
//! the app turns it into a session (its webhook automations).
//!
//! REST (user token, `Authorization: Bearer <access JWT>`):
//!
//!   POST   /v1/hooks          {name, host_id} -> 201 {id, name, host_id, url, secret, created_at}
//!   GET    /v1/hooks          [{id, name, host_id, url, created_at, last_delivery_at, pending}]
//!   DELETE /v1/hooks/:id      204; its queued deliveries go with it
//!
//! The secret (`whk_…`) is shown once, at creation. At most 10 hooks per account.
//!
//! Delivery (public; 30 requests a minute per hook and sender address):
//!
//!   POST /v1/hooks/:id        the sender's raw body, at most 1 MiB (413)
//!
//! Signed in one of two forms (anything else is 401):
//!
//!   - `X-EveryAI-Timestamp: <unix seconds>` and `X-EveryAI-Signature:
//!     sha256=<hex HMAC-SHA256(secret, timestamp + "." + body)>`; the timestamp
//!     must be within 5 minutes of the server's clock. The MAC covers the
//!     timestamp, so a captured request can't be replayed with a fresh one.
//!   - GitHub's `X-Hub-Signature-256: sha256=<hex HMAC-SHA256(secret, body)>`.
//!     It has no timestamp, so replays are caught by the MAC itself: the same
//!     signed body is accepted once while its row is kept (7 days). After
//!     that, a captured GitHub delivery can be replayed undetected. The
//!     unsigned `X-GitHub-Delivery` is not the key (changing it would get a
//!     replay past), and `X-GitHub-Event` is unsigned too: the app uses it
//!     only as a filter hint.
//!
//! Replies: 202 `{delivery_id}`; 200 `{ok, duplicate: true}` for a delivery
//! already accepted (the same signature); 200
//! `{ok}` for GitHub's `ping` (nothing is queued); 404 for an unknown hook;
//! 503 `{code: "host_backlog"}` with `Retry-After` while the host has 20
//! unacked deliveries (or 8 MiB) from this hook.
//!
//! To the host, as a relay text notice (remote.zig):
//! `{"type":"webhook", delivery_id, hook_id, hook_name, received_at, headers:
//! {content-type?, user-agent?, x-github-event?, x-github-delivery?,
//! x-github-hook-id?, x-everyai-event?}, body_b64}`. This notice is **not**
//! end-to-end encrypted: the server reads the body and stores it until the
//! host acks (`{"type":"webhook_ack","delivery_id"}`), a day at most.
//!
//! Flow: the host has at most one delivery per hook in flight, the oldest
//! unacked one. It goes out live when it is the oldest, after `hello` (one
//! per hook), and after the ack of the one before it, so a backlog arrives
//! one by one and never floods the relay queue. The host acks a delivery once
//! it has started its session (or decided not to), and holds it unacked while
//! the hook's last session still runs. A delivery can arrive twice (the app
//! keeps the ids it has seen and queued).
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const util = @import("util.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const secret_prefix = "whk_";
/// The largest body a sender may post.
pub const max_body = 1 << 20;
pub const max_hooks_per_user = 10;
/// How far a signed timestamp may be from the server's clock.
pub const tolerance_seconds = 5 * 60;
/// Unacked deliveries per hook before senders get 503.
pub const max_pending = 20;
pub const max_pending_bytes = 8 << 20;
/// How long an unacked delivery waits for its host.
pub const keep_pending_seconds = 24 * 60 * 60;
/// How long an accepted delivery's row stays as the replay guard.
pub const keep_seen_seconds = 7 * 24 * 60 * 60;

// ------------------------------------------------------------------ signatures

pub const SignatureError = error{ MissingSignature, BadSignature, BadTimestamp, Stale };

/// The signature headers of a request.
pub const Signed = struct {
    everyai: ?[]const u8 = null,
    timestamp: ?[]const u8 = null,
    github: ?[]const u8 = null,
};

/// Whether `header` (`sha256=<hex>`) is the MAC of `parts` under `secret`,
/// compared in constant time; returns the MAC as lower-case hex.
fn macMatches(secret: []const u8, parts: []const []const u8, header: []const u8) SignatureError![64]u8 {
    const prefix = "sha256=";
    if (!std.ascii.startsWithIgnoreCase(header, prefix)) return error.BadSignature;
    const hex = std.mem.trim(u8, header[prefix.len..], " ");
    var got: [HmacSha256.mac_length]u8 = undefined;
    if (hex.len != got.len * 2) return error.BadSignature;
    _ = std.fmt.hexToBytes(&got, hex) catch return error.BadSignature;
    var want: [HmacSha256.mac_length]u8 = undefined;
    var h = HmacSha256.init(secret);
    for (parts) |p| h.update(p);
    h.final(&want);
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, got, want)) return error.BadSignature;
    return std.fmt.bytesToHex(want, .lower);
}

/// Checks a delivery's signature at `now` (unix seconds) and returns its
/// dedup key (written to `buf`): `sig:<hex MAC>`, which only the secret's
/// holder can make for a given body (and timestamp).
pub fn verify(secret: []const u8, s: Signed, body: []const u8, now: i64, buf: []u8) SignatureError![]const u8 {
    if (s.everyai) |sig| {
        const ts_text = s.timestamp orelse return error.MissingSignature;
        const ts = std.fmt.parseInt(i64, std.mem.trim(u8, ts_text, " "), 10) catch return error.BadTimestamp;
        // No arithmetic on `ts`: a sender's value near i64's ends would overflow.
        if (ts < now - tolerance_seconds or ts > now + tolerance_seconds) return error.Stale;
        const mac = try macMatches(secret, &.{ std.mem.trim(u8, ts_text, " "), ".", body }, sig);
        return std.fmt.bufPrint(buf, "sig:{s}", .{&mac}) catch error.BadSignature;
    }
    const sig = s.github orelse return error.MissingSignature;
    const mac = try macMatches(secret, &.{body}, sig);
    return std.fmt.bufPrint(buf, "sig:{s}", .{&mac}) catch error.BadSignature;
}

// ------------------------------------------------------------------ deliveries

/// The request headers passed on to the host (lower-case names). Nothing that
/// could carry a credential: no `Authorization`, cookies or signatures.
pub const Headers = struct {
    @"content-type": ?[]const u8 = null,
    @"user-agent": ?[]const u8 = null,
    @"x-github-event": ?[]const u8 = null,
    @"x-github-delivery": ?[]const u8 = null,
    @"x-github-hook-id": ?[]const u8 = null,
    @"x-everyai-event": ?[]const u8 = null,

    fn of(req: *anole.Request) Headers {
        var out: Headers = .{};
        inline for (@typeInfo(Headers).@"struct".field_names) |n| {
            if (req.headers.get(n)) |v| @field(out, n) = v[0..@min(v.len, 256)];
        }
        return out;
    }
};

const Delivery = struct {
    id: []const u8,
    hook_id: []const u8,
    hook_name: []const u8,
    headers: Headers,
    body: anole.sqlite.Blob,
    created_at: i64,
};

/// The relay notice for `d`.
fn notice(arena: std.mem.Allocator, d: Delivery) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .type = "webhook",
        .delivery_id = d.id,
        .hook_id = d.hook_id,
        .hook_name = d.hook_name,
        .received_at = d.created_at,
        .headers = d.headers,
        // Blob writes itself as base64.
        .body_b64 = d.body,
    }, .{ .emit_null_optional_fields = false });
}

/// Sends `host_id` the oldest unacked delivery of `hook_id`, if there is one:
/// the only one of that hook in flight (see Flow above). From a scratch arena
/// freed here, since a host socket's own arena lives as long as the socket.
fn sendOldest(app: *App, io: std.Io, host_id: []const u8, hook_id: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    var ctx: anole.db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const d = try app.db.optional(Delivery, &ctx,
        \\SELECT d.id, d.hook_id, h.name AS hook_name, d.headers, d.body, d.created_at
        \\FROM hook_deliveries d JOIN hooks h ON h.id = d.hook_id
        \\WHERE d.hook_id = ? AND d.host_id = ? AND d.acked_at IS NULL AND d.body IS NOT NULL AND d.created_at > ?
        \\ORDER BY d.created_at, d.rowid LIMIT 1
    , .{ hook_id, host_id, util.now(io) - keep_pending_seconds }) orelse return;
    app.relay.notifyHost(io, host_id, try notice(arena.allocator(), d));
}

/// Sends `host_id` the oldest unacked delivery of each of its hooks, run once
/// its socket is registered (after `hello`); the rest follow ack by ack. Also
/// drops what is too old to keep. Never under the relay mutex: it reads the
/// database.
pub fn resendPending(app: *App, req: *anole.Request, host_id: []const u8) !void {
    const now = util.now(req.io);
    _ = try app.db.exec(req, "DELETE FROM hook_deliveries WHERE host_id = ? AND created_at < ?", .{ host_id, now - keep_seen_seconds });
    _ = try app.db.exec(req, "UPDATE hook_deliveries SET body = NULL WHERE host_id = ? AND body IS NOT NULL AND created_at < ?", .{ host_id, now - keep_pending_seconds });
    const hook_ids = try app.db.all([]const u8, req,
        \\SELECT DISTINCT hook_id FROM hook_deliveries
        \\WHERE host_id = ? AND acked_at IS NULL AND body IS NOT NULL ORDER BY hook_id
    , .{host_id});
    for (hook_ids) |hook_id| try sendOldest(app, req.io, host_id, hook_id);
}

/// The host took `delivery_id`: its body goes, and the next one of its hook
/// is sent. Only that host's own deliveries; anything else changes nothing.
pub fn ack(app: *App, req: *anole.Request, host_id: []const u8, delivery_id: []const u8) !void {
    const hook_id = try app.db.optional([]const u8, req, "UPDATE hook_deliveries SET body = NULL, acked_at = ? WHERE id = ? AND host_id = ? AND acked_at IS NULL RETURNING hook_id", .{ util.now(req.io), delivery_id, host_id }) orelse return;
    try sendOldest(app, req.io, host_id, hook_id);
}

/// Drops deliveries too old to matter; run at start (main.pruneExpired).
pub fn prune(app: *App, ctx: anytype) !void {
    const now = util.now(ctx.io);
    _ = try app.db.exec(ctx, "DELETE FROM hook_deliveries WHERE created_at < ?", .{now - keep_seen_seconds});
    _ = try app.db.exec(ctx, "UPDATE hook_deliveries SET body = NULL WHERE body IS NOT NULL AND created_at < ?", .{now - keep_pending_seconds});
}

fn deliver(app: *App, req: *anole.Request, res: *anole.Response) !void {
    // The hook first: an unknown one is answered without reading the body.
    const id = req.param("id") orelse return res.fail(.not_found, "no such webhook");
    const hook = try app.db.optional(struct { host_id: []const u8, name: []const u8, secret: []const u8 }, req, "SELECT host_id, name, secret FROM hooks WHERE id = ?", .{id}) orelse
        return res.fail(.not_found, "no such webhook");
    if ((req.content_length orelse 0) > max_body) return res.fail(.payload_too_large, "the body is over 1 MiB");
    const body = (req.body() catch |err| switch (err) {
        error.BodyTooBig => return res.fail(.payload_too_large, "the body is over 1 MiB"),
        else => return err,
    }) orelse "";
    if (body.len > max_body) return res.fail(.payload_too_large, "the body is over 1 MiB");

    const now = util.now(req.io);
    var key_buf: [160]u8 = undefined;
    const dedup = verify(hook.secret, .{
        .everyai = req.headers.get("X-EveryAI-Signature"),
        .timestamp = req.headers.get("X-EveryAI-Timestamp"),
        .github = req.headers.get("X-Hub-Signature-256"),
    }, body, now, &key_buf) catch |err| {
        req.log().info("webhook refused", .{ .hook = id, .reason = @errorName(err) });
        return res.fail(.unauthorized, "invalid signature");
    };

    const headers: Headers = .of(req);
    // GitHub pings a hook when it is created: nothing to start.
    if (headers.@"x-github-event") |e| if (std.mem.eql(u8, e, "ping")) return res.json(.{ .ok = true });

    const backlog = try app.db.one(struct { n: i64, bytes: i64 }, req,
        \\SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS bytes FROM hook_deliveries
        \\WHERE hook_id = ? AND acked_at IS NULL AND body IS NOT NULL AND created_at > ?
    , .{ id, now - keep_pending_seconds });
    if (backlog.n >= max_pending or backlog.bytes + @as(i64, @intCast(body.len)) > max_pending_bytes) {
        res.status = .service_unavailable;
        try res.header("Retry-After", "3600");
        return res.json(.{ .message = "The computer this webhook goes to hasn't picked up its earlier deliveries yet.", .code = "host_backlog" });
    }

    const delivery_id = try util.uuid(req.arena, req.io);
    const inserted = try app.db.optional([]const u8, req,
        \\INSERT INTO hook_deliveries (id, hook_id, host_id, dedup_key, headers, body, size, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (hook_id, dedup_key) DO NOTHING RETURNING id
    , .{ delivery_id, id, hook.host_id, dedup, headers, anole.sqlite.Blob{ .data = body }, body.len, now });
    if (inserted == null) return res.json(.{ .ok = true, .duplicate = true });
    _ = try app.db.exec(req, "UPDATE hooks SET last_delivery_at = ? WHERE id = ?", .{ now, id });

    // Live only when it is the hook's oldest unacked one; otherwise it waits
    // its turn (the ack of the one before it sends it).
    const oldest = try app.db.optional([]const u8, req,
        \\SELECT id FROM hook_deliveries WHERE hook_id = ? AND acked_at IS NULL AND body IS NOT NULL AND created_at > ?
        \\ORDER BY created_at, rowid LIMIT 1
    , .{ id, now - keep_pending_seconds });
    if (oldest) |o| if (std.mem.eql(u8, o, delivery_id)) app.relay.notifyHost(req.io, hook.host_id, try notice(req.arena, .{
        .id = delivery_id,
        .hook_id = id,
        .hook_name = hook.name,
        .headers = headers,
        .body = .{ .data = body },
        .created_at = now,
    }));
    res.status = .accepted;
    try res.json(.{ .delivery_id = delivery_id });
}

// ------------------------------------------------------------------ CRUD

const NewHook = struct {
    name: []const u8,
    host_id: []const u8,

    pub const field_rules = .{
        .name = .{ anole.validate.trim, anole.validate.notBlank, anole.validate.maxLength(100) },
        .host_id = .{ anole.validate.trim, anole.validate.notBlank, anole.validate.maxLength(64) },
    };
};

fn hookUrl(app: *App, arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/v1/hooks/{s}", .{ std.mem.trimEnd(u8, app.cfg.public_url, "/"), id });
}

fn createHook(app: *App, req: *anole.Request, res: *anole.Response, in: anole.In(.{ .body = NewHook })) !void {
    const who = try auth.identity(req);
    _ = try app.db.optional([]const u8, req, "SELECT id FROM remote_hosts WHERE id = ? AND user_id = ?", .{ in.body.host_id, who.user_id }) orelse
        return res.fail(.not_found, "no such host");
    if (try app.db.one(i64, req, "SELECT COUNT(*) FROM hooks WHERE user_id = ?", .{who.user_id}) >= max_hooks_per_user) {
        res.status = .conflict;
        return res.json(.{ .message = "You have 10 webhooks already. Delete one to add another.", .code = "too_many_hooks" });
    }
    const id = try util.uuid(req.arena, req.io);
    const secret = try util.randomToken(req.arena, req.io, secret_prefix);
    const now = util.now(req.io);
    _ = try app.db.exec(req, "INSERT INTO hooks (id, user_id, host_id, name, secret, created_at) VALUES (?, ?, ?, ?, ?, ?)", .{
        id, who.user_id, in.body.host_id, in.body.name, secret, now,
    });
    res.status = .created;
    // The only time the secret is shown.
    try res.json(.{ .id = id, .name = in.body.name, .host_id = in.body.host_id, .url = try hookUrl(app, req.arena, id), .secret = secret, .created_at = now });
}

pub const HookInfo = struct {
    id: []const u8,
    name: []const u8,
    host_id: []const u8,
    url: []const u8 = "",
    created_at: i64,
    last_delivery_at: ?i64,
    /// Deliveries the host hasn't picked up yet.
    pending: i64,
};

fn listHooks(app: *App, req: *anole.Request) ![]HookInfo {
    const who = try auth.identity(req);
    const rows = try app.db.all(HookInfo, req,
        \\SELECT h.id, h.name, h.host_id, h.created_at, h.last_delivery_at,
        \\  (SELECT COUNT(*) FROM hook_deliveries d WHERE d.hook_id = h.id AND d.acked_at IS NULL AND d.body IS NOT NULL) AS pending
        \\FROM hooks h WHERE h.user_id = ? ORDER BY h.created_at
    , .{who.user_id});
    for (rows) |*r| r.url = try hookUrl(app, req.arena, r.id);
    return rows;
}

fn deleteHook(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: []const u8 } })) !void {
    const who = try auth.identity(req);
    if (try app.db.exec(req, "DELETE FROM hooks WHERE id = ? AND user_id = ?", .{ in.path.id, who.user_id }) == 0) return error.NotFound;
}

// ------------------------------------------------------------------ routes

/// One rate-limit bucket per hook and sender address, counted before the
/// signature is checked: someone without the secret who floods the URL fills
/// only their own bucket, not the real sender's.
fn byHook(req: *anole.Request, buf: []u8) []const u8 {
    var addr_buf: [64]u8 = undefined;
    const addr = anole.ratelimit.clientAddress(req, &addr_buf);
    return std.fmt.bufPrint(buf, "hook:{s}:{s}", .{ req.param("id") orelse "", addr }) catch "hook:?";
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    const v1 = app.group("/v1", .{auth.Authenticate{ .app = state }});
    v1.post("/hooks", createHook);
    v1.get("/hooks", listHooks);
    v1.delete("/hooks/:id", deleteHook);
    // Senders have no account here; the hook's signature is the check.
    const limited = anole.ratelimit.Middleware.init(state.limiter.limiter(), .{ .limit = 30, .window = .fromSeconds(60), .key = byHook, .on_error = .deny });
    app.with(.{limited}).post("/v1/hooks/:id", deliver);
}

test "verify: GitHub's documented example" {
    var buf: [160]u8 = undefined;
    const key = try verify("It's a Secret to Everybody", .{
        .github = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17",
    }, "Hello, World!", 0, &buf);
    try std.testing.expectEqualStrings("sig:757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17", key);
    // Upper-case hex is the same MAC, and the same key.
    try std.testing.expectEqualStrings("sig:757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17", try verify("It's a Secret to Everybody", .{
        .github = "sha256=757107EA0EB2509FC211221CCE984B8A37570B6D7586C22C46F4379C8B043E17",
    }, "Hello, World!", 0, &buf));
    try std.testing.expectError(error.BadSignature, verify("It's a Secret to Everybody", .{
        .github = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e18",
    }, "Hello, World!", 0, &buf));
    try std.testing.expectError(error.BadSignature, verify("other", .{
        .github = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17",
    }, "Hello, World!", 0, &buf));
    try std.testing.expectError(error.MissingSignature, verify("s", .{}, "x", 0, &buf));
}

test "verify: the EveryAI form covers the timestamp, within 5 minutes" {
    var buf: [160]u8 = undefined;
    const sign = struct {
        fn hex(secret: []const u8, ts: []const u8, body: []const u8) [71]u8 {
            var mac: [32]u8 = undefined;
            var h = HmacSha256.init(secret);
            h.update(ts);
            h.update(".");
            h.update(body);
            h.final(&mac);
            var out: [71]u8 = undefined;
            _ = std.fmt.bufPrint(&out, "sha256={s}", .{&std.fmt.bytesToHex(mac, .lower)}) catch unreachable;
            return out;
        }
    };
    const now: i64 = 1_800_000_000;
    const at_now = sign.hex("whk_s", "1800000000", "{}");
    try std.testing.expect(std.mem.startsWith(u8, try verify("whk_s", .{ .everyai = &at_now, .timestamp = "1800000000" }, "{}", now, &buf), "sig:"));
    // The edges of the window.
    const early = sign.hex("whk_s", "1799999700", "{}");
    _ = try verify("whk_s", .{ .everyai = &early, .timestamp = "1799999700" }, "{}", now, &buf);
    const late = sign.hex("whk_s", "1800000300", "{}");
    _ = try verify("whk_s", .{ .everyai = &late, .timestamp = "1800000300" }, "{}", now, &buf);
    const stale = sign.hex("whk_s", "1799999699", "{}");
    try std.testing.expectError(error.Stale, verify("whk_s", .{ .everyai = &stale, .timestamp = "1799999699" }, "{}", now, &buf));
    const future = sign.hex("whk_s", "1800000301", "{}");
    try std.testing.expectError(error.Stale, verify("whk_s", .{ .everyai = &future, .timestamp = "1800000301" }, "{}", now, &buf));
    // A fresh timestamp on an old signature doesn't match.
    try std.testing.expectError(error.BadSignature, verify("whk_s", .{ .everyai = &early, .timestamp = "1800000000" }, "{}", now, &buf));
    try std.testing.expectError(error.MissingSignature, verify("whk_s", .{ .everyai = &at_now }, "{}", now, &buf));
    try std.testing.expectError(error.BadTimestamp, verify("whk_s", .{ .everyai = &at_now, .timestamp = "soon" }, "{}", now, &buf));
    // i64's ends are stale, not an overflow (which panics the server in ReleaseSafe).
    try std.testing.expectError(error.Stale, verify("whk_s", .{ .everyai = "sha256=00", .timestamp = "-9223372036854775808" }, "{}", now, &buf));
    try std.testing.expectError(error.Stale, verify("whk_s", .{ .everyai = "sha256=00", .timestamp = "9223372036854775807" }, "{}", now, &buf));
}
