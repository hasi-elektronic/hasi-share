import { sha256Hex } from "./crypto";
import { isDevMode } from "./env";
import { HttpError, type Ctx } from "./http";

/** Factor applied to every limit in DEV_MODE (local development only). */
const DEV_FACTOR = 100;

/**
 * Fixed-window rate limiter backed by D1 (one atomic upsert per check).
 * `key` is hashed so no IPs / e-mails are stored. Throws 429 `rate_limited` when exceeded.
 */
export async function rateLimit(
  c: Ctx,
  name: string,
  key: string,
  limit: number,
  windowSec: number,
): Promise<void> {
  const effective = isDevMode(c.env) ? limit * DEV_FACTOR : limit;
  const now = c.deps.now();
  const windowMs = windowSec * 1000;
  const windowStart = Math.floor(now / windowMs) * windowMs;
  const bucket = `${name}:${(await sha256Hex(`${name}|${key}`)).slice(0, 32)}`;
  const row = await c.env.DB.prepare(
    "INSERT INTO rate_limits (bucket, count, window_start) VALUES (?1, 1, ?2) " +
      "ON CONFLICT(bucket) DO UPDATE SET " +
      "count = CASE WHEN rate_limits.window_start = excluded.window_start THEN rate_limits.count + 1 ELSE 1 END, " +
      "window_start = excluded.window_start " +
      "RETURNING count",
  )
    .bind(bucket, windowStart)
    .first<{ count: number }>();
  if (row && row.count > effective) {
    const retryAfter = Math.max(1, Math.ceil((windowStart + windowMs - now) / 1000));
    throw new HttpError(
      429,
      "rate_limited",
      "Too many requests. Try again later.",
      { retryAfter },
      { "retry-after": String(retryAfter) },
    );
  }
}
