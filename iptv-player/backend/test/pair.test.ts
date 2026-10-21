import { beforeEach, describe, expect, it } from "vitest";
import vec from "../../spec/test-vectors/pair-crypto.json";
import { b64urlDecode, b64urlEncode, toHex } from "../src/crypto";
import { iptvpPairDecrypt, iptvpPairEncrypt, pairEncryptSource } from "../src/pages/pairCrypto";
import { Harness, resetDb } from "./helpers";

const ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

describe("pair-crypto.json vectors (CONTRACT §9)", () => {
  it("vector is internally consistent (ECDH Z and HKDF key)", async () => {
    const curve = { name: "ECDH", namedCurve: "P-256" };
    const strip = ({ key_ops: _o, ext: _e, ...j }: Record<string, unknown>) => j as unknown as JsonWebKey;
    const priv = await crypto.subtle.importKey("jwk", strip(vec.senderPrivateJwk), curve, false, ["deriveBits"]);
    const pub = await crypto.subtle.importKey("jwk", vec.tvPublicJwk, curve, false, []);
    const z = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: pub } as never, priv, 256));
    expect(toHex(z)).toBe(vec.sharedSecretHex);
    const ikm = await crypto.subtle.importKey("raw", z, "HKDF", false, ["deriveBits"]);
    const k = new Uint8Array(
      await crypto.subtle.deriveBits(
        { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: new TextEncoder().encode("iptvp-pair-v1") } as never,
        ikm,
        256,
      ),
    );
    expect(toHex(k)).toBe(vec.aesKeyHex);
    expect(vec.payload.epk).toEqual(vec.senderPublicJwk);
    expect(b64urlDecode(vec.payload.ct).length).toBe(new TextEncoder().encode(vec.plaintext).length + 16);
  });

  it("page encryption with the vector's fixed sender key + iv reproduces the vector ciphertext", async () => {
    const out = await iptvpPairEncrypt(vec.tvPublicJwk, vec.plaintext, {
      senderPrivateJwk: vec.senderPrivateJwk,
      iv: b64urlDecode(vec.payload.iv),
    });
    expect(out).toEqual(vec.payload);
  });

  it("TV-side reference decryption recovers the plaintext", async () => {
    expect(await iptvpPairDecrypt(vec.tvPrivateJwk, vec.payload)).toBe(vec.plaintext);
  });

  it("random encryption round-trips and tampering is detected", async () => {
    const out = await iptvpPairEncrypt(vec.tvPublicJwk, "hello çğ");
    expect(b64urlDecode(out.iv).length).toBe(12);
    expect(await iptvpPairDecrypt(vec.tvPrivateJwk, out)).toBe("hello çğ");
    const ct = b64urlDecode(out.ct);
    ct[0]! ^= 1;
    await expect(iptvpPairDecrypt(vec.tvPrivateJwk, { ...out, ct: b64urlEncode(ct) })).rejects.toThrow();
  });

  it("the inlined page source is self-contained (no imports / bundler helpers needed)", () => {
    const src = pairEncryptSource();
    expect(src).toContain("window.iptvpPairEncrypt = (async function");
    expect(src).not.toMatch(/\bimport\b|\brequire\(/);
    expect(src).toContain("iptvp-pair-v1");
  });
});

