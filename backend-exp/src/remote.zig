//! Remote hosts for Code sessions: a desktop that runs the agent sidecar (the
//! host) and the user's other devices (clients) meet here, and the backend
//! relays their WebSocket frames. The frames are end-to-end encrypted by the
//! endpoints; the backend routes them by channel and never parses a payload.
//!
//! An account is optional (owner, 2026-11-08): the `rh_`/`rd_` tokens are
//! the identity, anchored by the endpoints' keys exchanged at pairing (the
//! QR carries the host's fingerprint). A host made without an account
//! belongs to the reserved `anonymous` user until an account claims it
//! (`POST /v1/remote/hosts/:id/claim`, JWT + host token); idle anonymous
//! hosts expire after ANON_HOST_IDLE_DAYS. A host's lifecycle:
//!
//!   anonymous ──claim──► claimed            (either) ──DELETE──► revoked
//!   anonymous ──idle N days──► expired
//!
//! Egress (egress.zig): each relay socket is admitted by the gate (one FIFO
//! queue when full, `queued {position}` notices), every relayed byte is
//! counted against the host (anonymous) or its account (claimed), paced to
//! the server's rate, and past a quota the socket gets `budget {resets_at}`
//! and closes 4008.
//!
//! REST (an access JWT is optional unless marked):
//!
//!   POST   /v1/remote/hosts               {name, platform?, public_key} -> 201 {id, name, platform, public_key, host_token}
//!   GET    /v1/remote/hosts               (JWT) the account's claimed hosts: [{id, name, platform, public_key, online, created_at, last_seen_at, devices: [...]}]
//!   POST   /v1/remote/hosts/:id/claim     (JWT + X-Remote-Host-Token) adds the host and its devices to the account; 409 when another account has it
//!   DELETE /v1/remote/hosts/:id           (+ X-Remote-Host-Token) revokes the host, its devices and live sockets
//!   DELETE /v1/remote/devices/:id         (+ X-Remote-Host-Token or X-Remote-Device-Token) unpairs one device
//!   POST   /v1/remote/pair                (+ X-Remote-Host-Token) {host_id} -> 201 {id, code, host_id, expires_at}
//!   POST   /v1/remote/pair/redeem         {code, device_name, public_key} -> {id, status, device_id, device_token, decide_by, host}
//!   GET    /v1/remote/pair/:id            (+ X-Remote-Device-Token of the redeeming device, or the host's token) {id, status, host_id, device_id}
//!   POST   /v1/remote/pair/:id/approve    (+ X-Remote-Host-Token) -> {id, status}
//!   POST   /v1/remote/pair/:id/deny       (+ X-Remote-Host-Token) -> {id, status}
//!
//! WebSockets (the host's or device's token in `Authorization: Bearer` or
//! `?token=`; nothing else):
//!
//!   GET /v1/remote/host                   the host, with its `rh_` token
//!   GET /v1/remote/client/:host_id        a paired device, with its `rd_` token
//!
//! Framing. Binary frames carry data; text frames are the relay's JSON
//! notices. A client sends and receives bare binary payloads. The host's
//! binary frames start with the 4-byte big-endian channel of the client they
//! come from or go to. Notices to the host: `hello {host_id, clients}`,
//! `client_open {channel, device_id, device_name, public_key}`,
//! `client_close {channel}`, `pair_request {pairing_id, device}`,
//! `webhook {delivery_id, hook_id, hook_name, received_at, headers, body_b64}`,
//! `replaced`, `revoked`, `queued {position}`, `budget {resets_at}`. Notices
//! to a client: `hello {channel, host_online}`, `host_online`,
//! `host_offline`, `closed`, `revoked`, `queued {position}`,
//! `budget {resets_at}`. The
//! host may send `{"type":"close_channel","channel":N}` to drop a client and
//! `{"type":"webhook_ack","delivery_id":"…"}` once it took a webhook.
//!
//! The `webhook` notice is the exception to "never parses a payload": it
//! carries a webhook sender's body, which the server reads, verifies and
//! queues until the ack (hooks.zig). It is not end-to-end encrypted.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const util = @import("util.zig");
const hooks = @import("hooks.zig");
const egress = @import("egress.zig");
const magic = @import("magic.zig");
const websocket = anole.websocket;

/// The owner of hosts, devices and pairings made without an account.
pub const anonymous_user = "anonymous";

pub const host_token_prefix = "rh_";
pub const device_token_prefix = "rd_";
/// How long a pairing code can be redeemed.
pub const code_ttl_seconds = 5 * 60;
/// How long the host has to approve a redeemed code.
pub const decide_ttl_seconds = 10 * 60;
/// The largest relayed payload.
pub const max_payload = 4 << 20;
/// The channel prefix on the host's binary frames.
pub const channel_len = 4;

/// Close codes the relay sends (the 4000 range is the application's).
pub const close_replaced: u16 = 4001;
pub const close_revoked: u16 = 4003;

/// The largest text (control) frame a host may send: its controls are a few
/// short fields. Bigger ones are skipped unread.
pub const max_control = 4 << 10;
/// Control frames a host socket may send per minute before it is closed.
pub const max_controls_per_minute = 600;

/// Code alphabet: 32 symbols without I, O, 0 and 1, so a byte maps without
/// bias and nothing reads as something else.
const code_alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
pub const code_len = 8;

const upgrade_options: websocket.UpgradeOptions = .{
    // Tokens, not cookies, authorize these sockets.
    .allowed_origins = .any,
    .max_message_size = max_payload + channel_len,
};

// ------------------------------------------------------------------ relay state

