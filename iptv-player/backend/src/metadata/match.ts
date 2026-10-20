import type { MetadataSearchResult, ParsedVodName } from "./types";

/**
 * VOD name → TMDB matching (CONTRACT §11.2, vectors `metadata/vod-names.json`).
 * Pure functions: the apps may run the same parser locally, the backend runs it for
 * `GET /v1/metadata/match`.
 */

/** Minimum score for a candidate to count as a match. */
export const MATCH_THRESHOLD = 0.75;

// Provider prefixes such as "DE | ", "|TR| ", "[EN] ", "4K-DE - ", "DE: ". Case-sensitive on
// purpose: real titles like "It: Chapter Two" must survive, providers write tags in caps.
const PREFIX_TAGS = [
  "DE", "GER", "DEU", "TR", "TUR", "EN", "ENG", "US", "UK", "GB", "FR", "ES", "IT", "NL", "PL",
  "RU", "AR", "AT", "CH", "AL", "KU", "MULTI", "VOD", "4K", "UHD", "FHD", "HD", "SD", "HEVC", "3D",
];
const TAG = `(?:${PREFIX_TAGS.join("|")})`;
const PREFIX_RE = new RegExp(`^\\s*[\\[(|]?\\s*${TAG}(?:\\s*[-_/+]\\s*${TAG})*\\s*(?:[\\])|:]|\\s-\\s)\\s*`);

// Season / episode markers; everything from the earliest marker on is dropped.
const EPISODE_RES: { re: RegExp; season: number; episode: number | null }[] = [
  { re: /\bS(\d{1,2})\s*E(\d{1,3})\b/i, season: 1, episode: 2 },
  { re: /\b(\d{1,2})x(\d{2,3})\b/, season: 1, episode: 2 },
  { re: /\b(?:Staffel|Season|Sezon)\s*(\d{1,2})\b/i, season: 1, episode: null },
  { re: /\bS(\d{1,2})(?=\s*$|\s*[-([|])/i, season: 1, episode: null },
];

const YEAR_BRACKET_RE = /[([]\s*((?:19|20)\d{2})\s*[)\]]/;
const YEAR_BARE_RE = /\b((?:19|20)\d{2})\b/g;
const BRACKET_GROUP_RE = /\[[^\]]*\]|\([^)]*\)|\{[^}]*\}/g;

/** Release / language tags dropped from the END of a name (lowercase, punctuation removed). */
const TAIL_JUNK = new Set([
  "2160p", "1080p", "720p", "576p", "480p", "4k", "uhd", "fhd", "hd", "sd", "hdr", "hdr10", "dv",
  "hevc", "h264", "h265", "x264", "x265", "avc", "web", "webdl", "webrip", "hdtv", "bluray", "brrip",
  "bdrip", "dvdrip", "remux", "multi", "dual", "dl", "ac3", "eac3", "dts", "aac", "51", "german",
  "deutsch", "ger", "eng", "english", "turkce", "dub", "dubbed", "sub", "subbed", "ov", "omu",
  "extended", "uncut", "remastered", "imax", "3d", "de", "en", "tr",
]);

