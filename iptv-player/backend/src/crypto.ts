/** Small WebCrypto helpers shared by all modules (Workers-compatible, no dependencies). */

const enc = new TextEncoder();
const dec = new TextDecoder();

export function utf8(s: string): Uint8Array {
  return enc.encode(s);
}

export function fromUtf8(b: Uint8Array): string {
  return dec.decode(b);
}

export function b64Encode(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]!);
  return btoa(s);
}

export function b64urlEncode(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? utf8(input) : input;
  return b64Encode(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Decodes standard or URL-safe base64 (padding optional). Throws on invalid input. */
export function b64Decode(s: string): Uint8Array {
  const norm = s.replace(/-/g, "+").replace(/_/g, "/").replace(/\s+/g, "");
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(norm)) throw new Error("invalid base64");
  const unpadded = norm.replace(/=+$/, "");
  if (unpadded.length % 4 === 1) throw new Error("invalid base64 length");
  const padded = unpadded + "===".slice((unpadded.length + 3) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Strict base64url decode (rejects '+', '/', '='). */
export function b64urlDecode(s: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) throw new Error("invalid base64url");
  return b64Decode(s);
}

export function toHex(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += bytes[i]!.toString(16).padStart(2, "0");
  return s;
}

export function fromHex(hex: string): Uint8Array {
  if (hex.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(hex)) throw new Error("invalid hex");
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

export async function sha256(data: Uint8Array | string): Promise<Uint8Array> {
  const bytes = typeof data === "string" ? utf8(data) : data;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

export async function sha256Hex(data: Uint8Array | string): Promise<string> {
  return toHex(await sha256(data));
}

export function randomBytes(n: number): Uint8Array {
  const b = new Uint8Array(n);
  crypto.getRandomValues(b);
  return b;
}

/** 32 random bytes, base64url – used for session tokens, pairing secrets, device codes. */
export function randomToken(bytes = 32): string {
  return b64urlEncode(randomBytes(bytes));
}

export function randomId(prefix: string, bytes = 12): string {
  return prefix + toHex(randomBytes(bytes));
}

/** Uniformly random string over `alphabet` (rejection sampling, no modulo bias). */
export function randomFromAlphabet(alphabet: string, length: number): string {
  const n = alphabet.length;
  const limit = 256 - (256 % n);
  let out = "";
  while (out.length < length) {
    const buf = randomBytes(length * 2);
    for (let i = 0; i < buf.length && out.length < length; i++) {
      const v = buf[i]!;
      if (v < limit) out += alphabet[v % n];
    }
  }
  return out;
}

/** Constant-time string comparison (compares SHA-256 digests so lengths do not leak). */
export async function timingSafeEqualStr(a: string, b: string): Promise<boolean> {
  const [da, db] = await Promise.all([sha256(a), sha256(b)]);
  let diff = 0;
  for (let i = 0; i < da.length; i++) diff |= da[i]! ^ db[i]!;
  return diff === 0 && a.length === b.length;
}

export function timingSafeEqualBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

export function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [A-Z ]+-----/g, "")
    .replace(/-----END [A-Z ]+-----/g, "")
    .replace(/\\n/g, "")
    .replace(/\s+/g, "");
  return b64Decode(body);
}

export function derToPem(der: Uint8Array, label: string): string {
  const b64 = b64Encode(der);
  const lines = b64.match(/.{1,64}/g) ?? [];
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`;
}

/** Imports an ECDSA P-256 private key from PKCS#8 PEM or a private JWK (JSON string). */
export async function importEs256PrivateKey(keyMaterial: string): Promise<CryptoKey> {
  const trimmed = keyMaterial.trim();
  const alg = { name: "ECDSA", namedCurve: "P-256" };
  if (trimmed.startsWith("{")) {
    const jwk = JSON.parse(trimmed) as JsonWebKey;
    const { key_ops: _ops, ext: _ext, ...clean } = jwk;
    return crypto.subtle.importKey("jwk", clean, alg, false, ["sign"]);
  }
  return crypto.subtle.importKey("pkcs8", pemToDer(trimmed), alg, false, ["sign"]);
}

export async function importRs256PrivateKey(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "pkcs8",
    pemToDer(pem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

/** Signs a compact JWS. ES256 signatures from WebCrypto are already raw r||s (64 bytes). */
export async function signJws(
  header: Record<string, unknown>,
  payload: Record<string, unknown>,
  key: CryptoKey,
): Promise<string> {
  const input = `${b64urlEncode(JSON.stringify(header))}.${b64urlEncode(JSON.stringify(payload))}`;
  const algo =
    header.alg === "RS256"
      ? { name: "RSASSA-PKCS1-v1_5" }
      : { name: "ECDSA", hash: "SHA-256" };
  const sig = new Uint8Array(await crypto.subtle.sign(algo, key, utf8(input)));
  return `${input}.${b64urlEncode(sig)}`;
}

/** Decodes the payload of a compact JWS WITHOUT verifying it (trust comes from elsewhere). */
export function decodeJwsPayloadUnverified(jws: string): Record<string, unknown> | null {
  const parts = jws.split(".");
  if (parts.length !== 3 || !parts[1]) return null;
  try {
    const obj = JSON.parse(fromUtf8(b64urlDecode(parts[1])));
    return obj && typeof obj === "object" && !Array.isArray(obj) ? (obj as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}
