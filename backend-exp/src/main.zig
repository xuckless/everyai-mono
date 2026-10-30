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
pub const migrations = @import("migrations.zig");
pub const auth = @import("auth.zig");
pub const billing = @import("billing.zig");
pub const models = @import("models.zig");
pub const chat = @import("chat.zig");
pub const gateway = @import("gateway.zig");
pub const util = @import("util.zig");
pub const openrouter = @import("openrouter.zig");
const agents = @import("agents.zig");
pub const tools = @import("tools.zig");
pub const images = @import("images.zig");
pub const routing = @import("routing.zig");
pub const polish = @import("polish.zig");
pub const anthropic = @import("anthropic.zig");
pub const devtools = @import("devtools.zig");
pub const safe_fetch = @import("net/safe_fetch.zig");
pub const tool_wait = @import("tool_wait.zig");
pub const remote = @import("remote.zig");

pub const std_options = anole.std_options;

/// The largest request body (chat attachments are inline base64).
pub const body_max = 32 << 20;
pub const panic = anole.panic;

/// The state every handler gets first.
pub const App = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    db: *anole.sqlite.Client,
    jwt_keys: [1]anole.auth.Key,
    google_keys: ?*anole.auth.Keyring = null,
    stripe_secrets: [1][]const u8 = .{""},
    /// OpenRouter: every model call goes here unless `route` says otherwise.
    /// Tests swap in a fake.
    upstream: openrouter.Upstream,
    /// Anthropic's own API (null without ANTHROPIC_API_KEY), for `anthropic/*`
    /// models while the dev switch `native_anthropic` is on.
    anthropic: ?openrouter.Upstream = null,
    native_anthropic: std.atomic.Value(bool) = .init(false),
    catalog: models.Catalog,
    /// Chat turns parked on a tool the app runs (`POST /v1/chat/tool_result`).
    waits: tool_wait.Waits = .{},
    /// Fetches URLs from model tool calls (`web_fetch`), refusing local and
    /// private addresses; null (tests) fails every such fetch.
    web: ?*const safe_fetch.Fetcher = null,
    /// Live remote-host and client sockets (remote.zig).
    relay: remote.Relay = .{},

    pub const Route = struct { up: openrouter.Upstream, provider: []const u8 };

    /// Where a call to `model` goes. `native_ok` is false for calls that need
    /// OpenRouter features (the web plugin in Search mode).
    pub fn route(self: *App, model: []const u8, native_ok: bool) Route {
        if (native_ok and std.mem.startsWith(u8, model, "anthropic/") and self.native_anthropic.load(.monotonic)) {
            if (self.anthropic) |a| return .{ .up = a, .provider = "anthropic" };
        }
        return .{ .up = self.upstream, .provider = "openrouter" };
    }
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
    routing.routes(app, state);
    polish.routes(app, state);
    devtools.routes(app, state);
    agents.routes(app, state);
    remote.routes(app, state);
}

/// Schema and seed data; run before serving.
pub fn prepare(state: *App, ctx: anytype) !void {
    _ = try anole.db.migrate(state.db, ctx, &migrations.all);
    const saved = try state.db.optional([]const u8, ctx, "SELECT value FROM settings WHERE key = 'upstream.anthropic'", .{});
    state.native_anthropic.store(std.mem.eql(u8, saved orelse state.cfg.anthropic_upstream, "anthropic"), .monotonic);
    if (state.cfg.dev_auth) try auth.seedDevUser(state, ctx);
}

pub fn main(init: std.process.Init) !void {
    const cfg = try anole.config.load(config.Config, init, .{ .env_files = &.{ ".env", "../.env" } });

    if (config.lanExposure(cfg)) {
        std.log.err("refusing to start: HOST={s} is reachable from the network and DEV_AUTH=true lets anyone there use the dev account. " ++
            "Set DEV_AUTH=false, bind HOST=127.0.0.1, or set DEV_AUTH_LAN=true to accept this on a trusted LAN.", .{cfg.host});
        return error.DevAuthOnLan;
    }

    var state: App = .{
        .gpa = init.gpa,
        .cfg = cfg,
        .db = undefined,
        .jwt_keys = .{.{ .kid = "k1", .alg = .HS256, .material = .{ .hmac = cfg.jwt_secret.expose() } }},
        .upstream = undefined,
        .catalog = .init(init.gpa),
    };
    defer state.catalog.deinit();
    // After the server (defers run last first): rooms outlive their sockets.
    defer state.relay.deinit();

    var app = try anole.Server(App).init(init.gpa, .{
        .http = .{ .address = cfg.host, .port = cfg.port, .h2c = true },
        // Argon2 runs on the blocking pool, not an executor.
        .blocking = .{},
        .client = .{ .timeout = null },
        // Chat attachments (images, PDFs) arrive inline as base64.
        .limits = .{ .body_max = body_max },
        // Non-streamed gateway completions (agents writing whole files) run
        // well past the 30 s default; the upstream bounds them anyway.
        .timeouts = .{ .request = .fromSeconds(600) },
    }, &state);
    defer app.deinit();
    const io = app.io();

    var or_client: openrouter.Client = .{ .base_url = cfg.openrouter_base_url, .api_key = cfg.openrouter_api_key.expose(), .referer = cfg.public_url };
    state.upstream = or_client.upstream();
    var an_client: openrouter.Client = .{ .base_url = cfg.anthropic_base_url, .api_key = if (cfg.anthropic_api_key) |k| k.expose() else "", .auth = .anthropic };
    var an_adapter: anthropic.Adapter = .{ .inner = an_client.upstream(), .catalog = &state.catalog };
    if (cfg.anthropic_api_key != null) state.anthropic = an_adapter.upstream();

    // Its own client: the shared one may reach local upstreams in development.
    var web_client = anole.http.Client.init(init.gpa, io, safe_fetch.clientOptions(.{}));
    defer web_client.deinit();
    const web: safe_fetch.Fetcher = .{ .http = &web_client };
    state.web = &web;

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
    std.log.info("EveryAI backend-exp on :{d} (dev_auth={}, markup={d:.2}, stripe={s}, claude via {s})", .{
        cfg.port, cfg.dev_auth, cfg.markup, if (cfg.stripe_secret_key == null) "mock" else "test", state.route("anthropic/", true).provider,
    });
    try app.run();
}

test {
    _ = util;
    _ = tools;
    _ = chat;
    _ = gateway;
    _ = safe_fetch;
    _ = models;
    _ = anthropic;
    _ = agents;
    _ = tool_wait;
    _ = polish;
    _ = remote;
}
