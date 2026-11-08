-- Remote control without an account (owner, 2026-11-08). Hosts, devices and
-- pairings keep `user_id NOT NULL` (a rebuild would cascade inside the
-- migration's transaction); an anonymous host belongs to the reserved
-- `anonymous` user, which can never sign in (its address is on .invalid,
-- refused by magic.zig). Claiming moves a host to a real account.
INSERT OR IGNORE INTO users (id, name, email, created_at) VALUES ('anonymous', 'Anonymous', 'anonymous@everyai.invalid', 0);

ALTER TABLE remote_hosts ADD COLUMN created_ip TEXT NOT NULL DEFAULT '';  -- /24 or /48, for per-network limits
ALTER TABLE remote_hosts ADD COLUMN claimed_at INTEGER;
CREATE INDEX remote_hosts_ip ON remote_hosts(created_ip, created_at);

-- Bytes the relay sent per subject ("host:<id>", "account:<id>") and period
-- ("d<epoch day>", "m<year*12+month-1>"); egress.zig adds to it hourly.
CREATE TABLE egress_usage (
    subject TEXT NOT NULL,
    period  TEXT NOT NULL,
    bytes   INTEGER NOT NULL,
    PRIMARY KEY (subject, period)
);
