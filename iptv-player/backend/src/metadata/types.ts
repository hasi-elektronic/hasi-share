/** Wire types of the metadata endpoints (CONTRACT §11.1). */

export type MediaType = "movie" | "tv";
export type MetadataLanguage = "de" | "tr" | "en";

export interface CastMember {
  name: string;
  character: string | null;
  profileUrl: string | null;
}

export interface MediaMetadata {
  tmdbId: number;
  type: MediaType;
  title: string;
  originalTitle: string | null;
  overview: string | null;
  posterUrl: string | null;
  backdropUrl: string | null;
  /** TMDB vote average 0..10, one decimal; null when nobody voted. */
  rating: number | null;
  voteCount: number;
  /** "YYYY-MM-DD" (tv: first air date) or null. */
  releaseDate: string | null;
  genres: string[];
  /** Max 10, billing order. */
  cast: CastMember[];
  /** YouTube watch URL or null. */
  trailerUrl: string | null;
  /** Movie runtime / typical episode runtime in minutes. */
  runtimeMinutes: number | null;
  /** tv only. */
  seasons: number | null;
  language: MetadataLanguage;
}

export interface MetadataSearchResult {
  tmdbId: number;
  type: MediaType;
  title: string;
  originalTitle: string | null;
  overview: string | null;
  posterUrl: string | null;
  backdropUrl: string | null;
  rating: number | null;
  voteCount: number;
  releaseDate: string | null;
}

/** Output of parseVodName (CONTRACT §11.2). */
export interface ParsedVodName {
  title: string;
  year: number | null;
  /** true when the year stood in () or [] – then it is certainly not part of the title. */
  yearInBrackets: boolean;
  season: number | null;
  episode: number | null;
}

export interface MetadataMatch {
  parsed: ParsedVodName;
  /** Best candidate at or above MATCH_THRESHOLD, else null. */
  match: MetadataSearchResult | null;
  /** Score of the best candidate (0..1, two decimals), 0 when TMDB had no results. */
  confidence: number;
}
