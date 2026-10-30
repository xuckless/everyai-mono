-- Accounts. Money is integer micro-USD (1 USD = 1_000_000) everywhere.
CREATE TABLE users (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    email         TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT,
    google_sub    TEXT UNIQUE,
    plan          TEXT NOT NULL DEFAULT 'free',
    created_at    INTEGER NOT NULL
);

-- Opaque refresh tokens, stored as SHA-256 hex; rotated on every use.
CREATE TABLE refresh_tokens (
    token_hash TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL,
    revoked    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX refresh_tokens_user ON refresh_tokens(user_id);

-- Gateway API keys (OpenHands and other OpenAI-compatible clients).
CREATE TABLE api_keys (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    digest       TEXT NOT NULL UNIQUE,
    prefix       TEXT NOT NULL,
    created_at   INTEGER NOT NULL,
    last_used_at INTEGER
);

-- Subscription state (Stripe test mode or mock).
CREATE TABLE subscriptions (
    user_id                TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    plan                   TEXT NOT NULL,
    status                 TEXT NOT NULL,
    stripe_subscription_id TEXT,
    current_period_end     INTEGER
);

-- Monthly included usage per plan period.
CREATE TABLE quota_periods (
    user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    period_start    INTEGER NOT NULL,
    period_end      INTEGER NOT NULL,
    included_micros INTEGER NOT NULL,
    used_micros     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, period_start)
);

-- Prepaid wallet: append-only; balance = SUM(amount_micros).
CREATE TABLE wallet_ledger (
    id            INTEGER PRIMARY KEY,
    user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount_micros INTEGER NOT NULL,
    kind          TEXT NOT NULL CHECK (kind IN ('topup', 'usage', 'grant', 'refund')),
    ref           TEXT,
    created_at    INTEGER NOT NULL
);
CREATE INDEX wallet_ledger_user ON wallet_ledger(user_id);

-- One row per upstream call, priced.
CREATE TABLE usage_events (
    id                 INTEGER PRIMARY KEY,
    user_id            TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    api_key_id         TEXT,
    session            TEXT,
    kind               TEXT NOT NULL,
    model              TEXT NOT NULL,
    prompt_tokens      INTEGER NOT NULL DEFAULT 0,
    completion_tokens  INTEGER NOT NULL DEFAULT 0,
    cached_tokens      INTEGER NOT NULL DEFAULT 0,
    cache_write_tokens INTEGER NOT NULL DEFAULT 0,
    cost_micros        INTEGER NOT NULL,
    charged_micros     INTEGER NOT NULL,
    from_quota_micros  INTEGER NOT NULL,
    from_wallet_micros INTEGER NOT NULL,
    created_at         INTEGER NOT NULL
);
CREATE INDEX usage_events_user_time ON usage_events(user_id, created_at);

-- Processed Stripe events (idempotency).
CREATE TABLE stripe_events (
    id         TEXT PRIMARY KEY,
    type       TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
