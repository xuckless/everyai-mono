//! EveryAI backend-exp: the prototype API on Anole.
//!
//!   zig build run     # http://localhost:8080
//!   zig build test
//!
//! Areas: auth (auth.zig), models shop (models.zig), chat over SSE with a
//! server-side tool loop (chat.zig), the OpenAI-compatible gateway for
//! OpenHands (gateway.zig), billing (billing.zig).
const std = @import("std");
const anole = @import("anole");
pub const config = @import("config.zig");
pub const migrate = @import("db/migrate.zig");
pub const auth = @import("auth.zig");
pub const billing = @import("billing.zig");
pub const models = @import("models.zig");
pub const chat = @import("chat.zig");
pub const gateway = @import("gateway.zig");
pub const util = @import("util.zig");
pub const openrouter = @import("openrouter.zig");
pub const tools = @import("tools.zig");
pub const images = @import("images.zig");
pub const sse_client = @import("net/sse_client.zig");

pub const std_options = anole.std_options;
pub const panic = anole.panic;

/// The state every handler gets first.
pub const App = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    db: *anole.sqlite.Client,
    jwt_keys: [1]anole.auth.Key,
    google_keys: ?*anole.auth.Keyring = null,
    stripe_secrets: [1][]const u8 = .{""},
    /// The upstream all model calls go through; tests swap in a fake.
    upstream: openrouter.Upstream,
    catalog: models.Catalog,
};

fn ping(_: *App, _: *anole.Request) struct { ok: bool, service: []const u8 } {
    return .{ .ok = true, .service = "everyai-backend-exp" };
}

/// Apart from `main` so the tests serve the same routes.
pub fn routes(app: *anole.Server(App), state: *App) !void {
    _ = app.health(.{});
    app.openapi(.{ .info = .{ .title = "EveryAI API", .version = "0.1.0" } });
    app.get("/v1/ping", ping);
    auth.routes(app, state);
    billing.routes(app, state);
    models.routes(app, state);
    chat.routes(app, state);
    gateway.routes(app, state);
    images.routes(app, state);
}

/// Schema and seed data; run before serving.
pub fn prepare(state: *App, ctx: anytype) !void {
    _ = try migrate.run(state.db, ctx, &migrate.all);
    if (state.cfg.dev_auth) try auth.seedDevUser(state, ctx);
}

pub fn main(init: std.process.Init) !void {
    const cfg = try anole.config.load(config.Config, init, .{ .env_files = &.{ ".env", "../.env" } });

    var state: App = .{
        .gpa = init.gpa,
        .cfg = cfg,
        .db = undefined,
        .jwt_keys = .{.{ .kid = "k1", .alg = .HS256, .material = .{ .hmac = cfg.jwt_secret.expose() } }},
        .upstream = undefined,
        .catalog = .init(init.gpa),
    };
    defer state.catalog.deinit();

    var app = try anole.Server(App).init(init.gpa, .{
        .http = .{ .port = cfg.port, .h2c = true },
        // Argon2 runs on the blocking pool, not an executor.
        .blocking = .{},
        .client = .{ .timeout = null },
    }, &state);
    defer app.deinit();
    const io = app.io();

    var or_client: openrouter.Client = .{ .base_url = cfg.openrouter_base_url, .api_key = cfg.openrouter_api_key.expose(), .referer = cfg.public_url };
    state.upstream = or_client.upstream();

    if (cfg.google_client_ids.len > 0) {
        const keyring = try init.arena.allocator().create(anole.auth.Keyring);
        keyring.* = anole.auth.Keyring.init(init.gpa, io, app.client(), anole.auth.oidc.Provider.google.jwks_uri);
        state.google_keys = keyring;
    }

    app.use(anole.middleware.RequestId.init(.{}));
    app.use(anole.observe.AccessLog.init(.{}));
    app.use(anole.middleware.Cors.init(.{}));

    const dir = std.fs.path.dirname(cfg.database_path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(io, dir);
    state.db = try app.sqlite(cfg.database_path);
    var setup_arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer setup_arena.deinit();
    var setup: anole.db.Ctx = .{ .io = io, .arena = setup_arena.allocator() };
    try prepare(&state, &setup);

    try routes(&app, &state);
    std.log.info("EveryAI backend-exp on :{d} (dev_auth={}, markup={d:.2}, stripe={s})", .{
        cfg.port, cfg.dev_auth, cfg.markup, if (cfg.stripe_secret_key == null) "mock" else "test",
    });
    try app.run();
}

test {
    _ = util;
    _ = tools;
    _ = chat;
    _ = gateway;
    _ = sse_client;
    _ = models;
}
