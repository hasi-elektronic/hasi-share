import { sha256Hex } from "../crypto";
import { badRequest, json, type Ctx } from "../http";
import { rateLimit } from "../ratelimit";
import { DETAILS_POLICY, LOOKUP_POLICY, cached, type CacheSource, type D1Slot } from "./cache";
import { MATCH_THRESHOLD, compareKey, parseVodName, pickBest } from "./match";
import { TmdbClient } from "./tmdb";
import type {
  MediaMetadata,
  MediaType,
  MetadataLanguage,
  MetadataMatch,
  MetadataSearchResult,
  ParsedVodName,
} from "./types";

/** Per client IP; a category screen matches its visible titles one by one. */
const RATE_LIMIT = 120;
const RATE_WINDOW_SEC = 60;

function queryParam(c: Ctx, key: string, max: number): string | undefined {
  const v = c.url.searchParams.get(key);
  if (v === null) return undefined;
  const s = v.trim();
  if (s.length > max) throw badRequest(`'${key}' is too long.`);
  return s === "" ? undefined : s;
}

function mediaType(c: Ctx): MediaType {
  const t = queryParam(c, "type", 10);
  if (t !== "movie" && t !== "tv") throw badRequest("'type' must be 'movie' or 'tv'.");
  return t;
}

/** `de` | `tr` | `en` (also accepts `de-DE` style); default `en`. */
function language(c: Ctx): MetadataLanguage {
  const l = queryParam(c, "language", 10)?.slice(0, 2).toLowerCase() ?? "en";
  if (l !== "de" && l !== "tr" && l !== "en") throw badRequest("'language' must be 'de', 'tr' or 'en'.");
  return l;
}

function year(c: Ctx): number | null {
  const y = queryParam(c, "year", 4);
  if (y === undefined) return null;
  const n = Number(y);
  if (!/^\d{4}$/.test(y) || n < 1874 || n > 2100) throw badRequest("'year' must be a four-digit year.");
  return n;
}

function respond(data: unknown, source: CacheSource): Response {
  // Clients may cache too; stale answers only briefly so they pick up the refresh.
  return json(data, 200, {
    "cache-control": source === "stale" ? "public, max-age=300" : "public, max-age=3600",
    "x-metadata-cache": source,
  });
}

function lookupSlot(c: Ctx, key: string): D1Slot {
  return {
    read: () =>
      c.env.DB.prepare("SELECT payload, fetched_at AS fetchedAt FROM metadata_lookups WHERE cache_key = ?1")
        .bind(key)
        .first<{ payload: string; fetchedAt: number }>(),
    write: (payload, fetchedAt) =>
      c.env.DB.prepare(
        "INSERT INTO metadata_lookups (cache_key, payload, fetched_at) VALUES (?1, ?2, ?3) " +
          "ON CONFLICT(cache_key) DO UPDATE SET payload = excluded.payload, fetched_at = excluded.fetched_at",
      ).bind(key, payload, fetchedAt),
  };
}

async function lookupKey(kind: "search" | "match", type: MediaType, lang: MetadataLanguage, query: string, y: number | null) {
  return (await sha256Hex(`${kind}|${type}|${lang}|${compareKey(query)}|${y ?? ""}`)).slice(0, 40);
}

/** GET /v1/metadata/search?query=&type=movie|tv[&year=][&language=de|tr|en] */
export async function metadataSearch(c: Ctx): Promise<Response> {
  const query = queryParam(c, "query", 200);
  if (!query) throw badRequest("'query' is required.");
  const type = mediaType(c);
  const lang = language(c);
  const y = year(c);
  await rateLimit(c, "metadata", c.ip, RATE_LIMIT, RATE_WINDOW_SEC);

  const key = await lookupKey("search", type, lang, query, y);
  const tmdb = new TmdbClient(c);
  const { data, source } = await cached<MetadataSearchResult[]>(c, `md:s:${key}`, lookupSlot(c, key), LOOKUP_POLICY, async () =>
    tmdb.configured ? tmdb.search(type, query, y, lang) : null,
  );
  return respond({ results: data }, source);
}

