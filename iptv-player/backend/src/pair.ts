import { b64urlDecode, randomFromAlphabet, randomToken, sha256Hex, timingSafeEqualStr } from "./crypto";
import { baseUrl } from "./env";
import { requireFeature } from "./features";
import { HttpError, badRequest, json, readJsonObject, type Ctx } from "./http";
import { rateLimit } from "./ratelimit";

/** CONTRACT §9 */
export const PAIR_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
export const PAIR_CODE_LENGTH = 6;
export const PAIR_TTL_SEC = 600;
export const PAIR_MAX_CT_BYTES = 8 * 1024;

const B64URL_COORD = /^[A-Za-z0-9_-]{43}$/;

/** "abc-123" / "ABC 123" → "ABC123", or null if invalid. */
export function normalizePairCode(raw: string): string | null {
  const s = raw.toUpperCase().replace(/[\s-]+/g, "");
  if (s.length !== PAIR_CODE_LENGTH) return null;
  for (const ch of s) if (!PAIR_CODE_ALPHABET.includes(ch)) return null;
  return s;
}

/** Validates a P-256 public JWK and returns a canonical copy {kty, crv, x, y}. */
export async function canonicalPublicJwk(v: unknown, field: string): Promise<{ kty: "EC"; crv: "P-256"; x: string; y: string }> {
  if (!v || typeof v !== "object" || Array.isArray(v)) throw badRequest(`'${field}' must be a JWK object.`);
  const j = v as Record<string, unknown>;
  if ("d" in j) throw badRequest(`'${field}' must not contain private key material.`);
  if (j.kty !== "EC" || j.crv !== "P-256" || typeof j.x !== "string" || typeof j.y !== "string") {
    throw badRequest(`'${field}' must be an EC P-256 public JWK.`);
  }
  if (!B64URL_COORD.test(j.x) || !B64URL_COORD.test(j.y)) throw badRequest(`'${field}' has invalid coordinates.`);
  const jwk = { kty: "EC" as const, crv: "P-256" as const, x: j.x, y: j.y };
  try {
    // Rejects points that are not on the curve.
    await crypto.subtle.importKey("jwk", jwk, { name: "ECDH", namedCurve: "P-256" }, false, []);
  } catch {
    throw badRequest(`'${field}' is not a valid P-256 public key.`);
  }
  return jwk;
}

interface PairRow {
  secret_hash: string;
  public_key: string;
  payload: string | null;
  expires_at: number;
}

async function loadSession(c: Ctx, rawCode: string): Promise<{ code: string; row: PairRow }> {
  const code = normalizePairCode(rawCode);
  if (!code) throw new HttpError(404, "not_found", "Unknown pairing code.");
  const row = await c.env.DB.prepare("SELECT secret_hash, public_key, payload, expires_at FROM pair_sessions WHERE code = ?1")
    .bind(code)
    .first<PairRow>();
  if (!row) throw new HttpError(404, "not_found", "Unknown pairing code.");
  if (row.expires_at <= c.deps.now()) throw new HttpError(410, "expired", "The pairing code has expired.");
  return { code, row };
}

/** POST /v1/pair/sessions {publicKey} → {code, secret, expiresAt, pairUrl} */
export async function pairCreate(c: Ctx): Promise<Response> {
  await requireFeature(c, "pairing");
  const body = await readJsonObject(c.req, 4 * 1024);
  const publicKey = await canonicalPublicJwk(body.publicKey, "publicKey");
  await rateLimit(c, "pair_create_ip", c.ip, 10, 60);

  const now = c.deps.now();
  const expiresAt = now + PAIR_TTL_SEC * 1000;
  const secret = randomToken(32);
  const secretHash = await sha256Hex(secret);
  let code = "";
  for (let attempt = 0; attempt < 8 && !code; attempt++) {
    const candidate = randomFromAlphabet(PAIR_CODE_ALPHABET, PAIR_CODE_LENGTH);
    await c.env.DB.prepare("DELETE FROM pair_sessions WHERE code = ?1 AND expires_at <= ?2").bind(candidate, now).run();
    const r = await c.env.DB.prepare(
      "INSERT OR IGNORE INTO pair_sessions (code, secret_hash, public_key, payload, created_at, expires_at) VALUES (?1, ?2, ?3, NULL, ?4, ?5)",
    )
      .bind(candidate, secretHash, JSON.stringify(publicKey), now, expiresAt)
      .run();
    if ((r.meta.changes ?? 0) > 0) code = candidate;
  }
  if (!code) throw new HttpError(503, "unavailable", "Could not allocate a pairing code. Try again.");
  return json({
    code,
    secret,
    expiresAt,
    expiresIn: PAIR_TTL_SEC,
    pairUrl: `${baseUrl(c.env)}/pair?c=${code}`,
  });
}

