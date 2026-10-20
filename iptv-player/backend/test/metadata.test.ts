import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import vectors from "../../spec/test-vectors/metadata/vod-names.json";
import { compareKey, parseVodName, scoreCandidate } from "../src/metadata/match";
import { DAY, Harness, resetDb } from "./helpers";

const TMDB_KEY = "tmdb-v3-key-0123456789abcdef";

interface TmdbCall {
  path: string;
  params: URLSearchParams;
  headers: Headers;
}

/** Fake TMDB: `routes` maps an API path ("/search/movie") to a JSON body or a status code. */
class FakeTmdb {
  calls: TmdbCall[] = [];
  routes = new Map<string, unknown | ((p: URLSearchParams) => unknown)>();
  down = false;

  handle = (url: URL, headers: Headers): Response => {
    const path = url.pathname.replace(/^\/3/, "");
    this.calls.push({ path, params: url.searchParams, headers });
    if (this.down) return new Response("down", { status: 503 });
    if (url.searchParams.get("api_key") !== TMDB_KEY && headers.get("authorization") !== `Bearer ${TMDB_KEY}`) {
      return Response.json({ status_code: 7, status_message: "Invalid API key" }, { status: 401 });
    }
    const r = this.routes.get(path);
    if (r === undefined) return Response.json({ status_code: 34 }, { status: 404 });
    const body = typeof r === "function" ? (r as (p: URLSearchParams) => unknown)(url.searchParams) : r;
    if (typeof body === "number") return new Response("err", { status: body });
    return Response.json(body);
  };

  count(path: string): number {
    return this.calls.filter((c) => c.path === path).length;
  }
}

const movie = (id: number, title: string, release: string, extra: Record<string, unknown> = {}) => ({
  id,
  title,
  original_title: title,
  overview: `${title} overview`,
  poster_path: `/p${id}.jpg`,
  backdrop_path: `/b${id}.jpg`,
  vote_average: 7.84,
  vote_count: 1200,
  release_date: release,
  ...extra,
});

const inceptionDetails = {
  id: 27205,
  title: "Inception",
  original_title: "Inception",
  overview: "",
  poster_path: "/inc.jpg",
  backdrop_path: null,
  vote_average: 8.369,
  vote_count: 36000,
  release_date: "2010-07-15",
  runtime: 148,
  genres: [{ id: 28, name: "Action" }, { id: 878, name: "Science Fiction" }],
  credits: {
    cast: Array.from({ length: 12 }, (_, i) => ({
      name: `Actor ${i}`,
      character: i === 0 ? "Cobb" : "",
      profile_path: i === 0 ? "/a0.jpg" : null,
      order: 11 - i,
    })),
  },
  videos: {
    results: [
      { site: "YouTube", key: "fanTeaser01", type: "Teaser", official: false, iso_639_1: "de" },
      { site: "Vimeo", key: "vimeo12345", type: "Trailer", official: true, iso_639_1: "de" },
      { site: "YouTube", key: "enTrailer01", type: "Trailer", official: true, iso_639_1: "en" },
      { site: "YouTube", key: "deTrailer01", type: "Trailer", official: true, iso_639_1: "de" },
    ],
  },
};

describe("VOD name parsing (spec/test-vectors/metadata/vod-names.json)", () => {
  for (const v of vectors.parse) {
    it(`parse ${JSON.stringify(v.input)}`, () => {
      const { input, ...expected } = v;
      expect(parseVodName(input)).toEqual(expected);
    });
  }
  for (const v of vectors.compareKey) {
    it(`compareKey ${JSON.stringify(v.input)}`, () => {
      expect(compareKey(v.input)).toBe(v.expected);
    });
  }

  it("scores year mismatches below the threshold even for identical titles", () => {
    const parsed = parseVodName("The Lion King (2019)");
    const c = (release: string) => ({
      tmdbId: 1, type: "movie" as const, title: "The Lion King", originalTitle: null, overview: null,
      posterUrl: null, backdropUrl: null, rating: null, voteCount: 0, releaseDate: release,
    });
    expect(scoreCandidate(parsed, c("2019-07-12"))).toBe(1);
    expect(scoreCandidate(parsed, c("1994-06-23"))).toBeLessThan(0.75);
    expect(scoreCandidate(parsed, c("2019-07-12"))).toBeGreaterThan(scoreCandidate(parsed, c("1994-06-23")));
  });
});