/// Who is connected right now. Memory comes from `smp_allocator` so the
/// state needs no setup in `App`; the server's `Rooms` hold the sockets and
/// queue the frames, so a slow peer never stalls the others.
pub const Relay = struct {
    rooms: websocket.Rooms = .init(std.heap.smp_allocator, .{ .max_queued_bytes = 16 << 20 }),
    mutex: std.Io.Mutex = .init,
    /// Host id (owned) -> the generation of its live socket.
    hosts: std.StringHashMapUnmanaged(u64) = .empty,
    channels: std.AutoHashMapUnmanaged(u32, Channel) = .empty,
    next_channel: u32 = 1,
    next_gen: u64 = 1,

    const gpa = std.heap.smp_allocator;

    pub const Channel = struct {
        host_id: []u8,
        device_id: []u8,
        device_name: []u8,
        public_key: []u8,

        fn free(c: Channel) void {
            gpa.free(c.host_id);
            gpa.free(c.device_id);
            gpa.free(c.device_name);
            gpa.free(c.public_key);
        }
    };

    pub fn deinit(self: *Relay) void {
        self.rooms.deinit();
        var hosts = self.hosts.keyIterator();
        while (hosts.next()) |k| gpa.free(k.*);
        self.hosts.deinit(gpa);
        var channels = self.channels.valueIterator();
        while (channels.next()) |c| c.free();
        self.channels.deinit(gpa);
    }

    pub fn online(self: *Relay, io: std.Io, host_id: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.hosts.contains(host_id);
    }

    /// A notice to the host's live socket, if it has one. Under the mutex.
    fn toHostLocked(self: *Relay, host_id: []const u8, text: []const u8) void {
        const gen = self.hosts.get(host_id) orelse return;
        var buf: [96]u8 = undefined;
        _ = self.rooms.broadcast(hostRoom(&buf, host_id, gen), .text, text, null);
    }

    fn toClient(self: *Relay, channel: u32, msg_type: websocket.MessageType, data: []const u8) void {
        var buf: [16]u8 = undefined;
        _ = self.rooms.broadcast(clientRoom(&buf, channel), msg_type, data, null);
    }

    /// Notifies `host_id`'s socket, if connected.
    pub fn notifyHost(self: *Relay, io: std.Io, host_id: []const u8, text: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.toHostLocked(host_id, text);
    }

    /// Drops every channel of `device_id` (or, with `host_id`, of that
    /// host): the clients are told `revoked` and their next frame closes
    /// them.
    fn dropChannelsLocked(self: *Relay, io: std.Io, device_id: ?[]const u8, host_id: ?[]const u8) void {
        _ = io;
        var doomed: [64]u32 = undefined;
        while (true) {
            var n: usize = 0;
            var it = self.channels.iterator();
            while (it.next()) |e| {
                const hit = if (device_id) |d| std.mem.eql(u8, e.value_ptr.device_id, d) else std.mem.eql(u8, e.value_ptr.host_id, host_id.?);
                if (!hit) continue;
                doomed[n] = e.key_ptr.*;
                n += 1;
                if (n == doomed.len) break;
            }
            if (n == 0) return;
            for (doomed[0..n]) |ch| {
                const kv = self.channels.fetchRemove(ch).?;
                self.toClient(ch, .text, "{\"type\":\"revoked\"}");
                if (host_id == null) {
                    var buf: [64]u8 = undefined;
                    self.toHostLocked(kv.value.host_id, std.fmt.bufPrint(&buf, "{{\"type\":\"client_close\",\"channel\":{d}}}", .{ch}) catch unreachable);
                }
                kv.value.free();
            }
        }
    }

    pub fn revokeDevice(self: *Relay, io: std.Io, device_id: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.dropChannelsLocked(io, device_id, null);
    }

    pub fn revokeHost(self: *Relay, io: std.Io, host_id: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.dropChannelsLocked(io, null, host_id);
        self.toHostLocked(host_id, "{\"type\":\"revoked\"}");
        if (self.hosts.fetchRemove(host_id)) |kv| gpa.free(kv.key);
    }
};

fn hostRoom(buf: []u8, host_id: []const u8, gen: u64) []const u8 {
    return std.fmt.bufPrint(buf, "h:{s}:{d}", .{ host_id, gen }) catch unreachable;
}

fn clientRoom(buf: []u8, channel: u32) []const u8 {
    return std.fmt.bufPrint(buf, "c:{d}", .{channel}) catch unreachable;
}

/// The channel and payload of a host's binary frame; null when it is too
/// short or names channel 0.
pub fn splitFrame(frame: []const u8) ?struct { channel: u32, payload: []const u8 } {
    if (frame.len < channel_len) return null;
    const channel = std.mem.readInt(u32, frame[0..channel_len], .big);
    if (channel == 0) return null;
    return .{ .channel = channel, .payload = frame[channel_len..] };
}

// ------------------------------------------------------------------ pairing codes

/// A fresh code: `code_len` symbols of `code_alphabet`.
pub fn newCode(io: std.Io) ![code_len]u8 {
    var bytes: [code_len]u8 = undefined;
    try io.randomSecure(&bytes);
    var out: [code_len]u8 = undefined;
    for (bytes, &out) |b, *c| c.* = code_alphabet[b & 31];
    return out;
}

/// `ABCD-EFGH`, as shown beside the QR code.
pub fn displayCode(arena: std.mem.Allocator, code: [code_len]u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}-{s}", .{ code[0..4], code[4..] });
}

/// What a person typed, as stored: upper case, without dashes and spaces.
/// Null when it cannot be a code.
pub fn normalizeCode(buf: *[code_len]u8, typed: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (typed) |ch| {
        if (ch == '-' or ch == ' ') continue;
        const up = std.ascii.toUpper(ch);
        if (std.mem.indexOfScalar(u8, code_alphabet, up) == null) return null;
        if (n == code_len) return null;
        buf[n] = up;
        n += 1;
    }
    return if (n == code_len) buf[0..n] else null;
}

// ------------------------------------------------------------------ REST

const HostRow = struct { id: []const u8, user_id: []const u8, name: []const u8 };

/// Whom a host's relayed bytes count against: its account once claimed,
/// else the host itself.
pub fn subjectOf(user_id: []const u8, host_id: []const u8) egress.Subject {
    return if (std.mem.eql(u8, user_id, anonymous_user)) .{ .kind = .host, .id = host_id } else .{ .kind = .account, .id = user_id };
}

pub const DeviceInfo = struct {
    id: []const u8,
    host_id: []const u8,
    name: []const u8,
    public_key: []const u8,
    created_at: i64,
    last_seen_at: ?i64,
};

pub const HostInfo = struct {
    id: []const u8,
    name: []const u8,
    platform: []const u8,
    public_key: []const u8,
    online: bool,
    created_at: i64,
    last_seen_at: ?i64,
    devices: []const DeviceInfo,
};

const NewHost = struct {
    name: []const u8,
    platform: []const u8 = "",
    public_key: []const u8,

    pub const field_rules = .{
        .name = .{ anole.validate.trim, anole.validate.notBlank, anole.validate.maxLength(100) },
        .platform = .{anole.validate.maxLength(40)},
        .public_key = .{ anole.validate.trim, anole.validate.notBlank, anole.validate.maxLength(512) },
    };
};