describe("pairing API", () => {
  let h: Harness;
  let tvKeys: CryptoKeyPair;
  let tvPub: JsonWebKey;
  let tvPriv: JsonWebKey;

  beforeEach(async () => {
    await resetDb();
    h = await Harness.create();
    tvKeys = (await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"])) as CryptoKeyPair;
    const pub = (await crypto.subtle.exportKey("jwk", tvKeys.publicKey)) as JsonWebKey;
    tvPub = { kty: "EC", crv: "P-256", x: pub.x!, y: pub.y! };
    tvPriv = (await crypto.subtle.exportKey("jwk", tvKeys.privateKey)) as JsonWebKey;
  });

  async function create(ip?: string) {
    const r = await h.post("/v1/pair/sessions", { publicKey: tvPub }, ip ? { ip } : {});
    expect(r.status).toBe(200);
    return r.json as { code: string; secret: string; expiresAt: number; pairUrl: string };
  }

  it("full flow: create → key → encrypted payload → poll once → deleted", async () => {
    const s = await create();
    expect(s.code).toHaveLength(6);
    for (const ch of s.code) expect(ALPHABET).toContain(ch);
    expect(s.pairUrl).toBe(`https://tv.example.test/pair?c=${s.code}`);
    expect(s.expiresAt).toBe(h.now + 600_000);
    expect(s.secret).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const pending = await h.get(`/v1/pair/sessions/${s.code}?secret=${s.secret}`);
    expect(pending.status).toBe(202);
    expect(pending.json).toEqual({ status: "pending" });

    // Phone: code typed as "abc-123" works too.
    const k = await h.get(`/v1/pair/sessions/${s.code.slice(0, 3).toLowerCase()}-${s.code.slice(3).toLowerCase()}/key`);
    expect(k.status).toBe(200);
    expect(k.json.publicKey).toEqual(tvPub);

    const plaintext = JSON.stringify({ v: 1, type: "m3u", name: "Home", url: "http://lists.example.com/get.php?username=u&password=p" });
    const enc = await iptvpPairEncrypt(k.json.publicKey, plaintext);
    const post = await h.post(`/v1/pair/sessions/${s.code}/payload`, enc);
    expect(post.status).toBe(200);
    expect(post.json).toEqual({ ok: true });

    const again = await h.post(`/v1/pair/sessions/${s.code}/payload`, enc);
    expect(again.status).toBe(409);
    expect((await h.get(`/v1/pair/sessions/${s.code}/key`)).status).toBe(409);

    const got = await h.get(`/v1/pair/sessions/${s.code}?secret=${encodeURIComponent(s.secret)}`);
    expect(got.status).toBe(200);
    expect(got.json).toEqual(enc);
    expect(await iptvpPairDecrypt(tvPriv, got.json as never)).toBe(plaintext);

    // delivered once, then gone
    expect((await h.get(`/v1/pair/sessions/${s.code}?secret=${s.secret}`)).status).toBe(404);
    // the backend never logged the ciphertext or the source URL
    h.assertLogsExclude([enc.ct, "lists.example.com", s.secret]);
  });

  it("wrong or missing secret → 404 (indistinguishable from unknown code)", async () => {
    const s = await create();
    expect((await h.get(`/v1/pair/sessions/${s.code}?secret=nope`)).status).toBe(404);
    expect((await h.get(`/v1/pair/sessions/${s.code}`)).status).toBe(404);
    expect((await h.get(`/v1/pair/sessions/ZZZZZZ?secret=${s.secret}`)).status).toBe(404);
    expect((await h.get(`/v1/pair/sessions/ZZZZZZ/key`)).status).toBe(404);
    expect((await h.get(`/v1/pair/sessions/bad!/key`)).status).toBe(404);
  });

  it("410 after the 10-minute TTL (key, payload, poll)", async () => {
    const s = await create();
    const enc = await iptvpPairEncrypt(tvPub, "{}");
    h.advance(600_000);
    expect((await h.get(`/v1/pair/sessions/${s.code}/key`)).status).toBe(410);
    expect((await h.post(`/v1/pair/sessions/${s.code}/payload`, enc)).status).toBe(410);
    expect((await h.get(`/v1/pair/sessions/${s.code}?secret=${s.secret}`)).status).toBe(410);
  });

  it("400 for invalid public keys", async () => {
    const bad = [
      undefined,
      "string",
      { kty: "RSA", n: "x", e: "AQAB" },
      { kty: "EC", crv: "P-384", x: tvPub.x, y: tvPub.y },
      { ...tvPub, d: tvPriv.d },
      { ...tvPub, x: "short" },
      { ...tvPub, y: tvPub.x }, // not on the curve
    ];
    for (const publicKey of bad) {
      const r = await h.post("/v1/pair/sessions", { publicKey });
      expect(r.status).toBe(400);
      expect(r.json.error).toBe("invalid_request");
    }
  });

  it("payload validation: iv must be 12 bytes, ct 17 B … 8 KB, epk a valid public key", async () => {
    const s = await create();
    const enc = await iptvpPairEncrypt(tvPub, "x");
    const b = (n: number) => b64urlEncode(new Uint8Array(n));
    const p = (body: unknown) => h.post(`/v1/pair/sessions/${s.code}/payload`, body);
    expect((await p({ ...enc, iv: b(16) })).status).toBe(400);
    expect((await p({ ...enc, iv: "+/==" })).status).toBe(400);
    expect((await p({ ...enc, ct: b(16) })).status).toBe(400);
    expect((await p({ ...enc, ct: b(8 * 1024 + 1) })).status).toBe(413);
    expect((await p({ ...enc, epk: { kty: "EC" } })).status).toBe(400);
    expect((await p({ epk: enc.epk })).status).toBe(400);
    // exactly 8 KB is accepted
    expect((await p({ ...enc, ct: b(8 * 1024) })).status).toBe(200);
  });

  it("create is rate limited: 10/min per IP (DEV_MODE off)", async () => {
    h = await Harness.create({ DEV_MODE: "false" });
    for (let i = 0; i < 10; i++) await create("198.18.0.1");
    const r = await h.post("/v1/pair/sessions", { publicKey: tvPub }, { ip: "198.18.0.1" });
    expect(r.status).toBe(429);
    await create("198.18.0.2");
    h.advance(60_000);
    await create("198.18.0.1");
  });

  it("403 when pairing is disabled", async () => {
    await h.admin("PUT", "/v1/admin/config", { features: { pairing: false } });
    expect((await h.post("/v1/pair/sessions", { publicKey: tvPub })).status).toBe(403);
  });
});
