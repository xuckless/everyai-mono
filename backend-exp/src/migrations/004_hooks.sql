-- Webhooks that start Code sessions on a paired host (hooks.zig). The secret
-- is stored as it is: an HMAC needs the plain secret, so it can't be hashed. A
-- leaked one lets someone send signed events to that host until the hook is
-- deleted; encrypting it at rest with a server key is a later option.
CREATE TABLE hooks (
    id               TEXT PRIMARY KEY,
    user_id          TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    host_id          TEXT NOT NULL REFERENCES remote_hosts(id) ON DELETE CASCADE,
    name             TEXT NOT NULL,
    secret           TEXT NOT NULL,
    created_at       INTEGER NOT NULL,
    last_delivery_at INTEGER
);
CREATE INDEX hooks_user ON hooks(user_id);

-- Accepted deliveries, kept until the host acks them (at most a day). `body`
-- is cleared on the ack; the row stays 7 days so a replay of the same
-- delivery is recognised (`dedup_key`: the GitHub delivery id, else the
-- signature).
CREATE TABLE hook_deliveries (
    id          TEXT PRIMARY KEY,
    hook_id     TEXT NOT NULL REFERENCES hooks(id) ON DELETE CASCADE,
    host_id     TEXT NOT NULL,
    dedup_key   TEXT NOT NULL,
    headers     TEXT NOT NULL,
    body        BLOB,
    size        INTEGER NOT NULL,
    created_at  INTEGER NOT NULL,
    acked_at    INTEGER,
    UNIQUE (hook_id, dedup_key)
);
CREATE INDEX hook_deliveries_pending ON hook_deliveries(host_id, acked_at);
