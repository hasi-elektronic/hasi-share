/**
 * CONTRACT §9 pairing encryption, shared by the /pair page (browser) and the tests.
 *
 * IMPORTANT: `iptvpPairEncrypt` must stay fully self-contained (no imports, no module-level
 * helpers): the /pair page inlines its source text via Function.prototype.toString().
 *
 *   e      = ephemeral P-256 key pair
 *   Z      = ECDH(e.priv, tv.pub)                      (32-byte x coordinate)
 *   K      = HKDF-SHA256(ikm=Z, salt=empty, info="iptvp-pair-v1", L=32)
 *   ct     = AES-256-GCM(K, iv=12 random bytes, UTF-8 JSON) with the 16-byte tag appended
 *   result = {epk: e.pub as JWK, iv: b64url, ct: b64url}
 *
 * `fixed` exists only for test vectors (deterministic ephemeral key and iv).
 */
export async function iptvpPairEncrypt(
  tvPublicJwk: { x?: string; y?: string },
  plaintext: string,
  fixed?: { senderPrivateJwk?: { x?: string; y?: string; d?: string }; iv?: Uint8Array },
): Promise<{ epk: { kty: string; crv: string; x: string; y: string }; iv: string; ct: string }> {
  const subtle = crypto.subtle;
  const curve = { name: "ECDH", namedCurve: "P-256" };
  const b64u = (bytes: Uint8Array): string => {
    let bin = "";
    for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i] as number);
    return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  };
  const tvKey = await subtle.importKey(
    "jwk",
    { kty: "EC", crv: "P-256", x: tvPublicJwk.x, y: tvPublicJwk.y },
    curve,
    false,
    [],
  );
  let senderPrivate: CryptoKey;
  let epk: { kty: string; crv: string; x: string; y: string };
  if (fixed && fixed.senderPrivateJwk) {
    const j = fixed.senderPrivateJwk;
    senderPrivate = await subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: j.x, y: j.y, d: j.d }, curve, false, [
      "deriveBits",
    ]);
    epk = { kty: "EC", crv: "P-256", x: String(j.x), y: String(j.y) };
  } else {
    const pair = (await subtle.generateKey(curve, true, ["deriveBits"])) as CryptoKeyPair;
    senderPrivate = pair.privateKey;
    const pub = (await subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
    epk = { kty: "EC", crv: "P-256", x: String(pub.x), y: String(pub.y) };
  }
  const z = await subtle.deriveBits(
    { name: "ECDH", public: tvKey } as unknown as SubtleCryptoDeriveKeyAlgorithm,
    senderPrivate,
    256,
  );
  const ikm = await subtle.importKey("raw", z, "HKDF", false, ["deriveKey"]);
  const aesKey = await subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: new Uint8Array(0),
      info: new TextEncoder().encode("iptvp-pair-v1"),
    } as unknown as SubtleCryptoDeriveKeyAlgorithm,
    ikm,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt"],
  );
  const iv = fixed && fixed.iv ? fixed.iv : crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(
    await subtle.encrypt({ name: "AES-GCM", iv: iv }, aesKey, new TextEncoder().encode(plaintext)),
  );
  return { epk: epk, iv: b64u(iv), ct: b64u(ct) };
}

/**
 * TV-side decryption (reference implementation for tests and documentation; the apps
 * implement it natively). Not inlined into any page.
 */
export async function iptvpPairDecrypt(
  tvPrivateJwk: { x?: string; y?: string; d?: string },
  payload: { epk: { x?: string; y?: string }; iv: string; ct: string },
): Promise<string> {
  const subtle = crypto.subtle;
  const curve = { name: "ECDH", namedCurve: "P-256" };
  const unb64u = (s: string): Uint8Array => {
    const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
    const out = new Uint8Array(b.length);
    for (let i = 0; i < b.length; i++) out[i] = b.charCodeAt(i);
    return out;
  };
  const priv = await subtle.importKey(
    "jwk",
    { kty: "EC", crv: "P-256", x: tvPrivateJwk.x, y: tvPrivateJwk.y, d: tvPrivateJwk.d },
    curve,
    false,
    ["deriveBits"],
  );
  const pub = await subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: payload.epk.x, y: payload.epk.y }, curve, false, []);
  const z = await subtle.deriveBits({ name: "ECDH", public: pub } as unknown as SubtleCryptoDeriveKeyAlgorithm, priv, 256);
  const ikm = await subtle.importKey("raw", z, "HKDF", false, ["deriveKey"]);
  const key = await subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: new Uint8Array(0),
      info: new TextEncoder().encode("iptvp-pair-v1"),
    } as unknown as SubtleCryptoDeriveKeyAlgorithm,
    ikm,
    { name: "AES-GCM", length: 256 },
    false,
    ["decrypt"],
  );
  const pt = await subtle.decrypt({ name: "AES-GCM", iv: unb64u(payload.iv) }, key, unb64u(payload.ct));
  return new TextDecoder().decode(pt);
}

/** Source text of the encryption routine, as inlined into the /pair page. */
export function pairEncryptSource(): string {
  // `__name` shim: harmless if a bundler with keepNames injected helper calls.
  return `var __name = function (f) { return f; };\nwindow.iptvpPairEncrypt = (${iptvpPairEncrypt.toString()});`;
}
