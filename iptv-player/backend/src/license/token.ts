import { b64urlDecode, fromUtf8, importEs256PrivateKey, signJws, utf8 } from "../crypto";

export const LICENSE_ISSUER = "iptvp-license";
export const LICENSE_TTL_SEC = 14 * 86_400;

export type LicenseSrc = "google" | "apple" | "account" | "admin" | null;

export interface LicenseClaims {
  purchased: boolean;
  src: LicenseSrc;
  trialStart: number | null;
  trialEnd: number | null;
  acct: string | null;
}

export interface LicensePayload {
  iss: string;
  aud: string;
  sub: string;
  iat: number;
  exp: number;
  lic: LicenseClaims;
}

const keyCache = new Map<string, Promise<CryptoKey>>();

function signingKey(material: string): Promise<CryptoKey> {
  let p = keyCache.get(material);
  if (!p) {
    p = importEs256PrivateKey(material);
    keyCache.set(material, p);
    p.catch(() => keyCache.delete(material));
  }
  return p;
}

/** Builds the CONTRACT §7.2 payload with the exact key order used by the spec. */
export function buildPayload(aud: string, sub: string, iat: number, lic: LicenseClaims): LicensePayload {
  return {
    iss: LICENSE_ISSUER,
    aud,
    sub,
    iat,
    exp: iat + LICENSE_TTL_SEC,
    lic: {
      purchased: lic.purchased,
      src: lic.src,
      trialStart: lic.trialStart,
      trialEnd: lic.trialEnd,
      acct: lic.acct,
    },
  };
}

/** Signs a license JWS: header {alg: ES256, kid, typ: JWT}, signature raw r||s base64url. */
export async function signLicenseToken(payload: LicensePayload, keyMaterial: string, kid: string): Promise<string> {
  const key = await signingKey(keyMaterial);
  return signJws({ alg: "ES256", kid, typ: "JWT" }, payload as unknown as Record<string, unknown>, key);
}

export type VerifyResult =
  | { valid: true; stale: boolean; claims: LicensePayload }
  | { valid: false; reason: "format" | "alg" | "kid" | "signature" | "iss" | "aud" };

/**
 * Client-side validation rules (CONTRACT §7.2). The backend uses it in tests and in
 * the admin tools; apps implement the same algorithm natively.
 */
export async function verifyLicenseToken(
  token: string,
  keys: Record<string, JsonWebKey>,
  opts: { audience: string | string[]; nowEpochSeconds: number; issuer?: string },
): Promise<VerifyResult> {
  const parts = token.split(".");
  if (parts.length !== 3) return { valid: false, reason: "format" };
  let header: Record<string, unknown>;
  let payload: Record<string, unknown>;
  let sig: Uint8Array;
  try {
    header = JSON.parse(fromUtf8(b64urlDecode(parts[0]!))) as Record<string, unknown>;
    payload = JSON.parse(fromUtf8(b64urlDecode(parts[1]!))) as Record<string, unknown>;
    sig = b64urlDecode(parts[2]!);
    if (!header || typeof header !== "object" || !payload || typeof payload !== "object") {
      return { valid: false, reason: "format" };
    }
  } catch {
    return { valid: false, reason: "format" };
  }
  if (header.alg !== "ES256") return { valid: false, reason: "alg" };
  const kid = header.kid;
  if (typeof kid !== "string" || !Object.prototype.hasOwnProperty.call(keys, kid)) {
    return { valid: false, reason: "kid" };
  }
  if (sig.length !== 64) return { valid: false, reason: "signature" };
  const jwk = keys[kid]!;
  let ok = false;
  try {
    const pub = await crypto.subtle.importKey(
      "jwk",
      { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, sig, utf8(`${parts[0]}.${parts[1]}`));
  } catch {
    ok = false;
  }
  if (!ok) return { valid: false, reason: "signature" };
  if (payload.iss !== (opts.issuer ?? LICENSE_ISSUER)) return { valid: false, reason: "iss" };
  const auds = Array.isArray(opts.audience) ? opts.audience : [opts.audience];
  if (typeof payload.aud !== "string" || !auds.includes(payload.aud)) return { valid: false, reason: "aud" };
  const exp = typeof payload.exp === "number" ? payload.exp : 0;
  return { valid: true, stale: opts.nowEpochSeconds >= exp, claims: payload as unknown as LicensePayload };
}
