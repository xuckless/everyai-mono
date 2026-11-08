-- Vault sync, dev only (vault.zig; routes exist only with VAULT_SYNC_DEV=true).
-- Ciphertext and metadata only: the server can't read a blob.
CREATE TABLE vault_blobs (
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    version    INTEGER NOT NULL,
    data       BLOB NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (user_id, name)
);
