-- Initial schema for the IPTV player backend (Cloudflare D1 / SQLite).
-- Conventions: *_at columns are epoch milliseconds, trial_* columns are epoch SECONDS
-- (they are copied 1:1 into license token claims). No foreign keys: cleanup is explicit
-- in code so behaviour is identical locally and on D1.

-- Runtime configuration editable through the admin API (defaults come from [vars]).
CREATE TABLE config (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE accounts (
  id         TEXT PRIMARY KEY,              -- 'acc_…'
  email      TEXT NOT NULL UNIQUE,          -- lowercased
  created_at INTEGER NOT NULL,
  sync_seq   INTEGER NOT NULL DEFAULT 0     -- last sync sequence number handed out
);

CREATE TABLE devices (
  device_key   TEXT PRIMARY KEY,            -- 64 hex (CONTRACT §7.1)
  platform     TEXT NOT NULL,               -- android | androidtv | ios | tvos
  app_id       TEXT NOT NULL,
  app_version  TEXT,
  account_id   TEXT,                        -- account of the last signed-in sync
  trial_start  INTEGER,                     -- seconds
  trial_end    INTEGER,                     -- seconds (snapshot: start + trial_days)
  trial_source TEXT,                        -- 'server' | 'apple'
  created_at   INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
);
CREATE INDEX idx_devices_account ON devices(account_id);

-- Earliest trial seen across all devices of an account ("earliest trial wins").
CREATE TABLE account_trials (
  account_id  TEXT PRIMARY KEY,
  trial_start INTEGER NOT NULL,
  trial_end   INTEGER NOT NULL,
  source      TEXT NOT NULL,
  updated_at  INTEGER NOT NULL
);

-- Apple trial marker purchases (price tier 0 non-consumable), keyed by Apple's
-- originalTransactionId so every device of one Apple ID gets the same snapshot.
CREATE TABLE apple_trials (
  original_transaction_id TEXT PRIMARY KEY,
  trial_start             INTEGER NOT NULL, -- seconds (= purchaseDate)
  trial_end               INTEGER NOT NULL, -- seconds
  revoked                 INTEGER NOT NULL DEFAULT 0,
  created_at              INTEGER NOT NULL
);

-- Pending e-mail login codes; e-mail only stored as SHA-256.
CREATE TABLE email_codes (
  email_hash TEXT PRIMARY KEY,
  code_hash  TEXT NOT NULL,
  attempts   INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX idx_email_codes_expires ON email_codes(expires_at);

CREATE TABLE sessions (
  token_hash   TEXT PRIMARY KEY,            -- SHA-256 of the bearer token
  account_id   TEXT NOT NULL,
  device_name  TEXT,
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL,            -- sliding, 180 days
  last_used_at INTEGER NOT NULL
);
CREATE INDEX idx_sessions_account ON sessions(account_id);
CREATE INDEX idx_sessions_expires ON sessions(expires_at);

CREATE TABLE licenses (
  id            TEXT PRIMARY KEY,           -- 'lic_…'
  store         TEXT NOT NULL CHECK (store IN ('google', 'apple', 'admin')),
  store_ref     TEXT NOT NULL,              -- google purchaseToken | apple originalTransactionId | admin id
  order_id      TEXT,                       -- google orderId | apple transactionId
  product_id    TEXT NOT NULL,
  status        TEXT NOT NULL CHECK (status IN ('active', 'revoked')),
  purchased_at  INTEGER,
  revoked_at    INTEGER,
  revoke_reason TEXT,                       -- 'store' | 'admin'
  device_key    TEXT,                       -- first device that presented the purchase
  account_id    TEXT,                       -- account it is linked to (cross-platform)
  note          TEXT,                       -- admin note (grants)
  raw_state     TEXT,                       -- last store state as JSON, no personal data
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  UNIQUE (store, store_ref)
);
CREATE INDEX idx_licenses_account ON licenses(account_id);
CREATE INDEX idx_licenses_device ON licenses(device_key);
CREATE INDEX idx_licenses_order ON licenses(order_id);

-- Every device that presented (or was granted) a license.
CREATE TABLE license_devices (
  license_id TEXT NOT NULL,
  device_key TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (license_id, device_key)
);
CREATE INDEX idx_license_devices_device ON license_devices(device_key);

-- TV device-code login (RFC 8628 style).
CREATE TABLE device_codes (
  device_code_hash TEXT PRIMARY KEY,
  user_code        TEXT NOT NULL UNIQUE,    -- 8 chars, no dash
  platform         TEXT NOT NULL,
  device_name      TEXT,
  account_id       TEXT,                    -- set on approval
  created_at       INTEGER NOT NULL,
  expires_at       INTEGER NOT NULL,
  last_poll_at     INTEGER
);
CREATE INDEX idx_device_codes_expires ON device_codes(expires_at);

-- Favorites & progress (CONTRACT §8).
CREATE TABLE sync_items (
  account_id TEXT NOT NULL,
  key        TEXT NOT NULL,
  kind       TEXT NOT NULL,                 -- favorite | progress
  data       TEXT NOT NULL,                 -- JSON
  updated_at INTEGER NOT NULL,              -- client epoch ms (LWW)
  deleted    INTEGER NOT NULL DEFAULT 0,
  seq        INTEGER NOT NULL,              -- per-account monotonic cursor
  PRIMARY KEY (account_id, key)
);
CREATE INDEX idx_sync_items_seq ON sync_items(account_id, seq);
CREATE INDEX idx_sync_items_kind ON sync_items(account_id, kind, deleted, updated_at);

-- TV pairing sessions (CONTRACT §9). The payload is opaque ciphertext.
CREATE TABLE pair_sessions (
  code        TEXT PRIMARY KEY,             -- 6 chars, no dash
  secret_hash TEXT NOT NULL,
  public_key  TEXT NOT NULL,                -- TV public JWK (JSON)
  payload     TEXT,                         -- {epk, iv, ct} JSON, deleted after delivery
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL
);
CREATE INDEX idx_pair_sessions_expires ON pair_sessions(expires_at);

-- Fixed-window rate limiter; bucket keys contain only hashes.
CREATE TABLE rate_limits (
  bucket       TEXT PRIMARY KEY,
  count        INTEGER NOT NULL,
  window_start INTEGER NOT NULL
);
CREATE INDEX idx_rate_limits_window ON rate_limits(window_start);
