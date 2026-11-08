//! Magic-link sign-in (owner, 2026-11-08): no passwords, no OAuth.
//!
//! The app asks with an email; the server mails a link and a 6-digit code.
//! The device that asked holds a `request_secret` and polls; the link opens
//! a page with a Sign in button (a GET never changes anything, so mail
//! scanners that fetch links can't use them). Approving on any device signs
//! in the device that asked, not the one that clicked. Typing the code on
//! the asking device works too.
//!
//! A request's states (`magic_requests.status`):
//!
//! ```text
//!   pending ──link: Sign in──► approved ──poll──► redeemed
//!      │  ╲                       │
//!      │   ╲──code ok─────────────┼──────────────► redeemed
//!      │    ╲                     │
//!      │     ──link: Not me──► denied
//!      │──5 wrong codes──► dead
//!      └──15 min──► expired ◄── (approved, never polled)
//! ```
//!
//! Only hashes are stored: the link token and the request secret as SHA-256,
//! the code as HMAC-SHA256 under the server secret (a 6-digit space hashed
//! plainly would be read straight back from a stolen database). Every
//! comparison is constant-time. Unknown addresses get the same answer and
//! the same mail (that is how an account is made), so nothing tells which
//! addresses have accounts.
const std = @import("std");
const anole = @import("anole");

const App = @import("main.zig").App;
const auth = @import("auth.zig");
const mail = @import("mail.zig");
const util = @import("util.zig");

pub const ttl_seconds: i64 = 15 * 60;
pub const max_code_attempts: i64 = 5;
/// Per address: at most this many requests in 15 minutes, and in a day.
pub const per_email_window = 3;
pub const per_email_day = 10;

pub const Status = enum { pending, approved, redeemed, expired, dead, denied };
pub const Purpose = enum { sign_in, change_email };

const Row = struct {
    id: []const u8,
    purpose: []const u8,
    user_id: ?[]const u8,
    email: []const u8,
    code_hash: []const u8,
    secret_hash: []const u8,
    device_name: []const u8,
    ip_prefix: []const u8,
    status: []const u8,
    attempts: i64,
    created_at: i64,
    expires_at: i64,
};

const row_columns = "id, purpose, user_id, email, code_hash, secret_hash, device_name, ip_prefix, status, attempts, created_at, expires_at";

/// The state a row is in now: a pending or approved request past its
/// deadline has expired (stored lazily, by the next write or the pruner).
fn statusOf(r: Row, now: i64) Status {
    const stored = std.meta.stringToEnum(Status, r.status) orelse .dead;
    return switch (stored) {
        .pending, .approved => if (now >= r.expires_at) .expired else stored,
        else => stored,
    };
}

// ------------------------------------------------------------------ hashing

fn hmacHex(arena: std.mem.Allocator, key: []const u8, parts: []const []const u8) ![]const u8 {
    var mac = std.crypto.auth.hmac.sha2.HmacSha256.init(key);
    for (parts) |p| {
        mac.update(p);
        mac.update("\x00");
    }
    var out: [32]u8 = undefined;
    mac.final(&out);
    const hex = std.fmt.bytesToHex(out, .lower);
    return arena.dupe(u8, &hex);
}

fn codeHash(app: *App, arena: std.mem.Allocator, id: []const u8, code: []const u8) ![]const u8 {
    return hmacHex(arena, app.jwt_keys[0].material.hmac, &.{ "everyai-magic-code", id, code });
}

