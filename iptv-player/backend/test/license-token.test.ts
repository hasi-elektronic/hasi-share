import { describe, expect, it } from "vitest";
import keyVectors from "../../spec/test-vectors/content-keys.json";
import vectors from "../../spec/test-vectors/license-token.json";
import { b64urlDecode, importEs256PrivateKey } from "../src/crypto";
import { buildPayload, signLicenseToken, verifyLicenseToken } from "../src/license/token";
import { decodeJwtPart, deviceKeyFor, testKeys } from "./helpers";

const keys = vectors.keys as Record<string, JsonWebKey>;

describe("license token vectors (CONTRACT §7.2)", () => {
  for (const c of vectors.cases) {
    it(`verifies case '${c.name}'`, async () => {
      const r = await verifyLicenseToken(c.token, keys, { audience: vectors.audience, nowEpochSeconds: c.nowEpochSeconds });
      if (c.expected.valid) {
        expect(r.valid).toBe(true);
        if (r.valid) {
          expect(r.stale).toBe(c.expected.stale);
          expect(r.claims).toEqual(c.expected.claims);
        }
      } else {
        expect(r).toEqual({ valid: false, reason: c.expected.reason });
      }
    });
  }
});

describe("license token signing", () => {
  it("signs with the backend test key (PKCS#8 PEM and JWK) and verifies with the public JWK", async () => {
    const { licensePem } = await testKeys();
    const valid = vectors.cases.find((c) => c.name === "valid")!;
    const claims = valid.expected.claims!;
    const payload = buildPayload(claims.aud, claims.sub, claims.iat, claims.lic as never);
    expect(payload).toEqual(claims); // exact claim set incl. exp = iat + 14 days

    for (const material of [licensePem, JSON.stringify(vectors.privateKeyForBackendTests.jwk)]) {
      const token = await signLicenseToken(payload, material, vectors.privateKeyForBackendTests.kid);
      const [h, p, s] = token.split(".");
      expect(decodeJwtPart(token, 0)).toEqual({ alg: "ES256", kid: "test-1", typ: "JWT" });
      // Same header/payload serialization as the vector token; signature differs (random k).
      expect(`${h}.${p}`).toBe(valid.token.split(".").slice(0, 2).join("."));
      expect(b64urlDecode(s!).length).toBe(64); // raw r||s, not DER
      const r = await verifyLicenseToken(token, keys, { audience: vectors.audience, nowEpochSeconds: valid.nowEpochSeconds });
      expect(r).toEqual({ valid: true, stale: false, claims });
    }
  });

  it("imports a PEM with escaped newlines (as pasted from JSON)", async () => {
    const { licensePem } = await testKeys();
    await expect(importEs256PrivateKey(licensePem.replace(/\n/g, "\\n"))).resolves.toBeDefined();
  });

  it("deviceKey format matches content-keys.json (CONTRACT §7.1)", async () => {
    for (const d of keyVectors.deviceKeys) {
      expect(await deviceKeyFor(d.appId, d.rawId)).toBe(d.expected);
    }
  });
});