fn createHost(app: *App, req: *anole.Request, in: anole.In(.{ .body = NewHost })) !anole.Created(struct {
    id: []const u8,
    name: []const u8,
    platform: []const u8,
    public_key: []const u8,
    host_token: []const u8,
}) {
    const owner = if (auth.optionalIdentity(req)) |who| who.user_id else anonymous_user;
    var ip_buf: [64]u8 = undefined;
    const network = magic.ipPrefix(req, &ip_buf);
    const now = util.now(req.io);
    if (std.mem.eql(u8, owner, anonymous_user)) {
        try prune(app, req);
        // Anyone can make one: limited per network, by the hour and in all.
        const made = try app.db.one(struct { hour: i64, live: i64 }, req,
            \\SELECT COALESCE(SUM(created_at > ?), 0) AS hour, COUNT(*) AS live
            \\FROM remote_hosts WHERE created_ip = ? AND user_id = ?
        , .{ now - 3600, network, anonymous_user });
        if (made.hour >= app.cfg.anon_hosts_per_hour or made.live >= app.cfg.anon_hosts_per_network) return error.TooManyRequests;
    }
    const id = try util.uuid(req.arena, req.io);
    const token = try util.randomToken(req.arena, req.io, host_token_prefix);
    _ = try app.db.exec(req, "INSERT INTO remote_hosts (id, user_id, name, platform, public_key, token_hash, created_at, created_ip, claimed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", .{
        id,  owner,   in.body.name,                                              in.body.platform, in.body.public_key, try util.sha256Hex(req.arena, token),
        now, network, if (std.mem.eql(u8, owner, anonymous_user)) null else now,
    });
    // The only time the token is shown.
    return .{ .value = .{ .id = id, .name = in.body.name, .platform = in.body.platform, .public_key = in.body.public_key, .host_token = token } };
}

fn listHosts(app: *App, req: *anole.Request) ![]const HostInfo {
    const who = try auth.identity(req);
    const Row = struct { id: []const u8, name: []const u8, platform: []const u8, public_key: []const u8, created_at: i64, last_seen_at: ?i64 };
    const rows = try app.db.all(Row, req, "SELECT id, name, platform, public_key, created_at, last_seen_at FROM remote_hosts WHERE user_id = ? ORDER BY created_at DESC", .{who.user_id});
    const devices = try app.db.all(DeviceInfo, req, "SELECT id, host_id, name, public_key, created_at, last_seen_at FROM remote_devices WHERE user_id = ? AND approved = 1 ORDER BY created_at", .{who.user_id});
    const out = try req.arena.alloc(HostInfo, rows.len);
    for (rows, out) |r, *h| {
        var mine: std.ArrayList(DeviceInfo) = .empty;
        for (devices) |d| if (std.mem.eql(u8, d.host_id, r.id)) try mine.append(req.arena, d);
        h.* = .{
            .id = r.id,
            .name = r.name,
            .platform = r.platform,
            .public_key = r.public_key,
            .online = app.relay.online(req.io, r.id),
            .created_at = r.created_at,
            .last_seen_at = r.last_seen_at,
            .devices = mine.items,
        };
    }
    return out;
}

/// Only the host itself (its `X-Remote-Host-Token`) removes it: an account
/// can be shared (the dev user), and the token is the desktop's alone.
fn deleteHost(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: []const u8 } })) !void {
    const host = try tokenHostNamed(app, req, in.path.id);
    // Its devices and pairings go with it (ON DELETE CASCADE; Anole's SQLite
    // turns foreign keys on).
    if (try app.db.exec(req, "DELETE FROM remote_hosts WHERE id = ?", .{host.id}) == 0) return error.NotFound;
    app.relay.revokeHost(req.io, host.id);
}

/// The device's host (`X-Remote-Host-Token`) or the device itself
/// (`X-Remote-Device-Token`) unpairs it.
fn deleteDevice(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: []const u8 } })) !void {
    const device = try app.db.optional(struct { host_id: []const u8, token_hash: []const u8 }, req, "SELECT host_id, token_hash FROM remote_devices WHERE id = ?", .{in.path.id}) orelse return error.NotFound;
    if (req.headers.get("X-Remote-Device-Token")) |token| {
        if (!std.mem.eql(u8, try util.sha256Hex(req.arena, token), device.token_hash)) return error.Unauthorized;
    } else {
        _ = try tokenHostNamed(app, req, device.host_id);
    }
    if (try app.db.exec(req, "DELETE FROM remote_devices WHERE id = ?", .{in.path.id}) == 0) return error.NotFound;
    app.relay.revokeDevice(req.io, in.path.id);
}

fn pair(app: *App, req: *anole.Request, in: anole.In(.{ .body = struct { host_id: []const u8 } })) !anole.Created(struct {
    id: []const u8,
    code: []const u8,
    host_id: []const u8,
    expires_at: i64,
}) {
    // Only the desktop mints codes for itself: on a shared account (the dev
    // user) anyone could otherwise send it pair requests.
    const host = try tokenHostNamed(app, req, in.body.host_id);
    const code = try newCode(req.io);
    const id = try util.uuid(req.arena, req.io);
    const now = util.now(req.io);
    const expires_at = now + code_ttl_seconds;
    _ = try app.db.exec(req, "INSERT INTO remote_pairings (id, user_id, host_id, code_hash, expires_at, created_at) VALUES (?, ?, ?, ?, ?, ?)", .{
        id, host.user_id, host.id, try util.sha256Hex(req.arena, &code), expires_at, now,
    });
    return .{ .value = .{ .id = id, .code = try displayCode(req.arena, code), .host_id = in.body.host_id, .expires_at = expires_at } };
}

const Redeem = struct {
    code: []const u8,
    device_name: []const u8,
    public_key: []const u8,

    pub const field_rules = .{
        .device_name = .{ anole.validate.trim, anole.validate.notBlank, anole.validate.maxLength(100) },
        .public_key = .{ anole.validate.trim, anole.validate.notBlank, anole.validate.maxLength(512) },
    };
};

