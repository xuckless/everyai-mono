//! Typed settings, loaded once in `main` by `anole.config.load`: the defaults
//! below, then (development only) `.env` files: backend-exp/.env, then the monorepo's root .env;
//! then the environment. `Secret`s never print.
const std = @import("std");
const anole = @import("anole");

pub const Config = struct {
    port: u16 = 8080,
    /// Interface to bind. "0.0.0.0" lets phones on the LAN reach a dev server;
    /// with DEV_AUTH on, anyone there can use the dev account.
    host: []const u8 = "127.0.0.1",
    /// Signs access tokens (HS256), 32+ characters. Required in production;
    /// in development a random one is made per run when unset.
    jwt_secret: ?anole.Secret = null,
    /// PEM files for serving HTTPS on `port` instead of plain HTTP (chain
    /// leaf first). Both or neither. Reloaded on SIGHUP, so a renewed
    /// certificate needs no restart.
    tls_cert_path: ?[]const u8 = null,
    tls_key_path: ?[]const u8 = null,
    /// Requests per minute from one client address (IPv6 by /64) across the
    /// whole API, a token bucket of the same size; 0 turns it off. /v1/auth
    /// keeps its own tighter limit on top.
    rate_limit_per_minute: u32 = 600,
    /// Where the SQLite file lives (relative to the working directory).
    database_path: []const u8 = "data/everyai.db",

    /// Upstream model provider (OpenAI-compatible API). Optional: without it
    /// the server runs on the keys users add in the app (byok.zig), and a call
    /// with none gets a clear "add your key" error.
    openrouter_api_key: ?anole.Secret = null,
    openrouter_base_url: []const u8 = "https://openrouter.ai/api/v1",
    /// Shown to OpenRouter for attribution (HTTP-Referer / X-Title).
    public_url: []const u8 = "http://localhost:8080",

    /// Anthropic's own API, for `anthropic/*` models when the dev switch
    /// (`PUT /v1/dev/upstream`) sends them there instead of OpenRouter.
    anthropic_api_key: ?anole.Secret = null,
    anthropic_base_url: []const u8 = "https://api.anthropic.com/v1",
    /// Where `anthropic/*` models go until the switch is used: "openrouter" or "anthropic".
    anthropic_upstream: []const u8 = "openrouter",

    /// Price multiplier on upstream cost for every paid request (only with
    /// billing on; see `priceMarkup`).
    markup: f64 = 1.15,
    /// Credits, plans, wallet and Stripe. Parked: off by default, the
    /// plan/billing/checkout/webhook routes are 404, nothing is charged and
    /// prices show at cost. Usage is still recorded.
    billing_enabled: bool = false,
    /// With billing off, the server's own model key would be free to anyone
    /// who can reach it. Production refuses to start with one unless this
    /// says that is intended (a self-hosted, trusted server).
    server_key_unmetered: bool = false,
    /// Model used when a request names none.
    default_model: []const u8 = "anthropic/claude-haiku-5.5",
    /// Research mode always runs on this model.
    research_model: []const u8 = "perplexity/sonar-deep-research",
    /// Cheap model for follow-up questions and titles.
    utility_model: []const u8 = "google/gemini-3.5-flash-lite",
    /// Per-job overrides of the utility model (empty = use it); see routing.zig.
    aux_title_model: []const u8 = "",
    aux_followups_model: []const u8 = "",
    aux_compaction_model: []const u8 = "",
    aux_critique_model: []const u8 = "",
    aux_judge_model: []const u8 = "",
    /// The typed decider (decide.zig): routing, ranking and judging calls.
    aux_decide_model: []const u8 = "",
    /// Part summaries and their merge in `summarise_parts` (summarise.zig).
    aux_summarise_model: []const u8 = "",
    /// What the Auto model (`everyai/auto`) runs a message on, by the tier
    /// the decider picks.
    auto_fast_model: []const u8 = "anthropic/claude-haiku-5.5",
    auto_balanced_model: []const u8 = "anthropic/claude-sonnet-5.5",
    auto_best_model: []const u8 = "anthropic/claude-opus-5.5",
    /// The vision model behind the figure Polish button (`POST /v1/figures/polish`).
    aux_polish_model: []const u8 = "anthropic/claude-haiku-5.5",
    /// The most one Polish round may charge, in micro-USD after markup.
    polish_max_micros: i64 = 50_000,
    /// Model for image generation (`generate_image` tool and /v1/images).
    image_model: []const u8 = "google/gemini-3.1-flash-image",
    /// Vector (SVG) model for `generate_image` with `engine: "vector"`.
    vector_model: []const u8 = "recraft/recraft-v4.1-vector",
    /// Tool-loop rounds per chat turn before the server stops calling the model.
    max_tool_steps: u8 = 6,
    /// How long a chat turn waits for the app to answer a client-executed
    /// tool (`client_tools`) before the model gets a timeout error instead.
    client_tool_timeout_ms: u32 = 300_000,
    /// Prompt-cache lifetime for explicit breakpoints (Anthropic/Gemini): "5m" or "1h".
    cache_ttl: []const u8 = "5m",
    /// OpenRouter web plugin engine for Search mode. "exa" injects results and
    /// always yields url citations; "native" (provider search) is cheaper but
    /// only cites when the model chooses to.
    search_engine: []const u8 = "exa",
    /// The same for gateway (coding agent) traffic, where sessions run long.
    gateway_cache_ttl: []const u8 = "1h",

    /// Prototype convenience: requests without credentials act as the seeded
    /// dev user (local development only). Off in production builds.
    dev_auth: bool = true,
    /// Acknowledges that DEV_AUTH is open to the network when `host` is not
    /// loopback; without it `main` refuses to start (see `lanExposure`).
    dev_auth_lan: bool = false,

    /// Sign-in mail (magic.zig) through Resend's HTTPS API. Without a key,
    /// development logs the message; production answers 503.
    resend_api_key: ?anole.Secret = null,
    mail_from: []const u8 = "EveryAI <noreply@everyai.dev>",
    /// Sends a day, under Resend's free 100: past it sign-in answers 503.
    mail_daily_cap: i64 = 90,

    /// Tests and a developer's own hosted run only: take `X-Provider-Key-*`
    /// on a server that isn't the app's local one. Off, such a request is a
    /// 400 `keys_not_accepted`; production refuses to start with it on.
    accept_provider_keys: bool = false,

    /// Vault sync (vault.zig), dev only until reviewed: the /v1/vault routes
    /// exist only with this on, and production refuses to start with it.
    vault_sync_dev: bool = false,

    /// Relay egress (egress.zig). The server's send rate and month, sockets
    /// at once (more wait in one queue), and per-subject limits: an
    /// anonymous host, and an account (its claimed hosts together).
    egress_rate_mbps: u64 = 40,
    /// The month is sized to GCP's Always Free egress (1 GB a month from
    /// North America, Premium tier only; about $0.12/GB past it, checked
    /// 2026-11-08 from secondary sources): 768 MB for the relay leaves room for
    /// the API itself. Raise it once a budget allows.
    egress_monthly_mb: u64 = 768,
    /// Log a warning once the month's relay bytes pass this many MB (0 = 80%
    /// of EGRESS_MONTHLY_MB).
    egress_warn_mb: u64 = 0,
    relay_max_live: u32 = 500,
    relay_per_subject_live: u32 = 16,
    relay_host_daily_mb: u64 = 32,
    relay_host_monthly_mb: u64 = 128,
    relay_account_daily_mb: u64 = 64,
    relay_account_monthly_mb: u64 = 256,
    /// Anonymous hosts: new ones per network per hour, live ones per
    /// network, devices per host, and days without a connection before one
    /// is removed (claimed hosts never expire).
    anon_hosts_per_hour: i64 = 5,
    anon_hosts_per_network: i64 = 20,
    devices_per_host: i64 = 10,
    anon_host_idle_days: i64 = 30,

    /// Stripe test mode. Without a key, checkout credits immediately (mock).
    stripe_secret_key: ?anole.Secret = null,
    stripe_webhook_secret: ?anole.Secret = null,

    /// The app's bundled sidecar (local.zig): loopback only, every route needs
    /// `X-EveryAI-Local: <LOCAL_TOKEN>`, local models and the user's own keys,
    /// nothing charged. Off on a deployed server.
    local_mode: bool = false,
    local_token: ?anole.Secret = null,
    /// The app's process id: when it is gone (the app crashed or was killed),
    /// the sidecar unloads the models it loaded and exits (local_models.zig).
    local_parent_pid: ?i64 = null,

    pub const production = .{ .dev_auth = false };

    /// The markup applied to prices and charges: 1.0 with billing parked.
    pub fn priceMarkup(cfg: Config) f64 {
        return if (cfg.billing_enabled) cfg.markup else 1.0;
    }

    /// True when the server holds its own model key while nothing is
    /// billed and nobody acknowledged that (`SERVER_KEY_UNMETERED=true`).
    pub fn unmeteredServerKey(cfg: Config) bool {
        const has_key = cfg.openrouter_api_key != null or cfg.anthropic_api_key != null;
        return has_key and !cfg.billing_enabled and !cfg.local_mode and !cfg.server_key_unmetered;
    }
};