describe("metadata endpoints", () => {
  let h: Harness;
  let tmdb: FakeTmdb;
  beforeEach(async () => {
    await resetDb();
    // KV off by default: KV storage is not reset between tests; the KV test opts in.
    h = await Harness.create({ TMDB_API_KEY: TMDB_KEY, METADATA_KV: undefined });
    tmdb = new FakeTmdb();
    h.stores.tmdb = tmdb.handle;
  });

  it("503 metadata_unavailable without TMDB_API_KEY", async () => {
    h.env.TMDB_API_KEY = undefined;
    const r = await h.get("/v1/metadata/search?query=Inception&type=movie");
    expect(r.status).toBe(503);
    expect(r.json.error).toBe("metadata_unavailable");
    expect(tmdb.calls).toHaveLength(0);
  });

  it("validates parameters", async () => {
    expect((await h.get("/v1/metadata/search?type=movie")).status).toBe(400);
    expect((await h.get("/v1/metadata/search?query=x&type=series")).status).toBe(400);
    expect((await h.get("/v1/metadata/search?query=x&type=movie&language=fr")).status).toBe(400);
    expect((await h.get("/v1/metadata/search?query=x&type=movie&year=99")).status).toBe(400);
    expect((await h.get("/v1/metadata/abc?type=movie")).status).toBe(400);
    expect((await h.get("/v1/metadata/match?type=movie")).status).toBe(400);
    expect(tmdb.calls).toHaveLength(0);
  });

  it("search maps results, sends key and language, caches in D1", async () => {
    tmdb.routes.set("/search/movie", { results: [movie(27205, "Inception", "2010-07-15"), { id: "bad" }] });
    const r = await h.get("/v1/metadata/search?query=Inception&type=movie&language=de-DE&year=2010");
    expect(r.status).toBe(200);
    expect(r.headers.get("x-metadata-cache")).toBe("tmdb");
    expect(r.headers.get("cache-control")).toBe("public, max-age=3600");
    expect(r.json.results).toEqual([
      {
        tmdbId: 27205, type: "movie", title: "Inception", originalTitle: "Inception", overview: "Inception overview",
        posterUrl: "https://image.tmdb.org/t/p/w500/p27205.jpg", backdropUrl: "https://image.tmdb.org/t/p/w1280/b27205.jpg",
        rating: 7.8, voteCount: 1200, releaseDate: "2010-07-15",
      },
    ]);
    const call = tmdb.calls[0]!;
    expect(call.params.get("language")).toBe("de-DE");
    expect(call.params.get("year")).toBe("2010");
    expect(call.params.get("include_adult")).toBe("false");

    // Same normalised query → D1 hit, no second TMDB call.
    const again = await h.get("/v1/metadata/search?query=inception&type=movie&language=de&year=2010");
    expect(again.json.results).toEqual(r.json.results);
    expect(again.headers.get("x-metadata-cache")).toBe("d1");
    expect(tmdb.count("/search/movie")).toBe(1);
    h.assertLogsExclude([TMDB_KEY]);
  });

  it("uses a Bearer header for v4 read access tokens", async () => {
    const v4 = "eyJhbGciOiJIUzI1NiJ9.fake.v4token";
    h.env.TMDB_API_KEY = v4;
    tmdb.routes.set("/search/tv", { results: [] });
    await h.get("/v1/metadata/search?query=Dark&type=tv");
    expect(tmdb.calls[0]!.headers.get("authorization")).toBe(`Bearer ${v4}`);
    expect(tmdb.calls[0]!.params.has("api_key")).toBe(false);
  });

  it("details: cast order/limit, trailer choice, English overview fallback", async () => {
    tmdb.routes.set("/movie/27205", (p: URLSearchParams) =>
      p.get("language") === "en-US" ? { ...inceptionDetails, overview: "A thief who steals secrets." } : inceptionDetails,
    );
    const r = await h.get("/v1/metadata/27205?type=movie&language=de");
    expect(r.status).toBe(200);
    expect(r.json).toMatchObject({
      tmdbId: 27205,
      type: "movie",
      title: "Inception",
      overview: "A thief who steals secrets.",
      posterUrl: "https://image.tmdb.org/t/p/w500/inc.jpg",
      backdropUrl: null,
      rating: 8.4,
      releaseDate: "2010-07-15",
      genres: ["Action", "Science Fiction"],
      trailerUrl: "https://www.youtube.com/watch?v=deTrailer01",
      runtimeMinutes: 148,
      seasons: null,
      language: "de",
    });
    expect(r.json.cast).toHaveLength(10);
    expect(r.json.cast[0]).toEqual({ name: "Actor 11", character: null, profileUrl: null });
    expect(r.json.cast[9]).toEqual({ name: "Actor 2", character: null, profileUrl: null });
    const first = tmdb.calls[0]!;
    expect(first.params.get("append_to_response")).toBe("videos,credits");
    expect(first.params.get("include_video_language")).toBe("de,en,null");

    await h.get("/v1/metadata/27205?type=movie&language=de");
    expect(tmdb.count("/movie/27205")).toBe(2); // details + overview fallback, then cached
  });

  it("tv details map name, first air date, seasons and episode runtime", async () => {
    tmdb.routes.set("/tv/70523", {
      id: 70523, name: "Dark", original_name: "Dark", overview: "Ein Kind verschwindet.", first_air_date: "2017-12-01",
      vote_average: 8.4, vote_count: 6000, number_of_seasons: 3, episode_run_time: [60], genres: [], videos: { results: [] },
    });
    const r = await h.get("/v1/metadata/70523?type=tv&language=de");
    expect(r.json).toMatchObject({ title: "Dark", releaseDate: "2017-12-01", seasons: 3, runtimeMinutes: 60, trailerUrl: null, cast: [] });
  });

  it("404 for unknown ids, 503 when TMDB is down and nothing is cached", async () => {
    expect((await h.get("/v1/metadata/999?type=movie")).status).toBe(404);
    tmdb.down = true;
    const r = await h.get("/v1/metadata/998?type=movie");
    expect(r.status).toBe(503);
    expect(r.headers.get("retry-after")).toBe("60");
  });

  it("serves stale D1 rows while TMDB is down, refreshes when it is back", async () => {
    tmdb.routes.set("/movie/27205", { ...inceptionDetails, overview: "v1" });
    await h.get("/v1/metadata/27205?type=movie");
    h.advance(15 * DAY); // past the 14-day fresh window
    tmdb.down = true;
    const stale = await h.get("/v1/metadata/27205?type=movie");
    expect(stale.status).toBe(200);
    expect(stale.headers.get("x-metadata-cache")).toBe("stale");
    expect(stale.json.overview).toBe("v1");
    tmdb.down = false;
    tmdb.routes.set("/movie/27205", { ...inceptionDetails, overview: "v2" });
    const fresh = await h.get("/v1/metadata/27205?type=movie");
    expect(fresh.headers.get("x-metadata-cache")).toBe("tmdb");
    expect(fresh.json.overview).toBe("v2");
  });

  it("match: parses the IPTV name and picks the best candidate", async () => {
    tmdb.routes.set("/search/movie", (p: URLSearchParams) => {
      expect(p.get("query")).toBe("The Matrix");
      expect(p.get("year")).toBe("1999");
      return {
        results: [
          movie(604, "The Matrix Reloaded", "2003-05-15"),
          movie(603, "The Matrix", "1999-03-30"),
        ],
      };
    });
    const r = await h.get(`/v1/metadata/match?type=movie&name=${encodeURIComponent("DE | The Matrix (1999) [4K]")}`);
    expect(r.status).toBe(200);
    expect(r.json.parsed).toEqual({ title: "The Matrix", year: 1999, yearInBrackets: true, season: null, episode: null });
    expect(r.json.match.tmdbId).toBe(603);
    expect(r.json.confidence).toBe(1);
  });

  it("match: retries without the year filter and with a bare year as part of the title", async () => {
    tmdb.routes.set("/search/movie", (p: URLSearchParams) =>
      p.get("query") === "Blade Runner 2049" && !p.has("year")
        ? { results: [movie(335984, "Blade Runner 2049", "2017-10-04")] }
        : { results: p.has("year") ? [] : [movie(78, "Blade Runner", "1982-06-25")] },
    );
    const r = await h.get("/v1/metadata/match?type=movie&name=Blade%20Runner%202049");
    expect(r.json.match.tmdbId).toBe(335984);
    expect(tmdb.count("/search/movie")).toBe(3);
  });

  it("match: no hit is cached as well (negative cache)", async () => {
    tmdb.routes.set("/search/movie", { results: [movie(1, "Something Else Entirely", "2001-01-01")] });
    const r = await h.get("/v1/metadata/match?type=movie&name=Qwertz%20Film");
    expect(r.json.match).toBeNull();
    expect(r.json.confidence).toBeLessThan(0.75);
    await h.get("/v1/metadata/match?type=movie&name=QWERTZ%20FILM%20HD");
    expect(tmdb.count("/search/movie")).toBe(1);
  });

  it("match: an explicit year parameter overrides the name", async () => {
    tmdb.routes.set("/search/tv", (p: URLSearchParams) => {
      expect(p.get("first_air_date_year")).toBe("2017");
      return { results: [{ id: 70523, name: "Dark", original_name: "Dark", first_air_date: "2017-12-01", vote_count: 6000 }] };
    });
    const r = await h.get("/v1/metadata/match?type=tv&name=EN%20-%20Dark%20S01E01&year=2017");
    expect(r.json.parsed).toMatchObject({ title: "Dark", year: 2017, season: 1, episode: 1 });
    expect(r.json.match.tmdbId).toBe(70523);
  });

  it("KV tier answers before D1 when the binding exists", async () => {
    h.env.METADATA_KV = env.METADATA_KV;
    const q = `kvtest${Date.now()}`;
    tmdb.routes.set("/search/movie", { results: [] });
    expect((await h.get(`/v1/metadata/search?query=${q}&type=movie`)).headers.get("x-metadata-cache")).toBe("tmdb");
    await resetDb(); // D1 gone → only KV can answer
    const r = await h.get(`/v1/metadata/search?query=${q}&type=movie`);
    expect(r.headers.get("x-metadata-cache")).toBe("kv");
    expect(tmdb.count("/search/movie")).toBe(1);
  });

  it("cron removes cache rows older than 90 days", async () => {
    tmdb.routes.set("/movie/27205", inceptionDetails);
    await h.get("/v1/metadata/27205?type=movie");
    h.advance(91 * DAY);
    await h.runCron();
    const { results } = await env.DB.prepare("SELECT tmdb_id FROM metadata_items").all();
    expect(results).toHaveLength(0);
  });
});
