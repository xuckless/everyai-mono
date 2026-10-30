//! Ordered SQL migrations for SQLite. Each migration runs once, in its own
//! transaction, and is recorded in `schema_migrations`. Candidate for
//! upstreaming into Anole (`anole.db.migrate`).
const std = @import("std");
const anole = @import("anole");

pub const Migration = struct {
    version: u32,
    name: []const u8,
    sql: []const u8,
};

/// The app's migrations, embedded at compile time. Append only; never edit
/// one that has shipped.
pub const all = [_]Migration{
    .{ .version = 1, .name = "init", .sql = @embedFile("../migrations/001_init.sql") },
    .{ .version = 2, .name = "upstreams", .sql = @embedFile("../migrations/002_upstreams.sql") },
};

/// Applies every migration newer than the database's latest. Returns how many ran.
pub fn run(db: *anole.sqlite.Client, ctx: anytype, migrations: []const Migration) !usize {
    try db.execScript(ctx,
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\    version    INTEGER PRIMARY KEY,
        \\    name       TEXT NOT NULL,
        \\    applied_at INTEGER NOT NULL
        \\);
    );
    const current = try db.one(i64, ctx, "SELECT COALESCE(MAX(version), 0) FROM schema_migrations", .{});

    var applied: usize = 0;
    var previous: u32 = 0;
    for (migrations) |m| {
        // A list out of order would silently skip a migration.
        if (m.version <= previous) return error.MigrationsOutOfOrder;
        previous = m.version;
        if (m.version <= current) continue;

        const now = std.Io.Clock.real.now(ctx.io).toSeconds();
        const script = try std.fmt.allocPrint(ctx.arena,
            \\BEGIN;
            \\{s}
            \\INSERT INTO schema_migrations (version, name, applied_at) VALUES ({d}, '{s}', {d});
            \\COMMIT;
        , .{ m.sql, m.version, m.name, now });
        db.execScript(ctx, script) catch |err| {
            db.execScript(ctx, "ROLLBACK;") catch {};
            std.log.err("migration {d}_{s} failed: {t}", .{ m.version, m.name, err });
            return err;
        };
        std.log.info("applied migration {d}_{s}", .{ m.version, m.name });
        applied += 1;
    }
    return applied;
}
