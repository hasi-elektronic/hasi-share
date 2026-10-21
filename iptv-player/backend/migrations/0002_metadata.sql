-- TMDB metadata cache (CONTRACT §11, BACKEND_API "Metadata"). Durable second tier behind KV:
-- KV answers hot keys with a TTL, these rows survive KV expiry and serve stale data while
-- TMDB is unreachable. Only public catalogue data is stored – nothing user- or source-specific.

-- Normalised details (MediaMetadata JSON) per title and UI language.
CREATE TABLE metadata_items (
  media_type TEXT NOT NULL CHECK (media_type IN ('movie', 'tv')),
  tmdb_id    INTEGER NOT NULL,
  language   TEXT NOT NULL,                 -- de | tr | en
  payload    TEXT NOT NULL,                 -- MediaMetadata JSON
  fetched_at INTEGER NOT NULL,              -- ms
  PRIMARY KEY (media_type, tmdb_id, language)
);
CREATE INDEX idx_metadata_items_fetched ON metadata_items(fetched_at);

-- Search and match answers, keyed by a hash of (endpoint, type, language, normalised query, year).
-- payload is JSON; a match with no hit is cached too (negative cache).
CREATE TABLE metadata_lookups (
  cache_key  TEXT PRIMARY KEY,
  payload    TEXT NOT NULL,
  fetched_at INTEGER NOT NULL               -- ms
);
CREATE INDEX idx_metadata_lookups_fetched ON metadata_lookups(fetched_at);
