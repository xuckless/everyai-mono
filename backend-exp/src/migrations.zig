//! The app's SQL migrations, embedded at compile time and run by
//! `anole.db.migrate`. Append only; never edit one that has shipped.
const anole = @import("anole");

pub const all = [_]anole.db.Migration{
    .{ .version = 1, .name = "init", .sql = @embedFile("migrations/001_init.sql") },
    .{ .version = 2, .name = "upstreams", .sql = @embedFile("migrations/002_upstreams.sql") },
    .{ .version = 3, .name = "remote", .sql = @embedFile("migrations/003_remote.sql") },
    .{ .version = 4, .name = "hooks", .sql = @embedFile("migrations/004_hooks.sql") },
    .{ .version = 5, .name = "magic", .sql = @embedFile("migrations/005_magic.sql") },
    .{ .version = 6, .name = "remote_anonymous", .sql = @embedFile("migrations/006_remote_anonymous.sql") },
    .{ .version = 7, .name = "vault_dev", .sql = @embedFile("migrations/007_vault_dev.sql") },
};
