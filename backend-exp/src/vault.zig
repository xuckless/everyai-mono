//! Vault sync, **dev only** (docs/vault/format.md, phase V2): the account's
//! encrypted vault files as opaque blobs. The server stores ciphertext and
//! metadata and can't read either; integrity is the client's (AEAD per item,
//! a signed manifest with a version it never lets go backwards). Writes are
//! optimistic: a PUT names the version it replaces, and a stale one is a 409
//! with the current version, so two devices can't overwrite each other.
//!
//! The routes exist only with `VAULT_SYNC_DEV=true`; production refuses to
//! start with it (main.zig) until the vault has had an external review.
//!
//!   GET    /v1/vault/blobs              [{name, version, size, updated_at}]
//!   GET    /v1/vault/blobs/:name        {name, version, data (base64)}
//!   PUT    /v1/vault/blobs/:name        {version: <the one it replaces, 0 = new>, data} → {name, version} | 409 {version}
//!   DELETE /v1/vault/blobs/:name?version=N
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const util = @import("util.zig");

pub const max_blob = 1 << 20;
pub const max_blobs = 5000;

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 96) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return name[0] != '.';
}

const Meta = struct { name: []const u8, version: i64, size: i64, updated_at: i64 };

fn list(app: *App, req: *anole.Request) ![]const Meta {
    const who = try auth.identity(req);
    return app.db.all(Meta, req, "SELECT name, version, length(data) AS size, updated_at FROM vault_blobs WHERE user_id = ? ORDER BY name", .{who.user_id});
}

fn get(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { name: []const u8 } })) !struct { name: []const u8, version: i64, data: []const u8 } {
    const who = try auth.identity(req);
    const row = try app.db.optional(struct { version: i64, data: anole.sqlite.Blob }, req, "SELECT version, data FROM vault_blobs WHERE user_id = ? AND name = ?", .{ who.user_id, in.path.name }) orelse return error.NotFound;
    const enc = std.base64.standard.Encoder;
    const out = try req.arena.alloc(u8, enc.calcSize(row.data.data.len));
    return .{ .name = in.path.name, .version = row.version, .data = enc.encode(out, row.data.data) };
}

const Put = struct { version: i64, data: []const u8 };

fn put(app: *App, req: *anole.Request, res: *anole.Response, in: anole.In(.{ .path = struct { name: []const u8 }, .body = Put })) !void {
    const who = try auth.identity(req);
    if (!validName(in.path.name)) return res.fail(.unprocessable_entity, "a blob name is letters, digits, - _ and .");
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(in.body.data) catch return res.fail(.unprocessable_entity, "data is not base64");
    if (size > max_blob) return res.fail(.payload_too_large, "a vault blob is at most 1 MiB");
    const data = try req.arena.alloc(u8, size);
    dec.decode(data, in.body.data) catch return res.fail(.unprocessable_entity, "data is not base64");
    const now = util.now(req.io);
    const next = in.body.version + 1;
    const written = if (in.body.version == 0) blk: {
        if (try app.db.one(i64, req, "SELECT COUNT(*) FROM vault_blobs WHERE user_id = ?", .{who.user_id}) >= max_blobs)
            return res.fail(.conflict, "the vault holds the most blobs it can");
        break :blk try app.db.exec(req, "INSERT OR IGNORE INTO vault_blobs (user_id, name, version, data, updated_at) VALUES (?, ?, 1, ?, ?)", .{ who.user_id, in.path.name, anole.sqlite.Blob{ .data = data }, now });
    } else try app.db.exec(req, "UPDATE vault_blobs SET version = ?, data = ?, updated_at = ? WHERE user_id = ? AND name = ? AND version = ?", .{ next, anole.sqlite.Blob{ .data = data }, now, who.user_id, in.path.name, in.body.version });
    if (written == 0) {
        const current = try app.db.optional(i64, req, "SELECT version FROM vault_blobs WHERE user_id = ? AND name = ?", .{ who.user_id, in.path.name }) orelse 0;
        res.status = .conflict;
        return res.json(.{ .message = "this blob changed on another device; fetch it, merge, and try again", .code = "vault_conflict", .version = current });
    }
    return res.json(.{ .name = in.path.name, .version = next });
}

fn delete(app: *App, req: *anole.Request, res: *anole.Response, in: anole.In(.{ .path = struct { name: []const u8 }, .query = struct { version: i64 } })) !void {
    const who = try auth.identity(req);
    if (try app.db.exec(req, "DELETE FROM vault_blobs WHERE user_id = ? AND name = ? AND version = ?", .{ who.user_id, in.path.name, in.query.version }) == 0) {
        const current = try app.db.optional(i64, req, "SELECT version FROM vault_blobs WHERE user_id = ? AND name = ?", .{ who.user_id, in.path.name }) orelse return error.NotFound;
        res.status = .conflict;
        return res.json(.{ .message = "this blob changed on another device", .code = "vault_conflict", .version = current });
    }
    res.status = .no_content;
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    if (!state.cfg.vault_sync_dev) return;
    const v = app.group("/v1/vault", .{auth.Authenticate{ .app = state }});
    v.get("/blobs", list);
    v.get("/blobs/:name", get);
    v.put("/blobs/:name", put);
    v.delete("/blobs/:name", delete);
}

test validName {
    try std.testing.expect(validName("manifest.json"));
    try std.testing.expect(validName("item-abc_1"));
    try std.testing.expect(!validName("../vault"));
    try std.testing.expect(!validName(".hidden"));
    try std.testing.expect(!validName(""));
}
