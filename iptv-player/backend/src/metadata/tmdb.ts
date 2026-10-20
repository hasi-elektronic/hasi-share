import type { Ctx } from "../http";
import type {
  CastMember,
  MediaMetadata,
  MediaType,
  MetadataLanguage,
  MetadataSearchResult,
} from "./types";

export const TMDB_API_BASE = "https://api.themoviedb.org/3";
export const TMDB_IMAGE_BASE = "https://image.tmdb.org/t/p";
const TIMEOUT_MS = 8_000;
const MAX_CAST = 10;

const TMDB_LANGUAGE: Record<MetadataLanguage, string> = { de: "de-DE", tr: "tr-TR", en: "en-US" };

export type TmdbResult<T> =
  | { ok: true; data: T }
  | { ok: false; kind: "not_found" | "unavailable"; status: number };

/** Minimal TMDB API v3 client. Accepts a v3 API key or a v4 read access token (JWT). */
export class TmdbClient {
  constructor(private readonly c: Ctx) {}

  get configured(): boolean {
    return (this.c.env.TMDB_API_KEY ?? "").trim() !== "";
  }

  private async get(path: string, params: Record<string, string>): Promise<TmdbResult<Record<string, unknown>>> {
    const key = (this.c.env.TMDB_API_KEY ?? "").trim();
    const url = new URL(`${TMDB_API_BASE}${path}`);
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
    const headers: Record<string, string> = { accept: "application/json" };
    // v4 read access tokens are JWTs ("eyJ…"); v3 keys go into the query string.
    if (key.startsWith("eyJ")) headers.authorization = `Bearer ${key}`;
    else url.searchParams.set("api_key", key);

    let res: Response;
    try {
      res = await this.c.deps.fetch(url.toString(), { headers, signal: AbortSignal.timeout(TIMEOUT_MS) });
    } catch (e) {
      this.c.log.warn("tmdb.network_error", { path, err: e instanceof Error ? e.message : String(e) });
      return { ok: false, kind: "unavailable", status: 0 };
    }
    if (res.status === 404) return { ok: false, kind: "not_found", status: 404 };
    if (!res.ok) {
      // 401 = wrong key (operator problem), 429/5xx = TMDB problem; both look the same to clients.
      const level = res.status === 401 ? "error" : "warn";
      this.c.log[level]("tmdb.request_failed", { path, status: res.status });
      return { ok: false, kind: "unavailable", status: res.status };
    }
    try {
      const body = (await res.json()) as unknown;
      if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("not an object");
      return { ok: true, data: body as Record<string, unknown> };
    } catch {
      this.c.log.warn("tmdb.malformed_response", { path });
      return { ok: false, kind: "unavailable", status: res.status };
    }
  }

  async search(
    type: MediaType,
    query: string,
    year: number | null,
    language: MetadataLanguage,
  ): Promise<TmdbResult<MetadataSearchResult[]>> {
    const params: Record<string, string> = {
      query,
      language: TMDB_LANGUAGE[language],
      include_adult: "false",
      page: "1",
    };
    if (year !== null) params[type === "movie" ? "year" : "first_air_date_year"] = String(year);
    const r = await this.get(`/search/${type}`, params);
    if (!r.ok) return r;
    const results = Array.isArray(r.data.results) ? r.data.results : [];
    const out: MetadataSearchResult[] = [];
    for (const item of results) {
      const mapped = mapSearchResult(type, item);
      if (mapped) out.push(mapped);
    }
    return { ok: true, data: out };
  }

  async details(type: MediaType, tmdbId: number, language: MetadataLanguage): Promise<TmdbResult<MediaMetadata>> {
    const r = await this.get(`/${type}/${tmdbId}`, {
      language: TMDB_LANGUAGE[language],
      append_to_response: "videos,credits",
      // Trailers in the UI language first, English and language-less ones as fallback.
      include_video_language: language === "en" ? "en,null" : `${language},en,null`,
    });
    if (!r.ok) return r;
    const meta = mapDetails(type, tmdbId, language, r.data);
    if (!meta) return { ok: false, kind: "unavailable", status: 200 };
    // TMDB returns "" when no translation exists – fall back to the English overview.
    if (meta.overview === null && language !== "en") {
      const en = await this.get(`/${type}/${tmdbId}`, { language: TMDB_LANGUAGE.en });
      if (en.ok) meta.overview = str(en.data.overview);
    }
    return { ok: true, data: meta };
  }
}

// ---------- mapping (lenient: TMDB fields may be missing or null) ----------

function str(v: unknown): string | null {
  return typeof v === "string" && v.trim() !== "" ? v.trim() : null;
}

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