/// Constant-time equality of two hex digests (lengths are public).
fn sameDigest(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Six digits, uniform (rejection sampling).
fn newCode(io: std.Io, buf: *[6]u8) !void {
    while (true) {
        var b: [4]u8 = undefined;
        try io.randomSecure(&b);
        const n = std.mem.readInt(u32, &b, .little);
        if (n >= 4_294_000_000) continue; // 4_294_000_000 is a multiple of 1_000_000
        _ = std.fmt.bufPrint(buf, "{d:0>6}", .{n % 1_000_000}) catch unreachable;
        return;
    }
}

/// The client's network, not its address: IPv4 /24, IPv6 /48. Shown in the
/// sign-in history and used for per-network limits; never the full address.
pub fn ipPrefix(req: *anole.Request, buf: []u8) []const u8 {
    return switch (req.remote_address) {
        .ip4 => |a| std.fmt.bufPrint(buf, "{d}.{d}.{d}.0/24", .{ a.bytes[0], a.bytes[1], a.bytes[2] }) catch "?",
        .ip6 => |a| blk: {
            const mapped = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
            if (std.mem.eql(u8, a.bytes[0..12], &mapped))
                break :blk std.fmt.bufPrint(buf, "{d}.{d}.{d}.0/24", .{ a.bytes[12], a.bytes[13], a.bytes[14] }) catch "?";
            break :blk std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}::/48", .{
                a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3], a.bytes[4], a.bytes[5],
            }) catch "?";
        },
    };
}

// ------------------------------------------------------------------ the mail

fn linkUrl(app: *App, arena: std.mem.Allocator, token: []const u8) ![]const u8 {
    const base = std.mem.trimEnd(u8, app.cfg.public_url, "/");
    return std.fmt.allocPrint(arena, "{s}/auth/l/{s}", .{ base, token });
}

fn compose(arena: std.mem.Allocator, purpose: Purpose, link: []const u8, code: []const u8, device: []const u8) !struct { subject: []const u8, text: []const u8, html: []const u8 } {
    const what = switch (purpose) {
        .sign_in => "sign in to EveryAI",
        .change_email => "use this address for your EveryAI account",
    };
    const subject = try std.fmt.allocPrint(arena, "Your EveryAI code: {s}", .{code});
    const text = try std.fmt.allocPrint(arena,
        \\Someone asked to {s} on {s}.
        \\
        \\Your code: {s}
        \\
        \\Or open this link and press Sign in:
        \\{s}
        \\
        \\The code and link work once, for 15 minutes.
        \\If you didn't ask, ignore this email: nothing happens without the code or the button.
        \\
    , .{ what, device, code, link });
    const d = try mail.escapeAlloc(arena, device);
    const l = try mail.escapeAlloc(arena, link);
    const html = try std.fmt.allocPrint(arena,
        \\<!doctype html><html><body style="margin:0;padding:32px 16px;background:#f6f5fb;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#17151f">
        \\<div style="max-width:440px;margin:0 auto;background:#ffffff;border-radius:16px;padding:28px">
        \\<p style="margin:0 0 4px;font-size:13px;color:#6b6780">EveryAI</p>
        \\<p style="margin:0 0 20px;font-size:15px">Someone asked to {s} on <b>{s}</b>.</p>
        \\<p style="margin:0 0 6px;font-size:13px;color:#6b6780">Your code</p>
        \\<p style="margin:0 0 24px;font-size:32px;letter-spacing:6px;font-weight:600;font-family:ui-monospace,Menlo,monospace">{s}</p>
        \\<p style="margin:0 0 24px"><a href="{s}" style="display:inline-block;background:#7c5cff;color:#ffffff;text-decoration:none;padding:10px 18px;border-radius:10px;font-size:14px">Open the sign-in page</a></p>
        \\<p style="margin:0;font-size:12px;color:#6b6780">The code and link work once, for 15 minutes. If you didn't ask, ignore this email: nothing happens without the code or the button.</p>
        \\</div></body></html>
    , .{ what, d, code, l });
    return .{ .subject = subject, .text = text, .html = html };
}

// ------------------------------------------------------------------ limits

/// Global daily mail cap (Resend's free plan stops at 100 a day). Counts
/// and reserves one send; false when today's budget is spent.
fn reserveMail(app: *App, req: *anole.Request) !bool {
    const day = @divFloor(util.now(req.io), 86_400);
    const sent = try app.db.optional(i64, req,
        \\INSERT INTO mail_days (day, sent) VALUES (?, 1)
        \\ON CONFLICT(day) DO UPDATE SET sent = sent + 1 WHERE sent < ?
        \\RETURNING sent
    , .{ day, app.cfg.mail_daily_cap });
    return sent != null;
}