/// A device redeems a code, with or without an account: the code (shown on
/// the host's screen) and the host's approval decide. The code is spent at
/// once; the device waits for the host to approve it. The device belongs to
/// the host's owner (anonymous until the host is claimed).
fn redeem(app: *App, req: *anole.Request, in: anole.In(.{ .body = Redeem })) !struct {
    id: []const u8,
    status: []const u8 = "pending",
    device_id: []const u8,
    device_token: []const u8,
    decide_by: i64,
    host: struct { id: []const u8, name: []const u8, platform: []const u8, public_key: []const u8 },
} {
    var buf: [code_len]u8 = undefined;
    // Wrong, spent and expired codes all look the same.
    const code = normalizeCode(&buf, in.body.code) orelse return error.NotFound;
    const now = util.now(req.io);
    const digest = try util.sha256Hex(req.arena, code);
    const target = try app.db.optional([]const u8, req, "SELECT host_id FROM remote_pairings WHERE code_hash = ? AND status = 'open' AND expires_at > ?", .{ digest, now }) orelse return error.NotFound;
    // A host holds at most DEVICES_PER_HOST devices (paired or waiting).
    if (try app.db.one(i64, req, "SELECT COUNT(*) FROM remote_devices WHERE host_id = ?", .{target}) >= app.cfg.devices_per_host) return error.Conflict;
    const claimed = try app.db.optional(struct { id: []const u8, host_id: []const u8 }, req,
        \\UPDATE remote_pairings SET status = 'pending'
        \\WHERE code_hash = ? AND status = 'open' AND expires_at > ?
        \\RETURNING id, host_id
    , .{ digest, now }) orelse return error.NotFound;
    const host = try app.db.one(struct { id: []const u8, user_id: []const u8, name: []const u8, platform: []const u8, public_key: []const u8 }, req, "SELECT id, user_id, name, platform, public_key FROM remote_hosts WHERE id = ?", .{claimed.host_id});

    const device_id = try util.uuid(req.arena, req.io);
    const token = try util.randomToken(req.arena, req.io, device_token_prefix);
    _ = try app.db.exec(req, "INSERT INTO remote_devices (id, user_id, host_id, name, public_key, token_hash, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", .{
        device_id, host.user_id, host.id, in.body.device_name, in.body.public_key, try util.sha256Hex(req.arena, token), now,
    });
    const decide_by = now + decide_ttl_seconds;
    _ = try app.db.exec(req, "UPDATE remote_pairings SET device_id = ?, decide_by = ? WHERE id = ?", .{ device_id, decide_by, claimed.id });

    app.relay.notifyHost(req.io, host.id, try std.json.Stringify.valueAlloc(req.arena, .{
        .type = "pair_request",
        .pairing_id = claimed.id,
        .decide_by = decide_by,
        .device = .{ .id = device_id, .name = in.body.device_name, .public_key = in.body.public_key },
    }, .{}));
    return .{ .id = claimed.id, .device_id = device_id, .device_token = token, .decide_by = decide_by, .host = .{ .id = host.id, .name = host.name, .platform = host.platform, .public_key = host.public_key } };
}

/// `open`, `pending`, `approved`, `denied` or `expired`.
fn effectiveStatus(status: []const u8, expires_at: i64, decide_by: ?i64, now: i64) []const u8 {
    if (std.mem.eql(u8, status, "open") and expires_at <= now) return "expired";
    if (std.mem.eql(u8, status, "pending") and (decide_by orelse 0) <= now) return "expired";
    return status;
}

fn pairStatus(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: []const u8 } })) !struct {
    id: []const u8,
    status: []const u8,
    host_id: []const u8,
    device_id: ?[]const u8,
} {
    const p = try app.db.optional(struct { status: []const u8, host_id: []const u8, device_id: ?[]const u8, expires_at: i64, decide_by: ?i64 }, req, "SELECT status, host_id, device_id, expires_at, decide_by FROM remote_pairings WHERE id = ?", .{in.path.id}) orelse return error.NotFound;
    // The device that redeemed it (its token), or the host.
    if (req.headers.get("X-Remote-Device-Token")) |token| {
        const device_id = p.device_id orelse return error.NotFound;
        const ok = try app.db.optional(i64, req, "SELECT 1 FROM remote_devices WHERE id = ? AND token_hash = ?", .{ device_id, try util.sha256Hex(req.arena, token) });
        if (ok == null) return error.NotFound;
    } else {
        _ = tokenHostNamed(app, req, p.host_id) catch return error.NotFound;
    }
    return .{ .id = in.path.id, .status = effectiveStatus(p.status, p.expires_at, p.decide_by, util.now(req.io)), .host_id = p.host_id, .device_id = p.device_id };
}

/// The host behind `X-Remote-Host-Token`: the token alone is the host's
/// identity (an account is optional).
pub fn tokenHost(app: *App, req: *anole.Request) !HostRow {
    const token = req.headers.get("X-Remote-Host-Token") orelse return error.Unauthorized;
    return try app.db.optional(HostRow, req, "SELECT id, user_id, name FROM remote_hosts WHERE token_hash = ?", .{try util.sha256Hex(req.arena, token)}) orelse error.Unauthorized;
}

/// [tokenHost], which must be `host_id`: another host's token finds nothing.
pub fn tokenHostNamed(app: *App, req: *anole.Request, host_id: []const u8) !HostRow {
    const host = try tokenHost(app, req);
    if (!std.mem.eql(u8, host.id, host_id)) return error.NotFound;
    return host;
}

/// `POST /v1/remote/hosts/:id/claim` (signed in, + X-Remote-Host-Token):
/// the host, its devices and pairings join the account; claimed hosts never
/// expire and count against the account's relay quota. Claiming again is a
/// no-op; another account's host is a 409.
fn claimHost(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: []const u8 } })) !struct { id: []const u8, claimed: bool } {
    const who = try auth.identity(req);
    const host = try tokenHostNamed(app, req, in.path.id);
    if (std.mem.eql(u8, host.user_id, who.user_id)) return .{ .id = host.id, .claimed = true };
    if (!std.mem.eql(u8, host.user_id, anonymous_user)) return error.Conflict;
    const now = util.now(req.io);
    if (try app.db.exec(req, "UPDATE remote_hosts SET user_id = ?, claimed_at = ? WHERE id = ? AND user_id = ?", .{ who.user_id, now, host.id, anonymous_user }) == 0) return error.Conflict;
    _ = try app.db.exec(req, "UPDATE remote_devices SET user_id = ? WHERE host_id = ?", .{ who.user_id, host.id });
    _ = try app.db.exec(req, "UPDATE remote_pairings SET user_id = ? WHERE host_id = ?", .{ who.user_id, host.id });
    return .{ .id = host.id, .claimed = true };
}

