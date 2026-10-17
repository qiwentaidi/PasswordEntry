CREATE TABLE IF NOT EXISTS shares (
    id TEXT PRIMARY KEY,
    schema_version INTEGER NOT NULL,
    algorithm TEXT NOT NULL,
    iv TEXT NOT NULL,
    ciphertext TEXT NOT NULL,
    revoke_token_hash TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    revoked_at TEXT,
    view_count INTEGER NOT NULL DEFAULT 0,
    max_views INTEGER,
    last_viewed_at TEXT
);

CREATE INDEX IF NOT EXISTS shares_expires_at_idx ON shares(expires_at);