fn tooMany(res: *anole.Response, message: []const u8, code: []const u8) !void {
    res.status = .too_many_requests;
    return res.json(.{ .message = message, .code = code });
}

// ------------------------------------------------------------------ routes

const Ask = struct {
    email: []const u8,
    device_name: []const u8 = "",

    pub const field_rules = .{
        .email = .{ anole.validate.trim, anole.validate.email, anole.validate.maxLength(254) },
        .device_name = .{ anole.validate.trim, anole.validate.maxLength(60) },
    };
};

pub const Asked = struct {
    request_id: []const u8,
    request_secret: []const u8,
    expires_at: i64,
    code_length: u8 = 6,
};

/// `POST /v1/auth/magic {email, device_name?}` → 202 `Asked`.
fn ask(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bindWith(Ask, .{});
    return start(app, req, res, .sign_in, null, in.email, in.device_name);
}

/// `POST /v1/auth/email {email}` (signed in): a link to the new address;
/// redeeming it moves the account there.
fn changeEmail(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const who = try auth.identity(req);
    const in = try req.bindWith(Ask, .{});
    if (try app.db.optional([]const u8, req, "SELECT id FROM users WHERE email = ?", .{in.email}) != null) {
        res.status = .conflict;
        return res.json(.{ .message = "That address already has an account.", .code = "email_taken" });
    }
    return start(app, req, res, .change_email, who.user_id, in.email, in.device_name);
}

fn start(app: *App, req: *anole.Request, res: *anole.Response, purpose: Purpose, user_id: ?[]const u8, email: []const u8, device_in: []const u8) !void {
    // The reserved owner of anonymous remote hosts (remote.zig) can't sign in.
    if (std.ascii.endsWithIgnoreCase(email, ".invalid")) return error.UnprocessableEntity;
    const mailer = app.mailer orelse {
        res.status = .service_unavailable;
        return res.json(.{ .message = "Sign-in email isn't set up on this server.", .code = "mail_unavailable" });
    };
    const now = util.now(req.io);
    const recent = try app.db.one(struct { window: i64, day: i64 }, req,
        \\SELECT COALESCE(SUM(created_at > ?), 0) AS window, COUNT(*) AS day
        \\FROM magic_requests WHERE email = ? AND created_at > ?
    , .{ now - ttl_seconds, email, now - 86_400 });
    if (recent.window >= per_email_window) return tooMany(res, "Too many sign-in emails to this address. Wait a few minutes.", "magic_wait");
    if (recent.day >= per_email_day) return tooMany(res, "Too many sign-in emails to this address today.", "magic_day");
    if (!try reserveMail(app, req)) {
        res.status = .service_unavailable;
        return res.json(.{ .message = "Sign-in email is busy today. Try again tomorrow.", .code = "mail_busy" });
    }

    const id = try util.uuid(req.arena, req.io);
    const token = try util.randomToken(req.arena, req.io, "ml_");
    const secret = try util.randomToken(req.arena, req.io, "ms_");
    var code_buf: [6]u8 = undefined;
    try newCode(req.io, &code_buf);
    const code = code_buf[0..];
    var ip_buf: [64]u8 = undefined;
    const device = if (device_in.len == 0) "a device" else device_in;
    _ = try app.db.exec(req,
        \\INSERT INTO magic_requests (id, purpose, user_id, email, token_hash, code_hash, secret_hash, device_name, ip_prefix, status, attempts, created_at, expires_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)
    , .{
        id,                                   @tagName(purpose),                      user_id,                               email,
        try util.sha256Hex(req.arena, token), try codeHash(app, req.arena, id, code), try util.sha256Hex(req.arena, secret), device,
        ipPrefix(req, &ip_buf),               now,                                    now + ttl_seconds,
    });

    const m = try compose(req.arena, purpose, try linkUrl(app, req.arena, token), code, device);
    mailer.send(req, .{ .to = email, .subject = m.subject, .text = m.text, .html = m.html, .idempotency_key = id }) catch |err| {
        req.log().err("sign-in mail failed", .{ .err = @errorName(err) });
        _ = try app.db.exec(req, "UPDATE magic_requests SET status = 'dead' WHERE id = ?", .{id});
        res.status = .bad_gateway;
        return res.json(.{ .message = "Couldn't send the email. Try again.", .code = "mail_failed" });
    };
    res.status = .accepted;
    return res.json(Asked{ .request_id = id, .request_secret = secret, .expires_at = now + ttl_seconds });
}

