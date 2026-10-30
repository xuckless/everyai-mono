//! Remote hosts for Code sessions: a desktop that runs the agent sidecar (the
//! host) and the user's other devices (clients) meet here, and the backend
//! relays their WebSocket frames. The frames are end-to-end encrypted by the
//! endpoints; the backend routes them by channel and never parses a payload.
//!
//! REST (user token, `Authorization: Bearer <access JWT>`):
//!
//!   POST   /v1/remote/hosts               {name, platform?, public_key} -> 201 {id, name, platform, public_key, host_token}
//!   GET    /v1/remote/hosts               [{id, name, platform, public_key, online, created_at, last_seen_at, devices: [...]}]
//!   DELETE /v1/remote/hosts/:id           revokes the host, its devices and live sockets
//!   DELETE /v1/remote/devices/:id         unpairs one device
//!   POST   /v1/remote/pair                {host_id} -> 201 {id, code, host_id, expires_at}
//!   POST   /v1/remote/pair/redeem         {code, device_name, public_key} -> {id, status, device_id, device_token, decide_by, host}
//!   GET    /v1/remote/pair/:id            {id, status, host_id, device_id}
//!   POST   /v1/remote/pair/:id/approve    (+ X-Remote-Host-Token) -> {id, status}
//!   POST   /v1/remote/pair/:id/deny       (+ X-Remote-Host-Token) -> {id, status}
//!
//! WebSockets (token in `Authorization: Bearer` or `?token=`):
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
//! `replaced`, `revoked`. Notices to a client: `hello {channel,
//! host_online}`, `host_online`, `host_offline`, `closed`, `revoked`. The
//! host may send `{"type":"close_channel","channel":N}` to drop a client.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const util = @import("util.zig");
const websocket = anole.websocket;

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
    const who = try auth.identity(req);
    const id = try util.uuid(req.arena, req.io);
    const token = try util.randomToken(req.arena, req.io, host_token_prefix);
    _ = try app.db.exec(req, "INSERT INTO remote_hosts (id, user_id, name, platform, public_key, token_hash, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", .{
        id, who.user_id, in.body.name, in.body.platform, in.body.public_key, try util.sha256Hex(req.arena, token), util.now(req.io),
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

fn deleteHost(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: []const u8 } })) !void {
    const who = try auth.identity(req);
    if (try app.db.exec(req, "DELETE FROM remote_hosts WHERE id = ? AND user_id = ?", .{ in.path.id, who.user_id }) == 0) return error.NotFound;
    // Without relying on foreign keys being enforced.
    _ = try app.db.exec(req, "DELETE FROM remote_devices WHERE host_id = ?", .{in.path.id});
    _ = try app.db.exec(req, "DELETE FROM remote_pairings WHERE host_id = ?", .{in.path.id});
    app.relay.revokeHost(req.io, in.path.id);
}

fn deleteDevice(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: []const u8 } })) !void {
    const who = try auth.identity(req);
    if (try app.db.exec(req, "DELETE FROM remote_devices WHERE id = ? AND user_id = ?", .{ in.path.id, who.user_id }) == 0) return error.NotFound;
    app.relay.revokeDevice(req.io, in.path.id);
}

