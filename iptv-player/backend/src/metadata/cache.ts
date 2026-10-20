import { HttpError, notFound, type Ctx } from "../http";
import type { TmdbResult } from "./tmdb";

/**
 * Two-tier read-through cache in front of TMDB:
 *   KV (optional binding METADATA_KV, expirationTtl) → D1 row (fresh window) → TMDB.
 * A D1 row older than the fresh window is still served when TMDB fails ("stale-if-error").
 */

export type CacheSource = "kv" | "d1" | "tmdb" | "stale";

export interface CachePolicy {
  /** KV expirationTtl in seconds (KV minimum is 60). */
  kvTtlSec: number;
  /** How long a D1 row counts as fresh. */
  freshMs: number;
}

export const DAY_MS = 86_400_000;
export const DETAILS_POLICY: CachePolicy = { kvTtlSec: 7 * 86_400, freshMs: 14 * DAY_MS };
export const LOOKUP_POLICY: CachePolicy = { kvTtlSec: 86_400, freshMs: 3 * DAY_MS };
/** Rows not refreshed for this long are deleted by the daily cron. */
export const METADATA_RETENTION_MS = 90 * DAY_MS;

/** D1 side of one cache entry. */
export interface D1Slot {
  read(): Promise<{ payload: string; fetchedAt: number } | null>;
  write(payload: string, fetchedAt: number): D1PreparedStatement;
}

interface KvEnvelope {
  t: number;
  v: unknown;
}

export async function cached<T>(
  c: Ctx,
  kvKey: string,
  slot: D1Slot,
  policy: CachePolicy,
  load: () => Promise<TmdbResult<T> | null>,
): Promise<{ data: T; source: CacheSource }> {
  const kv = c.env.METADATA_KV;
  const now = c.deps.now();

  if (kv) {
    try {
      const hit = await kv.get<KvEnvelope>(kvKey, "json");
      if (hit && typeof hit.t === "number" && now - hit.t < policy.kvTtlSec * 1000) {
        return { data: hit.v as T, source: "kv" };
      }
    } catch (e) {
      c.log.warn("metadata.kv_read_failed", { err: e instanceof Error ? e.message : String(e) });
    }
  }

  const row = await slot.read();
  let parsedRow: T | undefined;
  if (row) {
    try {
      parsedRow = JSON.parse(row.payload) as T;
    } catch {
      parsedRow = undefined;
    }
  }
  if (row && parsedRow !== undefined && now - row.fetchedAt < policy.freshMs) {
    // Re-warm KV so the next read skips D1 (remaining lifetime only).
    const remainingSec = Math.floor((policy.freshMs - (now - row.fetchedAt)) / 1000);
    if (kv) putKv(c, kvKey, { t: row.fetchedAt, v: parsedRow }, Math.min(policy.kvTtlSec, remainingSec));
    return { data: parsedRow, source: "d1" };
  }

  const loaded = await load();
  if (loaded?.ok) {
    const payload = JSON.stringify(loaded.data);
    c.waitUntil(
      slot
        .write(payload, now)
        .run()
        .catch((e: unknown) => c.log.warn("metadata.d1_write_failed", { err: e instanceof Error ? e.message : String(e) })),
    );
    if (kv) putKv(c, kvKey, { t: now, v: loaded.data }, policy.kvTtlSec);
    return { data: loaded.data, source: "tmdb" };
  }
  if (loaded && loaded.kind === "not_found") throw notFound("No such title on TMDB.");
  if (parsedRow !== undefined) return { data: parsedRow, source: "stale" };
  if (loaded === null) {
    throw new HttpError(503, "metadata_unavailable", "Metadata service is not configured.");
  }
  throw new HttpError(503, "metadata_unavailable", "Metadata service is temporarily unavailable.", { retryAfter: 60 }, {
    "retry-after": "60",
  });
}

function putKv(c: Ctx, key: string, value: KvEnvelope, ttlSec: number): void {
  if (ttlSec < 60) return; // KV rejects shorter TTLs; D1 still has the row.
  c.waitUntil(
    c.env.METADATA_KV!.put(key, JSON.stringify(value), { expirationTtl: ttlSec }).catch((e: unknown) =>
      // Free plan: 1 000 KV writes/day – failures are expected there and harmless.
      c.log.warn("metadata.kv_write_failed", { err: e instanceof Error ? e.message : String(e) }),
    ),
  );
}
