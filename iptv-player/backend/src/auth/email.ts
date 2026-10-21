import { randomFromAlphabet, randomId, sha256Hex, timingSafeEqualStr } from "../crypto";
import { isDevMode } from "../env";
import { HttpError, badRequest, json, optString, readJsonObject, reqString, type Ctx } from "../http";
import { sendLoginCode, type Lang } from "../mail";
import { pickLang } from "../pages/i18n";
import { rateLimit } from "../ratelimit";
import { requireFeature } from "../features";
import { createSession } from "./session";

export const CODE_TTL_MS = 10 * 60_000;
export const MAX_CODE_ATTEMPTS = 5;

const EMAIL_RE = /^[^\s@<>()",;:]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;

export function normalizeEmail(raw: string): string {
  const e = raw.trim().toLowerCase();
  if (e.length > 254 || !EMAIL_RE.test(e)) throw badRequest("Invalid e-mail address.");
  return e;
}

export const emailHash = (email: string) => sha256Hex(`email|${email}`);
const codeHash = (eh: string, code: string) => sha256Hex(`otp|${eh}|${code}`);

/** POST /v1/auth/email/start {email, locale} → {ok: true[, devCode]} */
export async function emailStart(c: Ctx): Promise<Response> {
  await requireFeature(c, "accounts");
  const body = await readJsonObject(c.req);
  const email = normalizeEmail(reqString(body, "email", { max: 254 }));
  const localeRaw = optString(body, "locale", { max: 10 });
  const primary = localeRaw?.toLowerCase().split(/[-_]/)[0];
  const lang: Lang = primary === "de" || primary === "tr" || primary === "en" ? primary : pickLang(c.req, c.url);

  await rateLimit(c, "email_start_ip", c.ip, 20, 3600);
  await rateLimit(c, "email_start_email", email, 5, 3600);

  const now = c.deps.now();
  const code = randomFromAlphabet("0123456789", 6);
  const eh = await emailHash(email);
  await c.env.DB.prepare(
    "INSERT INTO email_codes (email_hash, code_hash, attempts, created_at, expires_at) VALUES (?1, ?2, 0, ?3, ?4) " +
      "ON CONFLICT(email_hash) DO UPDATE SET code_hash = excluded.code_hash, attempts = 0, " +
      "created_at = excluded.created_at, expires_at = excluded.expires_at",
  )
    .bind(eh, await codeHash(eh, code), now, now + CODE_TTL_MS)
    .run();

  const dev = isDevMode(c.env);
  const result = await sendLoginCode(c, email, code, lang);
  if (result === "failed" || (result === "skipped" && !dev)) {
    throw new HttpError(503, "email_unavailable", "The login e-mail could not be sent. Try again later.");
  }
  c.log.info("auth.email_code_sent", { email, delivered: result === "sent" });
  return json(dev ? { ok: true, devCode: code } : { ok: true });
}

/** POST /v1/auth/email/verify {email, code, deviceName} → {sessionToken, account} */
export async function emailVerify(c: Ctx): Promise<Response> {
  await requireFeature(c, "accounts");
  const body = await readJsonObject(c.req);
  const email = normalizeEmail(reqString(body, "email", { max: 254 }));
  const code = typeof body.code === "string" ? body.code.replace(/\s+/g, "") : "";
  const deviceName = optString(body, "deviceName", { max: 100 }) ?? null;
  await rateLimit(c, "email_verify_ip", c.ip, 60, 3600);

  const now = c.deps.now();
  const eh = await emailHash(email);
  const row = await c.env.DB.prepare(
    "SELECT code_hash, attempts, expires_at FROM email_codes WHERE email_hash = ?1",
  )
    .bind(eh)
    .first<{ code_hash: string; attempts: number; expires_at: number }>();
  if (!row) throw new HttpError(400, "invalid_code", "The code is invalid. Request a new code.");
  if (row.expires_at <= now) {
    await c.env.DB.prepare("DELETE FROM email_codes WHERE email_hash = ?1").bind(eh).run();
    throw new HttpError(410, "code_expired", "The code has expired. Request a new code.");
  }
  if (row.attempts >= MAX_CODE_ATTEMPTS) {
    throw new HttpError(429, "too_many_attempts", "Too many wrong codes. Request a new code.");
  }
  const ok = /^\d{6}$/.test(code) && (await timingSafeEqualStr(await codeHash(eh, code), row.code_hash));
  if (!ok) {
    const upd = await c.env.DB.prepare(
      "UPDATE email_codes SET attempts = attempts + 1 WHERE email_hash = ?1 RETURNING attempts",
    )
      .bind(eh)
      .first<{ attempts: number }>();
    const attempts = upd?.attempts ?? MAX_CODE_ATTEMPTS;
    if (attempts >= MAX_CODE_ATTEMPTS) {
      throw new HttpError(429, "too_many_attempts", "Too many wrong codes. Request a new code.");
    }
    throw new HttpError(400, "invalid_code", "The code is invalid.", {
      attemptsLeft: MAX_CODE_ATTEMPTS - attempts,
    });
  }

  // Single use: only the request that deletes the row may continue.
  const del = await c.env.DB.prepare("DELETE FROM email_codes WHERE email_hash = ?1 AND code_hash = ?2")
    .bind(eh, row.code_hash)
    .run();
  if ((del.meta.changes ?? 0) === 0) throw new HttpError(400, "invalid_code", "The code was already used.");

  const account = await findOrCreateAccount(c, email);
  const sessionToken = await createSession(c, account.id, deviceName);
  c.log.info("auth.login", { account: account.id, via: "email" });
  return json({ sessionToken, account: { id: account.id, email: account.email } });
}

export async function findOrCreateAccount(c: Ctx, email: string): Promise<{ id: string; email: string }> {
  await c.env.DB.prepare(
    "INSERT INTO accounts (id, email, created_at, sync_seq) VALUES (?1, ?2, ?3, 0) ON CONFLICT(email) DO NOTHING",
  )
    .bind(randomId("acc_", 10), email, c.deps.now())
    .run();
  const row = await c.env.DB.prepare("SELECT id, email FROM accounts WHERE email = ?1")
    .bind(email)
    .first<{ id: string; email: string }>();
  if (!row) throw new HttpError(500, "internal_error", "Account could not be created.");
  return row;
}