const Held = struct { request_id: []const u8, request_secret: []const u8 };

/// The row the asking device holds, checked by its secret; null when the
/// id is unknown or the secret is wrong (both answer 404).
fn held(app: *App, req: *anole.Request, h: Held) !?Row {
    const row = try app.db.optional(Row, req, "SELECT " ++ row_columns ++ " FROM magic_requests WHERE id = ?", .{h.request_id}) orelse return null;
    if (!sameDigest(row.secret_hash, try util.sha256Hex(req.arena, h.request_secret))) return null;
    return row;
}

pub const PollAnswer = struct {
    status: []const u8,
    /// Set once, when an approved request is redeemed.
    tokens: ?auth.Tokens = null,
};

/// `POST /v1/auth/magic/poll {request_id, request_secret}`.
fn poll(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const h = try req.bind(Held);
    const row = try held(app, req, h) orelse return error.NotFound;
    const status = statusOf(row, util.now(req.io));
    if (status != .approved) return res.json(PollAnswer{ .status = @tagName(status) });
    // Exactly one poll wins the approved request.
    const won = try app.db.exec(req, "UPDATE magic_requests SET status = 'redeemed' WHERE id = ? AND status = 'approved'", .{row.id});
    if (won == 0) return res.json(PollAnswer{ .status = "redeemed" });
    return res.json(PollAnswer{ .status = "redeemed", .tokens = try finish(app, req, row, "link") });
}

/// `POST /v1/auth/magic/code {request_id, request_secret, code}`.
fn enterCode(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(struct { request_id: []const u8, request_secret: []const u8, code: []const u8 });
    const row = try held(app, req, .{ .request_id = in.request_id, .request_secret = in.request_secret }) orelse return error.NotFound;
    const status = statusOf(row, util.now(req.io));
    if (status != .pending and status != .approved) {
        res.status = .gone;
        return res.json(.{ .message = "This code has expired. Ask for a new one.", .code = "magic_gone", .status = @tagName(status) });
    }
    const attempts = row.attempts + 1;
    const code = std.mem.trim(u8, in.code, " -");
    if (sameDigest(row.code_hash, try codeHash(app, req.arena, row.id, code))) {
        const won = try app.db.exec(req, "UPDATE magic_requests SET status = 'redeemed', attempts = ? WHERE id = ? AND status IN ('pending', 'approved')", .{ attempts, row.id });
        if (won == 0) return error.NotFound;
        return res.json(PollAnswer{ .status = "redeemed", .tokens = try finish(app, req, row, "code") });
    }
    const dead = attempts >= max_code_attempts;
    _ = try app.db.exec(req, "UPDATE magic_requests SET attempts = ?, status = CASE WHEN ? THEN 'dead' ELSE status END WHERE id = ?", .{ attempts, dead, row.id });
    res.status = .unauthorized;
    return res.json(.{
        .message = if (dead) "Too many wrong codes. Ask for a new one." else "That code isn't right.",
        .code = if (dead) "magic_dead" else "magic_wrong_code",
        .attempts_left = @max(0, max_code_attempts - attempts),
    });
}