export function imageUrl(path: unknown, size: "w185" | "w500" | "w1280"): string | null {
  const p = str(path);
  return p && p.startsWith("/") ? `${TMDB_IMAGE_BASE}/${size}${p}` : null;
}

function rating(v: unknown, votes: number): number | null {
  const n = num(v);
  return n === null || votes === 0 ? null : Math.round(n * 10) / 10;
}

function date(v: unknown): string | null {
  const s = str(v);
  return s && /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : null;
}

function mapSearchResult(type: MediaType, v: unknown): MetadataSearchResult | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  const id = num(o.id);
  const title = str(type === "movie" ? o.title : o.name);
  if (id === null || !Number.isInteger(id) || id <= 0 || !title) return null;
  const voteCount = Math.max(0, Math.trunc(num(o.vote_count) ?? 0));
  return {
    tmdbId: id,
    type,
    title,
    originalTitle: str(type === "movie" ? o.original_title : o.original_name),
    overview: str(o.overview),
    posterUrl: imageUrl(o.poster_path, "w500"),
    backdropUrl: imageUrl(o.backdrop_path, "w1280"),
    rating: rating(o.vote_average, voteCount),
    voteCount,
    releaseDate: date(type === "movie" ? o.release_date : o.first_air_date),
  };
}

function mapCast(credits: unknown): CastMember[] {
  const cast = credits && typeof credits === "object" ? (credits as Record<string, unknown>).cast : null;
  if (!Array.isArray(cast)) return [];
  return cast
    .filter((m): m is Record<string, unknown> => !!m && typeof m === "object" && str((m as Record<string, unknown>).name) !== null)
    .sort((a, b) => (num(a.order) ?? 999) - (num(b.order) ?? 999))
    .slice(0, MAX_CAST)
    .map((m) => ({ name: str(m.name)!, character: str(m.character), profileUrl: imageUrl(m.profile_path, "w185") }));
}

/** YouTube trailer: UI language before others, official before fan uploads, "Trailer" before "Teaser". */
export function pickTrailer(videos: unknown, language: MetadataLanguage): string | null {
  const list = videos && typeof videos === "object" ? (videos as Record<string, unknown>).results : null;
  if (!Array.isArray(list)) return null;
  let best: { key: string; rank: number } | null = null;
  for (const v of list) {
    if (!v || typeof v !== "object") continue;
    const o = v as Record<string, unknown>;
    const key = str(o.key);
    if (o.site !== "YouTube" || !key || !/^[A-Za-z0-9_-]{6,20}$/.test(key)) continue;
    if (o.type !== "Trailer" && o.type !== "Teaser") continue;
    const rank =
      (o.iso_639_1 === language ? 0 : o.iso_639_1 === "en" ? 4 : 8) +
      (o.official === true ? 0 : 2) +
      (o.type === "Trailer" ? 0 : 1);
    if (!best || rank < best.rank) best = { key, rank };
  }
  return best ? `https://www.youtube.com/watch?v=${best.key}` : null;
}

export function mapDetails(
  type: MediaType,
  tmdbId: number,
  language: MetadataLanguage,
  o: Record<string, unknown>,
): MediaMetadata | null {
  const title = str(type === "movie" ? o.title : o.name);
  if (!title) return null;
  const voteCount = Math.max(0, Math.trunc(num(o.vote_count) ?? 0));
  const genres = Array.isArray(o.genres)
    ? o.genres.map((g) => (g && typeof g === "object" ? str((g as Record<string, unknown>).name) : null)).filter((g): g is string => g !== null)
    : [];
  let runtime: number | null;
  if (type === "movie") {
    runtime = num(o.runtime);
  } else {
    const ert = Array.isArray(o.episode_run_time) ? o.episode_run_time.map(num).filter((n): n is number => n !== null) : [];
    runtime = ert[0] ?? null;
  }
  return {
    tmdbId,
    type,
    title,
    originalTitle: str(type === "movie" ? o.original_title : o.original_name),
    overview: str(o.overview),
    posterUrl: imageUrl(o.poster_path, "w500"),
    backdropUrl: imageUrl(o.backdrop_path, "w1280"),
    rating: rating(o.vote_average, voteCount),
    voteCount,
    releaseDate: date(type === "movie" ? o.release_date : o.first_air_date),
    genres,
    cast: mapCast(o.credits),
    trailerUrl: pickTrailer(o.videos, language),
    runtimeMinutes: runtime !== null && runtime > 0 ? Math.round(runtime) : null,
    seasons: type === "tv" ? num(o.number_of_seasons) : null,
    language,
  };
}