/** GET /v1/metadata/match?name=<raw VOD name>&type=movie|tv[&year=][&language=] (CONTRACT §11.2) */
export async function metadataMatch(c: Ctx): Promise<Response> {
  const name = queryParam(c, "name", 300);
  if (!name) throw badRequest("'name' is required.");
  const type = mediaType(c);
  const lang = language(c);
  const parsed = parseVodName(name);
  // The provider's own year (Xtream `year`, M3U tag) beats a guess from the name.
  const y = year(c);
  if (y !== null) parsed.year = y;
  await rateLimit(c, "metadata", c.ip, RATE_LIMIT, RATE_WINDOW_SEC);

  const key = await lookupKey("match", type, lang, parsed.title, parsed.year);
  const tmdb = new TmdbClient(c);
  const { data, source } = await cached<Omit<MetadataMatch, "parsed">>(
    c,
    `md:m:${key}`,
    lookupSlot(c, key),
    LOOKUP_POLICY,
    async () => (tmdb.configured ? runMatch(tmdb, type, lang, parsed) : null),
  );
  const out: MetadataMatch = { parsed, ...data };
  return respond(out, source);
}

/**
 * Up to three searches, stopping at the first match ≥ threshold:
 *   1. title + year filter   2. title without year (provider year off / wrong)
 *   3. "title year" without filter when the year was a bare number ("Blade Runner 2049").
 */
async function runMatch(
  tmdb: TmdbClient,
  type: MediaType,
  lang: MetadataLanguage,
  parsed: ParsedVodName,
) {
  const attempts: { query: string; year: number | null; as: ParsedVodName }[] = [
    { query: parsed.title, year: parsed.year, as: parsed },
  ];
  if (parsed.year !== null) {
    attempts.push({ query: parsed.title, year: null, as: parsed });
    if (!parsed.yearInBrackets) {
      const title = `${parsed.title} ${parsed.year}`;
      attempts.push({ query: title, year: null, as: { ...parsed, title, year: null } });
    }
  }
  let best: { result: MetadataSearchResult; score: number } | null = null;
  for (const a of attempts) {
    const r = await tmdb.search(type, a.query, a.year, lang);
    if (!r.ok) return r;
    const b = pickBest(a.as, r.data);
    if (b && (!best || b.score > best.score)) best = b;
    if (best && best.score >= MATCH_THRESHOLD) break;
  }
  const data = {
    match: best && best.score >= MATCH_THRESHOLD ? best.result : null,
    confidence: best?.score ?? 0,
  };
  return { ok: true as const, data };
}

/** GET /v1/metadata/:tmdbId?type=movie|tv[&language=] */
export async function metadataDetails(c: Ctx): Promise<Response> {
  const raw = c.params.tmdbId ?? "";
  const tmdbId = Number(raw);
  if (!/^\d{1,10}$/.test(raw) || tmdbId < 1 || tmdbId > 2_147_483_647) {
    throw badRequest("'tmdbId' must be a positive integer.");
  }
  const type = mediaType(c);
  const lang = language(c);
  await rateLimit(c, "metadata", c.ip, RATE_LIMIT, RATE_WINDOW_SEC);

  const slot: D1Slot = {
    read: () =>
      c.env.DB.prepare(
        "SELECT payload, fetched_at AS fetchedAt FROM metadata_items WHERE media_type = ?1 AND tmdb_id = ?2 AND language = ?3",
      )
        .bind(type, tmdbId, lang)
        .first<{ payload: string; fetchedAt: number }>(),
    write: (payload, fetchedAt) =>
      c.env.DB.prepare(
        "INSERT INTO metadata_items (media_type, tmdb_id, language, payload, fetched_at) VALUES (?1, ?2, ?3, ?4, ?5) " +
          "ON CONFLICT(media_type, tmdb_id, language) DO UPDATE SET payload = excluded.payload, fetched_at = excluded.fetched_at",
      ).bind(type, tmdbId, lang, payload, fetchedAt),
  };
  const tmdb = new TmdbClient(c);
  const { data, source } = await cached<MediaMetadata>(c, `md:i:${type}:${tmdbId}:${lang}`, slot, DETAILS_POLICY, async () =>
    tmdb.configured ? tmdb.details(type, tmdbId, lang) : null,
  );
  return respond(data, source);
}
