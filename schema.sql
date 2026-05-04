-- Hasi Share D1 Schema
CREATE TABLE IF NOT EXISTS shares (
  id TEXT PRIMARY KEY,
  file_key TEXT NOT NULL,
  filename TEXT NOT NULL,
  size INTEGER DEFAULT 0,
  pw_hash TEXT NOT NULL,
  salt TEXT NOT NULL,
  expires_at TEXT,
  note TEXT DEFAULT '',
  downloads INTEGER DEFAULT 0,
  dl_token TEXT,
  dl_token_exp TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_shares_created ON shares(created_at DESC);
