-- Server-wide settings changed at runtime (the dev upstream switch).
CREATE TABLE settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Which provider served the call: "openrouter" or "anthropic".
ALTER TABLE usage_events ADD COLUMN provider TEXT NOT NULL DEFAULT 'openrouter';

-- Per-session totals for the app's usage meter.
CREATE INDEX usage_events_session ON usage_events(user_id, session);