/// The host behind `X-Remote-Host-Token`, which must belong to the caller
/// (webhooks, which need an account).
pub fn callingHost(app: *App, req: *anole.Request) !HostRow {
    const who = try auth.identity(req);
    const token = req.headers.get("X-Remote-Host-Token") orelse return error.Unauthorized;
    const host = try app.db.optional(HostRow, req, "SELECT id, user_id, name FROM remote_hosts WHERE token_hash = ?", .{try util.sha256Hex(req.arena, token)}) orelse return error.Unauthorized;
    if (!std.mem.eql(u8, host.user_id, who.user_id)) return error.Unauthorized;
    return host;
}

/// [callingHost], which must be `host_id`: another host's token finds nothing.
pub fn hostNamed(app: *App, req: *anole.Request, host_id: []const u8) !HostRow {
    const host = try callingHost(app, req);
    if (!std.mem.eql(u8, host.id, host_id)) return error.NotFound;
    return host;
}

const Decision = struct { id: []const u8, status: []const u8 };

fn decide(app: *App, req: *anole.Request, id: []const u8, approve: bool) !Decision {
    const host = try tokenHost(app, req);
    const now = util.now(req.io);
    const device_id = try app.db.optional(?[]const u8, req,
        \\UPDATE remote_pairings SET status = ?, decided_at = ?
        \\WHERE id = ? AND host_id = ? AND status = 'pending' AND decide_by > ?
        \\RETURNING device_id
    , .{ if (approve) "approved" else "denied", now, id, host.id, now }) orelse return error.NotFound;
    const device = device_id orelse return error.NotFound;
    if (approve) {
        _ = try app.db.exec(req, "UPDATE remote_devices SET approved = 1 WHERE id = ?", .{device});
    } else {
        _ = try app.db.exec(req, "DELETE FROM remote_devices WHERE id = ?", .{device});
    }
    return .{ .id = id, .status = if (approve) "approved" else "denied" };
}

fn approvePairing(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: []const u8 } })) !Decision {
    return decide(app, req, in.path.id, true);
}

fn denyPairing(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: []const u8 } })) !Decision {
    return decide(app, req, in.path.id, false);
}

/// Anonymous hosts nobody connected for ANON_HOST_IDLE_DAYS go (their
/// devices and pairings with them); claimed ones stay. Egress rows older
/// than two months go too. Runs at start and whenever a host is made.
pub fn prune(app: *App, ctx: anytype) !void {
    const now = util.now(ctx.io);
    _ = try app.db.exec(ctx, "DELETE FROM remote_hosts WHERE user_id = ? AND COALESCE(last_seen_at, created_at) < ?", .{ anonymous_user, now - app.cfg.anon_host_idle_days * 86_400 });
    const p = egress.Periods.of(now);
    _ = try app.db.exec(ctx, "DELETE FROM egress_usage WHERE (period LIKE 'd%' AND CAST(substr(period, 2) AS INTEGER) < ?) OR (period LIKE 'm%' AND CAST(substr(period, 2) AS INTEGER) < ?)", .{ p.day - 62, p.month - 2 });
}

// ------------------------------------------------------------------ egress

const mib: u64 = 1 << 20;

/// The gate and its config limits, with this day's and month's bytes read
/// back from `egress_usage` (run once, in `prepare`).
pub fn setUpEgress(app: *App, ctx: anytype) !void {
    const c = app.cfg;
    app.egress_quotas = .{
        .host = .{ .daily_bytes = c.relay_host_daily_mb * mib, .monthly_bytes = c.relay_host_monthly_mb * mib },
        .account = .{ .daily_bytes = c.relay_account_daily_mb * mib, .monthly_bytes = c.relay_account_monthly_mb * mib },
    };
    app.egress = egress.Gate.init(app.gpa, .{
        .rate_bytes_per_s = c.egress_rate_mbps * 1_000_000 / 8,
        .monthly_bytes = c.egress_monthly_gb * 1024 * mib,
        .warn_share = if (c.egress_warn_gb > 0 and c.egress_monthly_gb > 0) @as(f64, @floatFromInt(c.egress_warn_gb)) / @as(f64, @floatFromInt(c.egress_monthly_gb)) else 0.8,
        .max_live = c.relay_max_live,
        .per_subject_live = c.relay_per_subject_live,
    }, app.egress_quotas.source());
    const now = util.now(ctx.io);
    const p = egress.Periods.of(now);
    const day = try std.fmt.allocPrint(ctx.arena, "d{d}", .{p.day});
    const month = try std.fmt.allocPrint(ctx.arena, "m{d}", .{p.month});
    const rows = try app.db.all(egress.Gate.Row, ctx, "SELECT subject, period, bytes FROM egress_usage WHERE period IN (?, ?)", .{ day, month });
    try app.egress.load(ctx.io, rows, now);
}

/// Adds the bytes counted since the last flush to `egress_usage`.
pub fn flushEgress(app: *App, ctx: anytype) !void {
    const rows = try app.egress.drain(ctx.io, ctx.arena, util.now(ctx.io));
    for (rows) |r| _ = try app.db.exec(ctx,
        \\INSERT INTO egress_usage (subject, period, bytes) VALUES (?, ?, ?)
        \\ON CONFLICT(subject, period) DO UPDATE SET bytes = bytes + excluded.bytes
    , .{ r.subject, r.period, r.bytes });
}

/// How long a socket may wait in the queue before it is told to retry.
const max_queue_wait_s = 15 * 60;

/// Waits for the gate to admit this socket, telling it its place in line.
/// False when it was refused (and closed): over quota or its share used.
fn admitSocket(app: *App, ws: *websocket.Socket, req: *anole.Request, subject: egress.Subject, ticket: *egress.Gate.Ticket) !bool {
    const io = req.io;
    const started = util.now(io);
    var told: u32 = 0;
    while (true) {
        switch (try app.egress.admit(io, subject, ticket, util.now(io))) {
            .admitted => return true,
            .queued => |position| {
                if (position != told) {
                    told = position;
                    try ws.send(.text, try std.fmt.allocPrint(req.arena, "{{\"type\":\"queued\",\"position\":{d}}}", .{position}));
                }
                if (util.now(io) - started >= max_queue_wait_s) {
                    ws.close(@fromBackingInt(1013), "relay busy") catch {};
                    return false;
                }
                try io.sleep(.fromSeconds(1), .awake);
            },
            .subject_full => {
                ws.close(.policy_violation, "too many relay connections for this host or account") catch {};
                return false;
            },
            .over_quota => {
                try sendBudget(app, ws, req, subject);
                return false;
            },
        }
    }
}