fn pair(app: *App, req: *anole.Request, in: anole.In(.{ .body = struct { host_id: []const u8 } })) !anole.Created(struct {
    id: []const u8,
    code: []const u8,
    host_id: []const u8,
    expires_at: i64,
}) {
    const who = try auth.identity(req);
    _ = try app.db.optional([]const u8, req, "SELECT id FROM remote_hosts WHERE id = ? AND user_id = ?", .{ in.body.host_id, who.user_id }) orelse return error.NotFound;
    const code = try newCode(req.io);
    const id = try util.uuid(req.arena, req.io);
    const now = util.now(req.io);
    const expires_at = now + code_ttl_seconds;
    _ = try app.db.exec(req, "INSERT INTO remote_pairings (id, user_id, host_id, code_hash, expires_at, created_at) VALUES (?, ?, ?, ?, ?, ?)", .{
        id, who.user_id, in.body.host_id, try util.sha256Hex(req.arena, &code), expires_at, now,
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

/// A device with the same account claims a code. The code is spent at once;
/// the device waits for the host to approve it.
fn redeem(app: *App, req: *anole.Request, in: anole.In(.{ .body = Redeem })) !struct {
    id: []const u8,
    status: []const u8 = "pending",
    device_id: []const u8,
    device_token: []const u8,
    decide_by: i64,
    host: struct { id: []const u8, name: []const u8, platform: []const u8, public_key: []const u8 },
} {
    const who = try auth.identity(req);
    var buf: [code_len]u8 = undefined;
    // Wrong, spent, expired and other accounts' codes all look the same.
    const code = normalizeCode(&buf, in.body.code) orelse return error.NotFound;
    const now = util.now(req.io);
    const claimed = try app.db.optional(struct { id: []const u8, host_id: []const u8 }, req,
        \\UPDATE remote_pairings SET status = 'pending'
        \\WHERE code_hash = ? AND user_id = ? AND status = 'open' AND expires_at > ?
        \\RETURNING id, host_id
    , .{ try util.sha256Hex(req.arena, code), who.user_id, now }) orelse return error.NotFound;
    const host = try app.db.one(struct { id: []const u8, name: []const u8, platform: []const u8, public_key: []const u8 }, req, "SELECT id, name, platform, public_key FROM remote_hosts WHERE id = ?", .{claimed.host_id});

    const device_id = try util.uuid(req.arena, req.io);
    const token = try util.randomToken(req.arena, req.io, device_token_prefix);
    _ = try app.db.exec(req, "INSERT INTO remote_devices (id, user_id, host_id, name, public_key, token_hash, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", .{
        device_id, who.user_id, host.id, in.body.device_name, in.body.public_key, try util.sha256Hex(req.arena, token), now,
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
    const who = try auth.identity(req);
    const p = try app.db.optional(struct { status: []const u8, host_id: []const u8, device_id: ?[]const u8, expires_at: i64, decide_by: ?i64 }, req, "SELECT status, host_id, device_id, expires_at, decide_by FROM remote_pairings WHERE id = ? AND user_id = ?", .{ in.path.id, who.user_id }) orelse return error.NotFound;
    return .{ .id = in.path.id, .status = effectiveStatus(p.status, p.expires_at, p.decide_by, util.now(req.io)), .host_id = p.host_id, .device_id = p.device_id };
}

/// The host behind `X-Remote-Host-Token`, which must belong to the caller.
fn callingHost(app: *App, req: *anole.Request) !HostRow {
    const who = try auth.identity(req);
    const token = req.headers.get("X-Remote-Host-Token") orelse return error.Unauthorized;
    const host = try app.db.optional(HostRow, req, "SELECT id, user_id, name FROM remote_hosts WHERE token_hash = ?", .{try util.sha256Hex(req.arena, token)}) orelse return error.Unauthorized;
    if (!std.mem.eql(u8, host.user_id, who.user_id)) return error.Unauthorized;
    return host;
}

const Decision = struct { id: []const u8, status: []const u8 };

fn decide(app: *App, req: *anole.Request, id: []const u8, approve: bool) !Decision {
    const host = try callingHost(app, req);
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
    serveHost(app, &ws, req, host) catch |err| {
        if (err == error.Canceled) return err;
        std.log.warn("remote host {s}: {t}", .{ host.id, err });
        if (!ws.isClosed()) ws.close(.internal_error, "") catch {};
        return;
    };
    if (!ws.isClosed()) ws.close(.normal, "") catch {};
}

fn serveHost(app: *App, ws: *websocket.Socket, req: *anole.Request, host: HostRow) !void {
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

    while (try ws.next()) |msg| {
        switch (msg.type) {
            .binary => {
                const frame = splitFrame(msg.data) orelse continue;
                relay.mutex.lockUncancelable(io);
                const live = relay.hosts.get(host.id) == gen;
                const routed = if (relay.channels.get(frame.channel)) |c| std.mem.eql(u8, c.host_id, host.id) else false;
                relay.mutex.unlock(io);
                if (!live) return ws.close(@fromBackingInt(@intCast(close_replaced)), "replaced or revoked");
                if (routed) relay.toClient(frame.channel, .binary, frame.payload);
            },
            .text => {
                const Control = struct { type: []const u8, channel: u32 = 0 };
                const c = std.json.parseFromSliceLeaky(Control, req.arena, msg.data, .{ .ignore_unknown_fields = true }) catch continue;
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

const DeviceRow = struct { id: []const u8, host_id: []const u8, name: []const u8, public_key: []const u8, approved: i64 };

fn clientSocket(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const host_id = req.param("host_id") orelse return res.fail(.not_found, "no such host");
    const token = socketToken(req) orelse return res.fail(.unauthorized, "device token required");
    if (!std.mem.startsWith(u8, token, device_token_prefix)) return res.fail(.unauthorized, "device token required");
    const device = try app.db.optional(DeviceRow, req, "SELECT id, host_id, name, public_key, approved FROM remote_devices WHERE token_hash = ? AND host_id = ?", .{
        try util.sha256Hex(req.arena, token), host_id,
    }) orelse return res.fail(.unauthorized, "this device is not paired with that host");
    if (device.approved == 0) return res.fail(.forbidden, "waiting for the host to approve this device");
    var ws = (try websocket.upgrade(req, res, upgrade_options)) orelse return res.fail(.upgrade_required, "this endpoint speaks WebSocket");
    defer ws.deinit();
    serveClient(app, &ws, req, device) catch |err| {
        if (err == error.Canceled) return err;
        std.log.warn("remote client {s}: {t}", .{ device.id, err });
        if (!ws.isClosed()) ws.close(.internal_error, "") catch {};
        return;
    };
    if (!ws.isClosed()) ws.close(.normal, "") catch {};
}

fn serveClient(app: *App, ws: *websocket.Socket, req: *anole.Request, device: DeviceRow) !void {
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

pub fn routes(app: *anole.Server(App), state: *App) void {
    const v1 = app.group("/v1/remote", .{auth.Authenticate{ .app = state }});
    v1.post("/hosts", createHost);
    v1.get("/hosts", listHosts);
    v1.delete("/hosts/:id", deleteHost);
    v1.delete("/devices/:id", deleteDevice);
    v1.post("/pair", pair);
    v1.post("/pair/redeem", redeem);
    v1.get("/pair/:id", pairStatus);
    v1.post("/pair/:id/approve", approvePairing);
    v1.post("/pair/:id/deny", denyPairing);
    // Sockets authenticate with their own tokens, not the user's.
    app.get("/v1/remote/host", hostSocket);
    app.get("/v1/remote/client/:host_id", clientSocket);
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
