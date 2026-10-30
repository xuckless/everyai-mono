-- Remote hosts for Code sessions: desktops that run the agent sidecar and
-- relay through the backend. Tokens are stored as SHA-256 hex; public keys
-- are the endpoints' own (end-to-end encryption), kept here only to hand
-- over during pairing.
CREATE TABLE remote_hosts (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    platform     TEXT NOT NULL DEFAULT '',
    public_key   TEXT NOT NULL,
    token_hash   TEXT NOT NULL UNIQUE,
    created_at   INTEGER NOT NULL,
    last_seen_at INTEGER
);
CREATE INDEX remote_hosts_user ON remote_hosts(user_id);

-- Client devices paired with a host. `approved` turns 1 once the host
-- accepts the pairing; until then the device token opens nothing.
CREATE TABLE remote_devices (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    host_id      TEXT NOT NULL REFERENCES remote_hosts(id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    public_key   TEXT NOT NULL,
    token_hash   TEXT NOT NULL UNIQUE,
    approved     INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL,
    last_seen_at INTEGER
);
CREATE INDEX remote_devices_host ON remote_devices(host_id);

-- Pairing codes: single use and short-lived. open -> pending (redeemed by a
-- device) -> approved | denied.
CREATE TABLE remote_pairings (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    host_id     TEXT NOT NULL REFERENCES remote_hosts(id) ON DELETE CASCADE,
    code_hash   TEXT NOT NULL UNIQUE,
    status      TEXT NOT NULL DEFAULT 'open',
    expires_at  INTEGER NOT NULL,
    device_id   TEXT REFERENCES remote_devices(id) ON DELETE SET NULL,
    decide_by   INTEGER,
    created_at  INTEGER NOT NULL,
    decided_at  INTEGER
);
CREATE INDEX remote_pairings_host ON remote_pairings(host_id, status);