fn sendBudget(app: *App, ws: *websocket.Socket, req: *anole.Request, subject: egress.Subject) !void {
    const resets = app.egress.resetsAt(req.io, subject, util.now(req.io));
    ws.send(.text, try std.fmt.allocPrint(req.arena, "{{\"type\":\"budget\",\"resets_at\":{d}}}", .{resets})) catch {};
    ws.close(@fromBackingInt(@intCast(egress.close_over_quota)), "relay limit reached") catch {};
}

/// Counts `n` relayed bytes and waits out the server's rate. False when a
/// quota is spent (the socket was told and closed).
fn spendRelay(app: *App, ws: *websocket.Socket, req: *anole.Request, subject: egress.Subject, n: usize) !bool {
    const io = req.io;
    switch (try app.egress.spend(io, subject, n, std.Io.Clock.real.now(io).nanoseconds)) {
        .ok => {},
        .wait_ns => |ns| try io.sleep(.fromNanoseconds(@intCast(ns)), .awake),
        .over_quota => {
            try sendBudget(app, ws, req, subject);
            return false;
        },
    }
    if (app.egress.flushDue(io, util.now(io))) {
        var ctx: anole.db.Ctx = .{ .io = io, .arena = req.arena };
        flushEgress(app, &ctx) catch |err| req.log().warn("egress flush failed", .{ .err = @errorName(err) });
    }
    return true;
}

// ------------------------------------------------------------------ WebSockets

/// `Authorization: Bearer <token>`, else `?token=` (browsers cannot set
/// headers on a WebSocket).
fn socketToken(req: *anole.Request) ?[]const u8 {
    if (req.headers.get("Authorization")) |h| {
        if (std.ascii.startsWithIgnoreCase(h, "Bearer ")) return std.mem.trim(u8, h[7..], " ");
    }
    return req.query.get("token");
}

fn hostSocket(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const token = socketToken(req) orelse return res.fail(.unauthorized, "host token required");
    if (!std.mem.startsWith(u8, token, host_token_prefix)) return res.fail(.unauthorized, "host token required");
    const host = try app.db.optional(HostRow, req, "SELECT id, user_id, name FROM remote_hosts WHERE token_hash = ?", .{try util.sha256Hex(req.arena, token)}) orelse
        return res.fail(.unauthorized, "unknown host token");
    var ws = (try websocket.upgrade(req, res, upgrade_options)) orelse return res.fail(.upgrade_required, "this endpoint speaks WebSocket");
    defer ws.deinit();
    const subject = subjectOf(host.user_id, host.id);
    var ticket: egress.Gate.Ticket = .{ .id = 0 };
    defer {
        app.egress.leave(req.io, &ticket);
        var ctx: anole.db.Ctx = .{ .io = req.io, .arena = req.arena };
        flushEgress(app, &ctx) catch {};
    }
    if (!try admitSocket(app, &ws, req, subject, &ticket)) return;
    serveHost(app, &ws, req, host, subject) catch |err| {
        if (err == error.Canceled) return err;
        req.log().warn("remote host socket failed", .{ .host = host.id, .err = @errorName(err) });
        if (!ws.isClosed()) ws.close(.internal_error, "") catch {};
        return;
    };
    if (!ws.isClosed()) ws.close(.normal, "") catch {};
}

