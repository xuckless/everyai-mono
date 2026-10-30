//! Typed settings, loaded once in `main` by `anole.config.load`: the defaults
//! below, then `.env` files (backend-exp/.env, then the monorepo's root .env),
//! then the environment. `Secret`s never print.
const anole = @import("anole");

pub const Config = struct {
    port: u16 = 8080,
    /// Interface to bind. "0.0.0.0" lets phones on the LAN reach a dev server;
    /// with DEV_AUTH on, anyone there can use the dev account.
    host: []const u8 = "127.0.0.1",
    /// Signs access tokens (HS256), 32+ characters.
    jwt_secret: anole.Secret,
    /// Where the SQLite file lives (relative to the working directory).
    database_path: []const u8 = "data/everyai.db",

    /// Upstream model provider (OpenAI-compatible API).
    openrouter_api_key: anole.Secret,
    openrouter_base_url: []const u8 = "https://openrouter.ai/api/v1",
    /// Shown to OpenRouter for attribution (HTTP-Referer / X-Title).
    public_url: []const u8 = "http://localhost:8080",

    /// Anthropic's own API, for `anthropic/*` models when the dev switch
    /// (`PUT /v1/dev/upstream`) sends them there instead of OpenRouter.
    anthropic_api_key: ?anole.Secret = null,
    anthropic_base_url: []const u8 = "https://api.anthropic.com/v1",
    /// Where `anthropic/*` models go until the switch is used: "openrouter" or "anthropic".
    anthropic_upstream: []const u8 = "openrouter",

    /// Price multiplier on upstream cost for every paid request.
    markup: f64 = 1.15,
    /// Model used when a request names none.
    default_model: []const u8 = "anthropic/claude-haiku-5.5",
    /// Research mode always runs on this model.
    research_model: []const u8 = "perplexity/sonar-deep-research",
    /// Cheap model for follow-up questions and titles.
    utility_model: []const u8 = "google/gemini-3.5-flash-lite",
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
    /// dev user (the app's DEV_SKIP_AUTH mode). Off in production builds.
    dev_auth: bool = true,

    /// Google OAuth client ids whose ID tokens we accept (comma separated:
    /// android, ios, web/desktop).
    google_client_ids: []const u8 = "",

    /// Stripe test mode. Without a key, checkout credits immediately (mock).
    stripe_secret_key: ?anole.Secret = null,
    stripe_webhook_secret: ?anole.Secret = null,

    pub const production = .{ .dev_auth = false };
};
