import { randomToken, sha256Hex } from "../crypto";
import { bearerToken, unauthorized, type Ctx } from "../http";

export const SESSION_TTL_MS = 180 * 86_400_000;
/** Sliding expiry is refreshed at most once per day per session (avoids a write per request). */
const SLIDE_INTERVAL_MS = 86_400_000;

export interface Session {
  tokenHash: string;
  accountId: string;
  email: string;
}

export async function createSession(c: Ctx, accountId: string, deviceName: string | null): Promise<string> {
  const token = randomToken(32);
  const now = c.deps.now();
  await c.env.DB.prepare(
    "INSERT INTO sessions (token_hash, account_id, device_name, created_at, expires_at, last_used_at) " +
      "VALUES (?1, ?2, ?3, ?4, ?5, ?4)",
  )
    .bind(await sha256Hex(token), accountId, deviceName, now, now + SESSION_TTL_MS)
    .run();
  return token;
}

/** Returns the session for the request's bearer token, or null (missing/invalid/expired). */
export async function optionalSession(c: Ctx): Promise<Session | null> {
  const token = bearerToken(c.req);
  if (!token || token.length > 128) return null;
  const tokenHash = await sha256Hex(token);
  const now = c.deps.now();
  const row = await c.env.DB.prepare(
    "SELECT s.account_id, s.expires_at, s.last_used_at, a.email FROM sessions s " +
      "JOIN accounts a ON a.id = s.account_id WHERE s.token_hash = ?1",
  )
    .bind(tokenHash)
    .first<{ account_id: string; expires_at: number; last_used_at: number; email: string }>();
  if (!row) return null;
  if (row.expires_at <= now) {
    await c.env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?1").bind(tokenHash).run();
    return null;
  }
  if (now - row.last_used_at >= SLIDE_INTERVAL_MS) {
    await c.env.DB.prepare("UPDATE sessions SET expires_at = ?2, last_used_at = ?3 WHERE token_hash = ?1")
      .bind(tokenHash, now + SESSION_TTL_MS, now)
      .run();
  }
  return { tokenHash, accountId: row.account_id, email: row.email };
}

export async function requireSession(c: Ctx): Promise<Session> {
  const s = await optionalSession(c);
  if (!s) throw unauthorized("A valid session token is required.");
  return s;
}