function collapse(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

function trimSeparators(s: string): string {
  return s.replace(/^[\s\-:|,.]+/, "").replace(/[\s\-:|,.]+$/, "");
}

/** Drops trailing release/language tags ("… 1080p BluRay x264" → "…"). */
function stripTailJunk(s: string): string {
  const tokens = collapse(s).split(" ");
  while (tokens.length > 1) {
    const t = tokens[tokens.length - 1]!.toLowerCase().replace(/[^a-z0-9]/g, "");
    if (t !== "" && !TAIL_JUNK.has(t)) break;
    tokens.pop();
  }
  return tokens.join(" ");
}

/** True when `rest` (the text after a bare year) is only tags, brackets and separators. */
function onlyJunk(rest: string): boolean {
  const r = collapse(rest.replace(BRACKET_GROUP_RE, " ").replace(/[-:|,.]/g, " "));
  return r === "" || r.split(" ").every((t) => TAIL_JUNK.has(t.toLowerCase().replace(/[^a-z0-9]/g, "")));
}

/** CONTRACT §11.2 – raw M3U / Xtream VOD name → search title, year, season/episode. */
export function parseVodName(raw: string): ParsedVodName {
  let s = collapse(raw);
  // Release-style names without spaces: "Inception.2010.1080p.BluRay".
  if (!s.includes(" ") && /[._]/.test(s)) s = collapse(s.replace(/[._]+/g, " "));

  for (let i = 0; i < 4; i++) {
    const next = s.replace(PREFIX_RE, "");
    if (next === s || next.trim() === "") break;
    s = next;
  }

  let season: number | null = null;
  let episode: number | null = null;
  let cut = s.length;
  for (const { re, season: si, episode: ei } of EPISODE_RES) {
    const m = re.exec(s);
    if (m && m.index > 0 && m.index < cut) {
      cut = m.index;
      season = Number(m[si]);
      episode = ei === null ? null : Number(m[ei]);
    }
  }
  s = s.slice(0, cut);

  let year: number | null = null;
  let yearInBrackets = false;
  const yb = YEAR_BRACKET_RE.exec(s);
  if (yb && trimSeparators(s.slice(0, yb.index).replace(BRACKET_GROUP_RE, " ")) !== "") {
    year = Number(yb[1]);
    yearInBrackets = true;
    s = s.slice(0, yb.index) + " " + s.slice(yb.index + yb[0].length);
  } else {
    // Bare year: the last one that is followed only by tags ("Inception 2010 1080p").
    // "1917" or "2012" alone stay titles.
    let last: RegExpExecArray | null = null;
    for (const m of s.matchAll(YEAR_BARE_RE)) {
      const before = trimSeparators(s.slice(0, m.index).replace(BRACKET_GROUP_RE, " "));
      if (before !== "" && onlyJunk(s.slice(m.index + m[0].length))) last = m as RegExpExecArray;
    }
    if (last) {
      year = Number(last[1]);
      s = s.slice(0, last.index);
    }
  }

  s = trimSeparators(stripTailJunk(trimSeparators(collapse(s.replace(BRACKET_GROUP_RE, " ")))));
  if (s === "") s = collapse(raw);
  return { title: s, year, yearInBrackets, season, episode };
}

const FOLD: Record<string, string> = { ı: "i", ß: "ss", ø: "o", æ: "ae", œ: "oe", ł: "l", đ: "d" };

/** Comparison key: lowercase, no diacritics (same folding as §5), non-alphanumerics → one space. */
export function compareKey(s: string): string {
  return s
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[ıßøæœłđ]/g, (ch) => FOLD[ch] ?? ch)
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function levenshtein(a: string, b: string): number {
  if (a === b) return 0;
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      cur.push(Math.min(prev[j]! + 1, cur[j - 1]! + 1, prev[j - 1]! + cost));
    }
    prev = cur;
  }
  return prev[b.length]!;
}

/** 0..1: max(edit-distance ratio, token Dice coefficient) of the two comparison keys. */
export function titleSimilarity(a: string, b: string): number {
  const ka = compareKey(a).slice(0, 200);
  const kb = compareKey(b).slice(0, 200);
  if (ka === "" || kb === "") return 0;
  if (ka === kb) return 1;
  const lev = 1 - levenshtein(ka, kb) / Math.max(ka.length, kb.length);
  const ta = new Set(ka.split(" "));
  const tb = new Set(kb.split(" "));
  let common = 0;
  for (const t of ta) if (tb.has(t)) common++;
  const dice = (2 * common) / (ta.size + tb.size);
  return Math.max(lev, dice);
}

function yearOf(date: string | null): number | null {
  const m = date ? /^(\d{4})/.exec(date) : null;
  return m ? Number(m[1]) : null;
}

/** Score of one TMDB candidate for a parsed name (CONTRACT §11.2 step "score"). */
export function scoreCandidate(parsed: ParsedVodName, c: MetadataSearchResult): number {
  let score = Math.max(
    titleSimilarity(parsed.title, c.title),
    c.originalTitle ? titleSimilarity(parsed.title, c.originalTitle) : 0,
  );
  const cy = yearOf(c.releaseDate);
  if (parsed.year !== null) {
    if (cy === null) score -= 0.05;
    else if (cy === parsed.year) score += 0.1;
    else if (Math.abs(cy - parsed.year) === 1) score += 0.05;
    // Large enough that an exact title with a wrong year (remake, "Blade Runner 2049") stays < threshold.
    else score -= 0.35;
  }
  score += Math.min(0.05, Math.log10(c.voteCount + 1) * 0.0125);
  return Math.round(Math.min(1, Math.max(0, score)) * 100) / 100;
}

/** Best candidate (score, then vote count, then TMDB order) – null when the list is empty. */
export function pickBest(
  parsed: ParsedVodName,
  candidates: MetadataSearchResult[],
): { result: MetadataSearchResult; score: number } | null {
  let best: { result: MetadataSearchResult; score: number } | null = null;
  for (const c of candidates) {
    const score = scoreCandidate(parsed, c);
    if (!best || score > best.score || (score === best.score && c.voteCount > best.result.voteCount)) {
      best = { result: c, score };
    }
  }
  return best;
}