fn serveHost(app: *App, ws: *websocket.Socket, req: *anole.Request, host: HostRow, subject: egress.Subject) !void {
    const relay = &app.relay;
    const io = req.io;
    var room_buf: [96]u8 = undefined;

    const ClientNote = struct { channel: u32, device_id: []const u8, device_name: []const u8, public_key: []const u8 };
    var clients: std.ArrayList(ClientNote) = .empty;

    // Read before the host is registered: its `hello` has to be queued
    // before any client hears `host_online`, and the mutex isn't held
    // across database calls.
    _ = try app.db.exec(req, "UPDATE remote_hosts SET last_seen_at = ? WHERE id = ?", .{ util.now(io), host.id });
    const Pending = struct { pairing_id: []const u8, decide_by: i64, device_id: []const u8, device_name: []const u8, public_key: []const u8 };
    const pending = try app.db.all(Pending, req,
        \\SELECT p.id AS pairing_id, p.decide_by, d.id AS device_id, d.name AS device_name, d.public_key
        \\FROM remote_pairings p JOIN remote_devices d ON d.id = p.device_id
        \\WHERE p.host_id = ? AND p.status = 'pending' AND p.decide_by > ?
    , .{ host.id, util.now(io) });

    const gen = blk: {
        relay.mutex.lockUncancelable(io);
        defer relay.mutex.unlock(io);
        const gen = relay.next_gen;
        relay.next_gen += 1;
        // Joined before it is registered, so no notice is lost.
        const room = hostRoom(&room_buf, host.id, gen);
        try relay.rooms.join(room, ws);
        const entry = try relay.hosts.getOrPut(Relay.gpa, host.id);
        if (entry.found_existing) {
            // A reconnect while the old socket lingers: the new one wins.
            var old_buf: [96]u8 = undefined;
            _ = relay.rooms.broadcast(hostRoom(&old_buf, host.id, entry.value_ptr.*), .text, "{\"type\":\"replaced\"}", null);
        } else {
            entry.key_ptr.* = Relay.gpa.dupe(u8, host.id) catch |err| {
                relay.hosts.removeByPtr(entry.key_ptr);
                return err;
            };
        }
        entry.value_ptr.* = gen;
        var it = relay.channels.iterator();
        while (it.next()) |e| if (std.mem.eql(u8, e.value_ptr.host_id, host.id)) {
            const c = e.value_ptr;
            try clients.append(req.arena, .{
                .channel = e.key_ptr.*,
                .device_id = try req.arena.dupe(u8, c.device_id),
                .device_name = try req.arena.dupe(u8, c.device_name),
                .public_key = try req.arena.dupe(u8, c.public_key),
            });
        };
        // The hello goes through the room, ahead of anything a client sends
        // once it hears `host_online` (a handshake that arrived before the
        // host opened its channels would be dropped).
        _ = relay.rooms.broadcast(room, .text, try std.json.Stringify.valueAlloc(req.arena, .{
            .type = "hello",
            .host_id = host.id,
            .clients = clients.items,
            .pending_pairings = pending,
        }, .{}), null);
        for (clients.items) |c| relay.toClient(c.channel, .text, "{\"type\":\"host_online\"}");
        break :blk gen;
    };
    defer {
        relay.mutex.lockUncancelable(io);
        if (relay.hosts.get(host.id) == gen) {
            const kv = relay.hosts.fetchRemove(host.id).?;
            Relay.gpa.free(kv.key);
            var it = relay.channels.iterator();
            while (it.next()) |e| if (std.mem.eql(u8, e.value_ptr.host_id, host.id))
                relay.toClient(e.key_ptr.*, .text, "{\"type\":\"host_offline\"}");
        }
        relay.mutex.unlock(io);
        _ = app.db.exec(req, "UPDATE remote_hosts SET last_seen_at = ? WHERE id = ?", .{ util.now(io), host.id }) catch {};
    }
    // Webhooks that came while it was away, behind the hello.
    try hooks.resendPending(app, req, host.id);

    // Control frames are parsed into a scratch arena reset for each one: the
    // request's arena lives as long as the socket.
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    var window_start = util.now(io);
    var controls: u32 = 0;
    while (try ws.next()) |msg| {
        _ = scratch.reset(.{ .retain_with_limit = 64 << 10 });
        switch (msg.type) {
            .binary => {
                const frame = splitFrame(msg.data) orelse continue;
                relay.mutex.lockUncancelable(io);
                const live = relay.hosts.get(host.id) == gen;
                const routed = if (relay.channels.get(frame.channel)) |c| std.mem.eql(u8, c.host_id, host.id) else false;
                relay.mutex.unlock(io);
                if (!live) return ws.close(@fromBackingInt(@intCast(close_replaced)), "replaced or revoked");
                if (routed) {
                    if (!try spendRelay(app, ws, req, subject, frame.payload.len)) return;
                    relay.toClient(frame.channel, .binary, frame.payload);
                }
            },
            .text => {
                const now = util.now(io);
                if (now - window_start >= 60) {
                    window_start = now;
                    controls = 0;
                }
                controls += 1;
                if (controls > max_controls_per_minute) return ws.close(.policy_violation, "too many control frames");
                if (msg.data.len > max_control) continue;
                const Control = struct { type: []const u8, channel: u32 = 0, delivery_id: []const u8 = "" };
                const c = std.json.parseFromSliceLeaky(Control, scratch.allocator(), msg.data, .{ .ignore_unknown_fields = true }) catch continue;
                // A database call: before the mutex.
                if (std.mem.eql(u8, c.type, "webhook_ack")) {
                    var ctx: anole.db.Ctx = .{ .io = io, .arena = scratch.allocator() };
                    try hooks.ack(app, &ctx, host.id, c.delivery_id);
                    continue;
                }
                if (!std.mem.eql(u8, c.type, "close_channel")) continue;
                relay.mutex.lockUncancelable(io);
                defer relay.mutex.unlock(io);
                if (relay.hosts.get(host.id) != gen) return ws.close(@fromBackingInt(@intCast(close_replaced)), "replaced or revoked");
                const owned = if (relay.channels.get(c.channel)) |ch| std.mem.eql(u8, ch.host_id, host.id) else false;
                if (!owned) continue;
                const kv = relay.channels.fetchRemove(c.channel).?;
                kv.value.free();
                relay.toClient(c.channel, .text, "{\"type\":\"closed\"}");
            },
            else => {},
        }
    }
}

const DeviceRow = struct { id: []const u8, user_id: []const u8, host_id: []const u8, name: []const u8, public_key: []const u8, approved: i64 };

fn clientSocket(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const host_id = req.param("host_id") orelse return res.fail(.not_found, "no such host");
    const token = socketToken(req) orelse return res.fail(.unauthorized, "device token required");
    if (!std.mem.startsWith(u8, token, device_token_prefix)) return res.fail(.unauthorized, "device token required");
    const device = try app.db.optional(DeviceRow, req, "SELECT d.id, h.user_id, d.host_id, d.name, d.public_key, d.approved FROM remote_devices d JOIN remote_hosts h ON h.id = d.host_id WHERE d.token_hash = ? AND d.host_id = ?", .{
        try util.sha256Hex(req.arena, token), host_id,
    }) orelse return res.fail(.unauthorized, "this device is not paired with that host");
    if (device.approved == 0) return res.fail(.forbidden, "waiting for the host to approve this device");
    var ws = (try websocket.upgrade(req, res, upgrade_options)) orelse return res.fail(.upgrade_required, "this endpoint speaks WebSocket");
    defer ws.deinit();
    // The device's frames count against its host's owner, like the host's.
    const subject = subjectOf(device.user_id, device.host_id);
    var ticket: egress.Gate.Ticket = .{ .id = 0 };
    defer {
        app.egress.leave(req.io, &ticket);
        var ctx: anole.db.Ctx = .{ .io = req.io, .arena = req.arena };
        flushEgress(app, &ctx) catch {};
    }
    if (!try admitSocket(app, &ws, req, subject, &ticket)) return;
    serveClient(app, &ws, req, device, subject) catch |err| {
        if (err == error.Canceled) return err;
        req.log().warn("remote client socket failed", .{ .device = device.id, .err = @errorName(err) });
        if (!ws.isClosed()) ws.close(.internal_error, "") catch {};
        return;
    };
    if (!ws.isClosed()) ws.close(.normal, "") catch {};
}

