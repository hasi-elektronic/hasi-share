import { randomFromAlphabet, randomToken, sha256Hex } from "../crypto";
import { baseUrl } from "../env";
import { HttpError, json, optString, readJsonObject, reqString, type Ctx } from "../http";
import { rateLimit } from "../ratelimit";
import { requireFeature } from "../features";
import { createSession, requireSession } from "./session";

/** Same unambiguous alphabet as pairing codes (CONTRACT §9). */
export const USER_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
export const DEVICE_CODE_TTL_SEC = 600;
export const DEVICE_POLL_INTERVAL_SEC = 5;
/** Polls closer together than this are answered with `slow_down`. */
const MIN_POLL_GAP_MS = DEVICE_POLL_INTERVAL_SEC * 1000 - 1000;

const PLATFORMS = new Set(["android", "androidtv", "ios", "tvos", "web"]);

/** "abcd-efgh" / "ABCD EFGH" → "ABCDEFGH" (null if not a valid user code). */
export function normalizeUserCode(raw: string): string | null {
  const s = raw.toUpperCase().replace(/[\s-]+/g, "");
  if (s.length !== 8) return null;
  for (const ch of s) if (!USER_CODE_ALPHABET.includes(ch)) return null;
  return s;
}

export const formatUserCode = (code: string) => `${code.slice(0, 4)}-${code.slice(4)}`;

/** POST /v1/auth/device/start {platform, deviceName} */
export async function deviceStart(c: Ctx): Promise<Response> {
  await requireFeature(c, "accounts");
  const body = await readJsonObject(c.req);
  const platform = reqString(body, "platform", { max: 20 });
  if (!PLATFORMS.has(platform)) throw new HttpError(400, "invalid_request", "Unknown platform.");
  const deviceName = optString(body, "deviceName", { max: 100 }) ?? null;
  await rateLimit(c, "device_start_ip", c.ip, 10, 60);

  const now = c.deps.now();
  const deviceCode = randomToken(32);
  const deviceCodeHash = await sha256Hex(deviceCode);
  let userCode = "";
  for (let attempt = 0; attempt < 5 && !userCode; attempt++) {
    const candidate = randomFromAlphabet(USER_CODE_ALPHABET, 8);
    // Free the code if an expired row still holds it.
    await c.env.DB.prepare("DELETE FROM device_codes WHERE user_code = ?1 AND expires_at <= ?2")
      .bind(candidate, now)
      .run();
    const res = await c.env.DB.prepare(
      "INSERT OR IGNORE INTO device_codes (device_code_hash, user_code, platform, device_name, created_at, expires_at) " +
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
      .bind(deviceCodeHash, candidate, platform, deviceName, now, now + DEVICE_CODE_TTL_SEC * 1000)
      .run();
    if ((res.meta.changes ?? 0) > 0) userCode = candidate;
  }
  if (!userCode) throw new HttpError(503, "unavailable", "Could not allocate a code. Try again.");

  const base = baseUrl(c.env);
  return json({
    deviceCode,
    userCode: formatUserCode(userCode),
    verificationUrl: `${base}/link`,
    verificationUrlComplete: `${base}/link?c=${userCode}`,
    interval: DEVICE_POLL_INTERVAL_SEC,
    expiresIn: DEVICE_CODE_TTL_SEC,
  });
}

/** POST /v1/auth/device/poll {deviceCode} */
export async function devicePoll(c: Ctx): Promise<Response> {
  const body = await readJsonObject(c.req);
  const deviceCode = reqString(body, "deviceCode", { max: 128 });
  const hash = await sha256Hex(deviceCode);
  const now = c.deps.now();
  const row = await c.env.DB.prepare(
    "SELECT user_code, device_name, account_id, expires_at, last_poll_at FROM device_codes WHERE device_code_hash = ?1",
  )
    .bind(hash)
    .first<{ user_code: string; device_name: string | null; account_id: string | null; expires_at: number; last_poll_at: number | null }>();
  // Unknown codes are treated like expired ones: the TV must restart the flow.
  if (!row || row.expires_at <= now) {
    if (row) await c.env.DB.prepare("DELETE FROM device_codes WHERE device_code_hash = ?1").bind(hash).run();
    throw new HttpError(410, "expired_token", "The device code has expired. Start again.");
  }
  if (row.last_poll_at !== null && now - row.last_poll_at < MIN_POLL_GAP_MS) {
    await c.env.DB.prepare("UPDATE device_codes SET last_poll_at = ?2 WHERE device_code_hash = ?1").bind(hash, now).run();
    throw new HttpError(429, "slow_down", `Poll at most every ${DEVICE_POLL_INTERVAL_SEC} seconds.`, {
      interval: DEVICE_POLL_INTERVAL_SEC,
    });
  }
  if (!row.account_id) {
    await c.env.DB.prepare("UPDATE device_codes SET last_poll_at = ?2 WHERE device_code_hash = ?1").bind(hash, now).run();
    throw new HttpError(428, "authorization_pending", "Waiting for the user to approve the code.");
  }
  // Approved: consume the code exactly once.
  const del = await c.env.DB.prepare("DELETE FROM device_codes WHERE device_code_hash = ?1 AND account_id IS NOT NULL")
    .bind(hash)
    .run();
  if ((del.meta.changes ?? 0) === 0) throw new HttpError(410, "expired_token", "The device code was already used.");
  const account = await c.env.DB.prepare("SELECT id, email FROM accounts WHERE id = ?1")
    .bind(row.account_id)
    .first<{ id: string; email: string }>();
  if (!account) throw new HttpError(410, "expired_token", "The approving account no longer exists.");
  const sessionToken = await createSession(c, account.id, row.device_name);
  c.log.info("auth.login", { account: account.id, via: "device_code" });
  return json({ sessionToken, account: { id: account.id, email: account.email } });
}

/** POST /v1/auth/device/approve (session) {userCode} */
export async function deviceApprove(c: Ctx): Promise<Response> {
  const session = await requireSession(c);
  const body = await readJsonObject(c.req);
  const userCode = normalizeUserCode(reqString(body, "userCode", { max: 20 }));
  await rateLimit(c, "device_approve_acct", session.accountId, 10, 60);
  if (!userCode) throw new HttpError(404, "invalid_code", "Unknown code.");
  const now = c.deps.now();
  const row = await c.env.DB.prepare("SELECT account_id, expires_at FROM device_codes WHERE user_code = ?1")
    .bind(userCode)
    .first<{ account_id: string | null; expires_at: number }>();
  if (!row) throw new HttpError(404, "invalid_code", "Unknown code.");
  if (row.expires_at <= now) throw new HttpError(410, "expired_token", "The code has expired.");
  if (row.account_id && row.account_id !== session.accountId) {
    throw new HttpError(409, "already_approved", "The code was already approved by another account.");
  }
  await c.env.DB.prepare("UPDATE device_codes SET account_id = ?2 WHERE user_code = ?1 AND expires_at > ?3")
    .bind(userCode, session.accountId, now)
    .run();
  return json({ ok: true });
}