/// Signs in (making the account on first use) or moves the account to the
/// new address, records the sign-in, and issues the usual token pair.
fn finish(app: *App, req: *anole.Request, row: Row, method: []const u8) !auth.Tokens {
    const now = util.now(req.io);
    const purpose = std.meta.stringToEnum(Purpose, row.purpose) orelse .sign_in;
    const user_id: []const u8 = switch (purpose) {
        .change_email => blk: {
            const uid = row.user_id orelse return error.NotFound;
            _ = app.db.exec(req, "UPDATE users SET email = ? WHERE id = ?", .{ row.email, uid }) catch return error.Conflict;
            break :blk uid;
        },
        .sign_in => if (try app.db.optional([]const u8, req, "SELECT id FROM users WHERE email = ?", .{row.email})) |id| id else blk: {
            const local = row.email[0 .. std.mem.indexOfScalar(u8, row.email, '@') orelse row.email.len];
            break :blk (try auth.createUser(app, req, local, row.email, null, null)).id;
        },
    };
    _ = try app.db.exec(req, "INSERT INTO sign_ins (user_id, at, device_name, ip_prefix, method) VALUES (?, ?, ?, ?, ?)", .{ user_id, now, row.device_name, row.ip_prefix, method });
    return auth.issue(app, req, try auth.loadUser(app, req, user_id));
}

// ------------------------------------------------------------------ the link page

/// `GET /auth/l/:token`: shows what the link would do. Changes nothing.
fn page(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const token = req.param("token") orelse "";
    const row = try app.db.optional(Row, req, "SELECT " ++ row_columns ++ " FROM magic_requests WHERE token_hash = ?", .{try util.sha256Hex(req.arena, token)});
    const now = util.now(req.io);
    const status: Status = if (row) |r| statusOf(r, now) else .expired;
    switch (status) {
        .pending => return renderAsk(res, row.?, token),
        .approved, .redeemed => return renderDone(res, "You're signed in", "Go back to EveryAI on the device that asked. You can close this page."),
        .denied => return renderDone(res, "Sign-in refused", "Nothing was signed in. You can close this page."),
        .expired, .dead => return renderDone(res, "This link has expired", "Ask for a new email in EveryAI."),
    }
}

/// `POST /auth/l/:token/approve|deny`: the button. Only from our own page.
fn decide(app: *App, req: *anole.Request, res: *anole.Response, approve: bool) !void {
    if (!sameOrigin(app, req)) {
        res.status = .forbidden;
        return renderDone(res, "Open the link from your email", "This sign-in page has to be used directly.");
    }
    const token = req.param("token") orelse "";
    const digest = try util.sha256Hex(req.arena, token);
    const changed = try app.db.exec(req,
        \\UPDATE magic_requests SET status = ?, decided_at = ?
        \\WHERE token_hash = ? AND status = 'pending' AND expires_at > ?
    , .{ if (approve) "approved" else "denied", util.now(req.io), digest, util.now(req.io) });
    if (changed == 0) return page(app, req, res);
    if (approve) return renderDone(res, "You're signed in", "Go back to EveryAI on the device that asked. On this device, the button below brings EveryAI forward.");
    return renderDone(res, "Sign-in refused", "Nothing was signed in. You can close this page.");
}

fn approveLink(app: *App, req: *anole.Request, res: *anole.Response) !void {
    return decide(app, req, res, true);
}

fn denyLink(app: *App, req: *anole.Request, res: *anole.Response) !void {
    return decide(app, req, res, false);
}

/// A browser form POST carries `Origin` (or at least `Referer`); either
/// must be this server. Stops another site from posting the button.
fn sameOrigin(app: *App, req: *anole.Request) bool {
    const base = std.mem.trimEnd(u8, app.cfg.public_url, "/");
    if (req.headers.get("Origin")) |o| return std.mem.eql(u8, std.mem.trimEnd(u8, o, "/"), base);
    if (req.headers.get("Referer")) |r| return std.mem.startsWith(u8, r, base) and (r.len == base.len or r[base.len] == '/');
    return false;
}

