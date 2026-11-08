-- Magic-link sign-in (magic.zig): requests, the sign-in history, and the
-- daily mail budget. Passwords and Google sign-in are off; their columns
-- (users.password_hash, users.google_sub) stay nullable and unused.
CREATE TABLE magic_requests (
  id          TEXT PRIMARY KEY,
  purpose     TEXT NOT NULL DEFAULT 'sign_in',          -- sign_in | change_email
  user_id     TEXT REFERENCES users(id) ON DELETE CASCADE, -- change_email only
  email       TEXT NOT NULL COLLATE NOCASE,
  token_hash  TEXT NOT NULL UNIQUE,                     -- SHA-256 of the link token
  code_hash   TEXT NOT NULL,                            -- HMAC-SHA256 of the 6-digit code
  secret_hash TEXT NOT NULL,                            -- SHA-256 of the asking device's secret
  device_name TEXT NOT NULL,
  ip_prefix   TEXT NOT NULL,                            -- /24 or /48, never the address
  status      TEXT NOT NULL DEFAULT 'pending',          -- pending|approved|redeemed|expired|dead|denied
  attempts    INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL,
  decided_at  INTEGER
);
CREATE INDEX magic_requests_email ON magic_requests(email, created_at);

CREATE TABLE sign_ins (
  id          INTEGER PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  at          INTEGER NOT NULL,
  device_name TEXT NOT NULL,
  ip_prefix   TEXT NOT NULL,
  method      TEXT NOT NULL                             -- link | code
);
CREATE INDEX sign_ins_user ON sign_ins(user_id, at);

CREATE TABLE mail_days (
  day  INTEGER PRIMARY KEY,                             -- days since the epoch (UTC)
  sent INTEGER NOT NULL
);