/// Whether `host` only accepts connections from this machine.
pub fn isLoopback(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "[::1]") or
        std.mem.startsWith(u8, host, "127.");
}

/// True when dev auth would hand the dev account to anyone who can reach the
/// server, and nobody said that was intended (`DEV_AUTH_LAN=true`).
pub fn lanExposure(cfg: Config) bool {
    return cfg.dev_auth and !cfg.dev_auth_lan and !isLoopback(cfg.host);
}

/// True when dev auth is on in a production process that isn't the app's
/// own local server (which runs as production with dev auth on loopback,
/// behind its launch token).
pub fn devAuthInProduction(cfg: Config, environment: anole.env.Environment) bool {
    return cfg.dev_auth and !cfg.local_mode and environment != .development;
}

test "billing parked: prices at cost, an unmetered server key needs acknowledging" {
    var c: Config = .{ .jwt_secret = .init("x") };
    try std.testing.expectEqual(@as(f64, 1.0), c.priceMarkup());
    try std.testing.expect(!c.unmeteredServerKey());
    c.openrouter_api_key = .init("x");
    try std.testing.expect(c.unmeteredServerKey());
    c.server_key_unmetered = true;
    try std.testing.expect(!c.unmeteredServerKey());
    c.server_key_unmetered = false;
    c.billing_enabled = true;
    try std.testing.expect(!c.unmeteredServerKey());
    try std.testing.expectEqual(@as(f64, 1.15), c.priceMarkup());
}

test "dev auth on a non-loopback host needs DEV_AUTH_LAN" {
    const base: Config = .{ .jwt_secret = .init("x"), .openrouter_api_key = .init("x") };
    try std.testing.expect(!lanExposure(base));
    var lan = base;
    lan.host = "0.0.0.0";
    try std.testing.expect(lanExposure(lan));
    lan.dev_auth_lan = true;
    try std.testing.expect(!lanExposure(lan));
    lan.dev_auth_lan = false;
    lan.dev_auth = false;
    try std.testing.expect(!lanExposure(lan));
    try std.testing.expect(isLoopback("127.0.0.1") and isLoopback("localhost") and !isLoopback("192.168.1.5"));
}

test "production refuses dev auth, except the app's local server" {
    var c: Config = .{ .jwt_secret = .init("x"), .dev_auth = true };
    try std.testing.expect(!devAuthInProduction(c, .development));
    try std.testing.expect(devAuthInProduction(c, .production));
    c.local_mode = true;
    try std.testing.expect(!devAuthInProduction(c, .production));
    c.local_mode = false;
    c.dev_auth = false;
    try std.testing.expect(!devAuthInProduction(c, .production));
}