fn serveClient(app: *App, ws: *websocket.Socket, req: *anole.Request, device: DeviceRow, subject: egress.Subject) !void {
    const relay = &app.relay;
    const io = req.io;
    var room_buf: [16]u8 = undefined;

    var host_online = false;
    const channel = blk: {
        relay.mutex.lockUncancelable(io);
        defer relay.mutex.unlock(io);
        var ch = relay.next_channel;
        while (ch == 0 or relay.channels.contains(ch)) ch +%= 1;
        relay.next_channel = ch +% 1;
        try relay.rooms.join(clientRoom(&room_buf, ch), ws);
        var entry: Relay.Channel = .{
            .host_id = try Relay.gpa.dupe(u8, device.host_id),
            .device_id = try Relay.gpa.dupe(u8, device.id),
            .device_name = try Relay.gpa.dupe(u8, device.name),
            .public_key = try Relay.gpa.dupe(u8, device.public_key),
        };
        relay.channels.put(Relay.gpa, ch, entry) catch |err| {
            entry.free();
            return err;
        };
        host_online = relay.hosts.contains(device.host_id);
        relay.toHostLocked(device.host_id, try std.json.Stringify.valueAlloc(req.arena, .{
            .type = "client_open",
            .channel = ch,
            .device_id = device.id,
            .device_name = device.name,
            .public_key = device.public_key,
        }, .{}));
        break :blk ch;
    };
    defer {
        relay.mutex.lockUncancelable(io);
        if (relay.channels.get(channel)) |c| if (std.mem.eql(u8, c.device_id, device.id)) {
            relay.channels.fetchRemove(channel).?.value.free();
            var buf: [64]u8 = undefined;
            relay.toHostLocked(device.host_id, std.fmt.bufPrint(&buf, "{{\"type\":\"client_close\",\"channel\":{d}}}", .{channel}) catch unreachable);
        };
        relay.mutex.unlock(io);
        _ = app.db.exec(req, "UPDATE remote_devices SET last_seen_at = ? WHERE id = ?", .{ util.now(io), device.id }) catch {};
    }
    _ = try app.db.exec(req, "UPDATE remote_devices SET last_seen_at = ? WHERE id = ?", .{ util.now(io), device.id });
    try ws.send(.text, try std.json.Stringify.valueAlloc(req.arena, .{ .type = "hello", .channel = channel, .host_online = host_online }, .{}));

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(Relay.gpa);
    while (try ws.next()) |msg| {
        if (msg.type != .binary) continue;
        relay.mutex.lockUncancelable(io);
        const still = if (relay.channels.get(channel)) |c| std.mem.eql(u8, c.device_id, device.id) else false;
        const gen = relay.hosts.get(device.host_id);
        relay.mutex.unlock(io);
        if (!still) return ws.close(@fromBackingInt(@intCast(close_revoked)), "unpaired");
        // The host is away: the client was told (`host_offline`).
        const g = gen orelse continue;
        if (!try spendRelay(app, ws, req, subject, msg.data.len)) return;
        frame.clearRetainingCapacity();
        try frame.ensureTotalCapacity(Relay.gpa, channel_len + msg.data.len);
        var prefix: [channel_len]u8 = undefined;
        std.mem.writeInt(u32, &prefix, channel, .big);
        frame.appendSliceAssumeCapacity(&prefix);
        frame.appendSliceAssumeCapacity(msg.data);
        var buf: [96]u8 = undefined;
        _ = relay.rooms.broadcast(hostRoom(&buf, device.host_id, g), .binary, frame.items, null);
    }
}

// ------------------------------------------------------------------ routes

/// The rate-limit bucket of a signed-in user, or of the address without one.
fn byUser(req: *anole.Request, buf: []u8) []const u8 {
    if (req.local(auth.Identity, "identity")) |who| return std.fmt.bufPrint(buf, "user:{s}", .{who.user_id}) catch who.user_id;
    return anole.ratelimit.clientAddress(req, buf);
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    // Signed in or not: the host and device tokens are the identity.
    const v1 = app.group("/v1/remote", .{auth.Authenticate{ .app = state, .optional = true }});
    v1.post("/hosts", createHost);
    v1.delete("/hosts/:id", deleteHost);
    v1.delete("/devices/:id", deleteDevice);
    const account = app.group("/v1/remote", .{auth.Authenticate{ .app = state }});
    account.get("/hosts", listHosts);
    account.post("/hosts/:id/claim", claimHost);
    // Codes are guessable only by brute force; cap the attempts per account
    // or, signed out, per address.
    const guarded = v1.group("", .{anole.ratelimit.Middleware.init(state.limiter.limiter(), .{ .limit = 10, .window = .fromSeconds(60), .key = byUser, .on_error = .deny })});
    guarded.post("/pair", pair);
    guarded.post("/pair/redeem", redeem);
    v1.get("/pair/:id", pairStatus);
    v1.post("/pair/:id/approve", approvePairing);
    v1.post("/pair/:id/deny", denyPairing);
    // Sockets authenticate with their own tokens, not the user's.
    // WebSocket upgrades: OpenAPI has no way to describe them, and a GET
    // listed in /docs would only fail with 426 when tried.
    app.get("/v1/remote/host", anole.doc(.{ .hidden = true }, hostSocket));
    app.get("/v1/remote/client/:host_id", anole.doc(.{ .hidden = true }, clientSocket));
}

test normalizeCode {
    var buf: [code_len]u8 = undefined;
    try std.testing.expectEqualStrings("ABCDEFGH", normalizeCode(&buf, "abcd-efgh").?);
    try std.testing.expectEqualStrings("ABCD2345", normalizeCode(&buf, " ABCD 2345 ").?);
    try std.testing.expect(normalizeCode(&buf, "ABCD-EFG") == null);
    try std.testing.expect(normalizeCode(&buf, "ABCD-EFGHJ") == null);
    // Ambiguous symbols are not in the alphabet.
    try std.testing.expect(normalizeCode(&buf, "ABCD-EFG0") == null);
    try std.testing.expect(normalizeCode(&buf, "IBCD-EFGH") == null);
}

test splitFrame {
    try std.testing.expect(splitFrame("abc") == null);
    try std.testing.expect(splitFrame("\x00\x00\x00\x00data") == null);
    const f = splitFrame("\x00\x00\x01\x02data").?;
    try std.testing.expectEqual(@as(u32, 258), f.channel);
    try std.testing.expectEqualStrings("data", f.payload);
}

test effectiveStatus {
    try std.testing.expectEqualStrings("open", effectiveStatus("open", 100, null, 50));
    try std.testing.expectEqualStrings("expired", effectiveStatus("open", 100, null, 100));
    try std.testing.expectEqualStrings("pending", effectiveStatus("pending", 0, 200, 150));
    try std.testing.expectEqualStrings("expired", effectiveStatus("pending", 0, 200, 250));
    try std.testing.expectEqualStrings("approved", effectiveStatus("approved", 0, 0, 999));
}

test "codes use the whole alphabet without bias" {
    try std.testing.expectEqual(@as(usize, 32), code_alphabet.len);
    for (code_alphabet, 0..) |c, i| try std.testing.expect(std.mem.indexOfScalar(u8, code_alphabet[i + 1 ..], c) == null);
}