const page_head =
    \\<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    \\<meta name="robots" content="noindex"><title>EveryAI sign-in</title>
    \\<style>
    \\:root{--bg:#f6f5fb;--card:#fff;--text:#17151f;--muted:#6b6780;--line:#e6e3ef;--accent:#7c5cff}
    \\@media (prefers-color-scheme:dark){:root{--bg:#07070a;--card:#121118;--text:#f2f0f8;--muted:#9a96ab;--line:#24222d}}
    \\body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:var(--bg);color:var(--text);font:15px/1.5 -apple-system,"Segoe UI",Helvetica,Arial,sans-serif;padding:16px;box-sizing:border-box}
    \\main{width:100%;max-width:420px;background:var(--card);border:1px solid var(--line);border-radius:18px;padding:28px}
    \\.brand{font-size:13px;color:var(--muted);margin:0 0 6px}h1{font-size:20px;margin:0 0 8px}p{margin:0 0 18px;color:var(--muted)}
    \\form{display:inline}button{font:inherit;border-radius:10px;padding:10px 18px;border:1px solid var(--line);background:transparent;color:var(--text);cursor:pointer;margin-right:8px}
    \\button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
    \\</style></head><body><main><p class="brand">EveryAI</p>
;
const page_tail = "</main></body></html>";

fn securityHeaders(res: *anole.Response) !void {
    try res.header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
    try res.header("X-Frame-Options", "DENY");
    try res.header("Referrer-Policy", "no-referrer");
    try res.header("Cache-Control", "no-store");
    try res.header("X-Content-Type-Options", "nosniff");
}

fn renderAsk(res: *anole.Response, row: Row, token: []const u8) !void {
    try securityHeaders(res);
    const Tpl = struct {
        fn render(r: Row, t: []const u8, w: *std.Io.Writer) !void {
            try w.writeAll(page_head);
            const purpose = std.meta.stringToEnum(Purpose, r.purpose) orelse .sign_in;
            try w.writeAll("<h1>");
            try w.writeAll(switch (purpose) {
                .sign_in => "Sign in EveryAI on ",
                .change_email => "Use this address on ",
            });
            try mail.writeEscaped(w, r.device_name);
            try w.writeAll("?</h1><p>For ");
            try mail.writeEscaped(w, r.email);
            try w.writeAll(". Only press Sign in if you just asked for this. This page doesn't sign in the device you're reading it on.</p>");
            // The token is base64url: safe in a path as is.
            try w.print("<form method=\"post\" action=\"/auth/l/{s}/approve\"><button class=\"primary\" type=\"submit\">Sign in</button></form>", .{t});
            try w.print("<form method=\"post\" action=\"/auth/l/{s}/deny\"><button type=\"submit\">Not me</button></form>", .{t});
            try w.writeAll(page_tail);
        }
    };
    return res.render(.html, Tpl.render, .{ row, token });
}

fn renderDone(res: *anole.Response, title: []const u8, body: []const u8) !void {
    try securityHeaders(res);
    const Tpl = struct {
        fn render(t: []const u8, b: []const u8, w: *std.Io.Writer) !void {
            try w.writeAll(page_head);
            try w.writeAll("<h1>");
            try mail.writeEscaped(w, t);
            try w.writeAll("</h1><p>");
            try mail.writeEscaped(w, b);
            try w.writeAll("</p>");
            // Only brings the app forward; carries nothing (the app's poll
            // picks up the sign-in).
            if (std.mem.startsWith(u8, t, "You're signed in")) try w.writeAll("<p><a href=\"everyai://auth\">Open EveryAI</a></p>");
            try w.writeAll(page_tail);
        }
    };
    return res.render(.html, Tpl.render, .{ title, body });
}

// ------------------------------------------------------------------ account extras

const SignIn = struct { at: i64, device_name: []const u8, ip_prefix: []const u8, method: []const u8 };

/// `GET /v1/auth/sign_ins`: the last 20 sign-ins of this account.
fn signIns(app: *App, req: *anole.Request) ![]const SignIn {
    return app.db.all(SignIn, req, "SELECT at, device_name, ip_prefix, method FROM sign_ins WHERE user_id = ? ORDER BY at DESC, id DESC LIMIT 20", .{(try auth.identity(req)).user_id});
}

/// `POST /v1/auth/logout_all`: every refresh token of this account stops
/// working (access tokens end within 15 minutes).
fn logOutAll(app: *App, req: *anole.Request) !void {
    _ = try app.db.exec(req, "UPDATE refresh_tokens SET revoked = 1 WHERE user_id = ?", .{(try auth.identity(req)).user_id});
}

/// The poll/code bucket: its own key space, apart from the ask bucket.
fn waitKey(req: *anole.Request, buf: []u8) []const u8 {
    var addr_buf: [64]u8 = undefined;
    return std.fmt.bufPrint(buf, "magic-wait:{s}", .{anole.ratelimit.clientAddress(req, &addr_buf)}) catch "magic-wait:?";
}

pub fn prune(app: *App, ctx: anytype) !void {
    const now = util.now(ctx.io);
    _ = try app.db.exec(ctx, "DELETE FROM magic_requests WHERE expires_at < ?", .{now - 86_400});
    _ = try app.db.exec(ctx, "DELETE FROM mail_days WHERE day < ?", .{@divFloor(now, 86_400) - 7});
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    // Asking sends mail: 10 a minute per address (and the per-email and
    // daily caps in `start`). Polling runs every 2 s while the app waits,
    // and codes are already capped at 5 per request, so those two get a
    // looser bucket of their own.
    const asks = app.group("/v1/auth", .{anole.ratelimit.Middleware.init(state.limiter.limiter(), .{ .limit = 10, .window = .fromSeconds(60), .on_error = .deny })});
    asks.post("/magic", ask);
    const waits = app.group("/v1/auth/magic", .{anole.ratelimit.Middleware.init(state.limiter.limiter(), .{ .limit = 120, .window = .fromSeconds(60), .on_error = .deny, .key = waitKey })});
    waits.post("/poll", poll);
    waits.post("/code", enterCode);

    const page_limit = anole.ratelimit.Middleware.init(state.limiter.limiter(), .{ .limit = 30, .window = .fromSeconds(60), .on_error = .deny });
    const pages = app.group("/auth/l", .{page_limit});
    pages.get("/:token", page);
    pages.post("/:token/approve", approveLink);
    pages.post("/:token/deny", denyLink);

    const user = app.group("/v1/auth", .{auth.Authenticate{ .app = state }});
    user.post("/email", changeEmail);
    user.get("/sign_ins", signIns);
    user.post("/logout_all", logOutAll);
}

test "codes are six digits and hashes compare in constant time" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var buf: [6]u8 = undefined;
    for (0..50) |_| {
        try newCode(threaded.io(), &buf);
        for (buf) |c| try std.testing.expect(std.ascii.isDigit(c));
    }
    try std.testing.expect(sameDigest("abc", "abc"));
    try std.testing.expect(!sameDigest("abc", "abd"));
    try std.testing.expect(!sameDigest("abc", "ab"));
}

test "a pending request past its deadline reads as expired" {
    const r: Row = .{ .id = "x", .purpose = "sign_in", .user_id = null, .email = "a@b.c", .code_hash = "", .secret_hash = "", .device_name = "", .ip_prefix = "", .status = "pending", .attempts = 0, .created_at = 0, .expires_at = 100 };
    try std.testing.expectEqual(Status.pending, statusOf(r, 99));
    try std.testing.expectEqual(Status.expired, statusOf(r, 100));
    var done = r;
    done.status = "redeemed";
    try std.testing.expectEqual(Status.redeemed, statusOf(done, 1000));
}
