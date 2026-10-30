//! The app's SQL migrations, embedded at compile time and run by
//! `anole.db.migrate`. Append only; never edit one that has shipped.
const anole = @import("anole");

pub const all = [_]anole.db.Migration{
    .{ .version = 1, .name = "init", .sql = @embedFile("migrations/001_init.sql") },
    .{ .version = 2, .name = "upstreams", .sql = @embedFile("migrations/002_upstreams.sql") },
    .{ .version = 3, .name = "remote", .sql = @embedFile("migrations/003_remote.sql") },
};