/** GET /v1/pair/sessions/{code}/key → {publicKey} */
export async function pairGetKey(c: Ctx): Promise<Response> {
  await requireFeature(c, "pairing");
  await rateLimit(c, "pair_key_ip", c.ip, 60, 60);
  const { row } = await loadSession(c, c.params.code ?? "");
  if (row.payload !== null) throw new HttpError(409, "already_used", "A source was already sent with this code.");
  return json({ publicKey: JSON.parse(row.public_key) as unknown, expiresAt: row.expires_at });
}

/** POST /v1/pair/sessions/{code}/payload {epk, iv, ct} → {ok: true} (once) */
export async function pairPostPayload(c: Ctx): Promise<Response> {
  await requireFeature(c, "pairing");
  // base64url(8 KB) ≈ 11 KB + JWK + JSON overhead.
  const body = await readJsonObject(c.req, 16 * 1024);
  await rateLimit(c, "pair_payload_ip", c.ip, 30, 60);
  const epk = await canonicalPublicJwk(body.epk, "epk");
  if (typeof body.iv !== "string" || typeof body.ct !== "string") throw badRequest("'iv' and 'ct' must be base64url strings.");
  let iv: Uint8Array;
  let ct: Uint8Array;
  try {
    iv = b64urlDecode(body.iv);
    ct = b64urlDecode(body.ct);
  } catch {
    throw badRequest("'iv' and 'ct' must be base64url strings.");
  }
  if (iv.length !== 12) throw badRequest("'iv' must be 12 bytes.");
  if (ct.length < 17) throw badRequest("'ct' is too short.");
  if (ct.length > PAIR_MAX_CT_BYTES) {
    throw new HttpError(413, "payload_too_large", `'ct' must not exceed ${PAIR_MAX_CT_BYTES} bytes.`);
  }
  const { code } = await loadSession(c, c.params.code ?? "");
  const payload = JSON.stringify({ epk, iv: body.iv, ct: body.ct });
  const r = await c.env.DB.prepare(
    "UPDATE pair_sessions SET payload = ?2 WHERE code = ?1 AND payload IS NULL AND expires_at > ?3",
  )
    .bind(code, payload, c.deps.now())
    .run();
  if ((r.meta.changes ?? 0) === 0) throw new HttpError(409, "already_used", "A source was already sent with this code.");
  c.log.info("pair.payload_stored", { bytes: ct.length });
  return json({ ok: true });
}

/** GET /v1/pair/sessions/{code}?secret= → 202 pending | 200 {epk, iv, ct} (deleted after) */
export async function pairPoll(c: Ctx): Promise<Response> {
  await requireFeature(c, "pairing");
  const secret = c.url.searchParams.get("secret") ?? "";
  const { code, row } = await loadSession(c, c.params.code ?? "");
  // A wrong secret is indistinguishable from an unknown code.
  if (!secret || !(await timingSafeEqualStr(await sha256Hex(secret), row.secret_hash))) {
    throw new HttpError(404, "not_found", "Unknown pairing code.");
  }
  if (row.payload === null) return json({ status: "pending" }, 202);
  // Single delivery: only the request that deletes the row returns the ciphertext.
  const del = await c.env.DB.prepare(
    "DELETE FROM pair_sessions WHERE code = ?1 AND secret_hash = ?2 AND payload IS NOT NULL RETURNING payload",
  )
    .bind(code, row.secret_hash)
    .first<{ payload: string }>();
  if (!del) throw new HttpError(404, "not_found", "Unknown pairing code.");
  return json(JSON.parse(del.payload) as unknown);
}
