import { beforeEach, describe, expect, it } from "vitest";
import { verifyLicenseToken } from "../src/license/token";
import {
  ADMIN_TOKEN,
  APP_ID,
  DAY,
  Harness,
  T0,
  TEST_PUBLIC_KEYS,
  appleTxPayload,
  newDeviceKey,
  resetDb,
  type TestResponse,
} from "./helpers";

const T0S = Math.floor(T0 / 1000);
const LIFETIME = "de.hasielektronik.novaplayer.lifetime";
const TRIAL = "de.hasielektronik.novaplayer.trial";

let h: Harness;
let dk: string;

beforeEach(async () => {
  await resetDb();
  h = await Harness.create();
  dk = await newDeviceKey("android-1");
});

/** Verifies the token like a client would (CONTRACT §7.2) and checks it mirrors `license`. */
async function claimsOf(r: TestResponse, deviceKey = dk) {
  const v = await verifyLicenseToken(r.json.token as string, TEST_PUBLIC_KEYS, { audience: APP_ID, nowEpochSeconds: Math.floor(h.now / 1000) });
  expect(v.valid).toBe(true);
  if (!v.valid) throw new Error("invalid token");
  expect(v.stale).toBe(false);
  expect(v.claims.iss).toBe("iptvp-license");
  expect(v.claims.sub).toBe(deviceKey);
  expect(v.claims.iat).toBe(Math.floor(h.now / 1000));
  expect(v.claims.exp).toBe(v.claims.iat + 14 * 86_400);
  expect(v.claims.lic).toEqual(r.json.license);
  expect(r.json.serverTime).toBe(h.now);
  return v.claims.lic;
}

describe("POST /v1/license/sync – validation", () => {
  it.each([
    ["missing platform", { deviceKey: "a".repeat(64) }],
    ["unknown platform", { platform: "windows", deviceKey: "a".repeat(64) }],
    ["short deviceKey", { platform: "android", deviceKey: "abc" }],
    ["non-hex deviceKey", { platform: "android", deviceKey: "z".repeat(64) }],
    ["unknown appId", { platform: "android", deviceKey: "a".repeat(64), appId: "com.evil" }],
    ["startTrial not boolean", { platform: "android", deviceKey: "a".repeat(64), startTrial: "yes" }],
    ["google purchases on iOS", { platform: "ios", deviceKey: "a".repeat(64), google: { purchases: [{ productId: "lifetime_access", purchaseToken: "t" }] } }],
    ["apple ids on Android", { platform: "android", deviceKey: "a".repeat(64), apple: { transactionIds: ["2000000001"] } }],
    ["non-numeric apple id", { platform: "ios", deviceKey: "a".repeat(64), apple: { transactionIds: ["abc"] } }],
  ])("400 invalid_request: %s", async (_name, body) => {
    const r = await h.licenseSync(body);
    expect(r.status).toBe(400);
    expect(r.json.error).toBe("invalid_request");
    expect(typeof r.json.message).toBe("string");
  });

  it("400 for a non-JSON body", async () => {
    const r = await h.request("POST", "/v1/license/sync", { rawBody: "not json", headers: { "content-type": "application/json" } });
    expect(r.status).toBe(400);
    expect(r.json.error).toBe("invalid_request");
  });

  it("413 for an oversized body", async () => {
    const r = await h.post("/v1/license/sync", { platform: "android", deviceKey: dk, pad: "x".repeat(70_000) });
    expect(r.status).toBe(413);
  });

  it("accepts an upper-case deviceKey and normalizes it", async () => {
    const r = await h.licenseSync({ platform: "android", deviceKey: dk.toUpperCase() });
    expect(r.status).toBe(200);
    await claimsOf(r);
  });

  it("rate limit: 30/min per deviceKey (DEV_MODE off)", async () => {
    h = await Harness.create({ DEV_MODE: "false" });
    for (let i = 0; i < 30; i++) expect((await h.licenseSync({ platform: "android", deviceKey: dk })).status).toBe(200);
    const r = await h.licenseSync({ platform: "android", deviceKey: dk });
    expect(r.status).toBe(429);
    expect(r.json.error).toBe("rate_limited");
    expect(Number(r.headers.get("retry-after"))).toBeGreaterThan(0);
    // other devices are not affected; the window resets after a minute
    expect((await h.licenseSync({ platform: "android", deviceKey: await newDeviceKey("other") })).status).toBe(200);
    h.advance(60_000);
    expect((await h.licenseSync({ platform: "android", deviceKey: dk })).status).toBe(200);
  });

  it("500 server_misconfigured without a signing key", async () => {
    h = await Harness.create({ LICENSE_SIGNING_KEY: undefined });
    const r = await h.licenseSync({ platform: "android", deviceKey: dk });
    expect(r.status).toBe(500);
    expect(r.json.error).toBe("server_misconfigured");
  });
});

describe("license sync – Android trial (CONTRACT §7.5)", () => {
  it("no trial until startTrial; then trial = server now + trialDays", async () => {
    const r0 = await h.licenseSync({ platform: "android", deviceKey: dk });
    expect(r0.status).toBe(200);
    expect(await claimsOf(r0)).toEqual({ purchased: false, src: null, trialStart: null, trialEnd: null, acct: null });

    h.advance(1000);
    const r1 = await h.licenseSync({ platform: "android", deviceKey: dk, startTrial: true });
    const s = Math.floor(h.now / 1000);
    expect(await claimsOf(r1)).toEqual({ purchased: false, src: null, trialStart: s, trialEnd: s + 7 * 86_400, acct: null });
  });

  it("one trial per deviceKey: a second startTrial does not restart it", async () => {
    const r1 = await h.licenseSync({ platform: "android", deviceKey: dk, startTrial: true });
    h.advance(10 * DAY);
    const r2 = await h.licenseSync({ platform: "android", deviceKey: dk, startTrial: true });
    expect(r2.json.license.trialStart).toBe(r1.json.license.trialStart);
    expect(r2.json.license.trialEnd).toBe(r1.json.license.trialEnd);
  });

  it("snapshot: changing trialDays affects new trials only", async () => {
    const r1 = await h.licenseSync({ platform: "android", deviceKey: dk, startTrial: true });
    expect((await h.admin("PUT", "/v1/admin/config", { trialDays: 14 })).status).toBe(200);
    const r2 = await h.licenseSync({ platform: "android", deviceKey: dk });
    expect(r2.json.license.trialEnd).toBe(r1.json.license.trialEnd);

    const dk2 = await newDeviceKey("android-2");
    const r3 = await h.licenseSync({ platform: "android", deviceKey: dk2, startTrial: true });
    expect(r3.json.license.trialEnd - r3.json.license.trialStart).toBe(14 * 86_400);
    expect((await h.get("/v1/config")).json.trialDays).toBe(14);
  });

  it("startTrial from an Apple device does not create a server trial", async () => {
    const ios = await newDeviceKey("ios-1");
    const r = await h.licenseSync({ platform: "ios", deviceKey: ios, startTrial: true });
    expect((await claimsOf(r, ios)).trialStart).toBeNull();
  });

  it("signed-in device inherits the account's earlier trial (earliest trial wins)", async () => {
    const { token, accountId } = await h.login("trial@example.com");
    const a = await h.licenseSync({ platform: "android", deviceKey: dk, startTrial: true }, token);
    expect(a.json.license.acct).toBe(accountId);
    const first = a.json.license.trialStart as number;

    h.advance(2 * DAY);
    const dk2 = await newDeviceKey("android-tv-2");
    const b = await h.licenseSync({ platform: "androidtv", deviceKey: dk2, startTrial: true }, token);
    expect(b.json.license.trialStart).toBe(first);
    expect(b.json.license.trialEnd).toBe(first + 7 * 86_400);
    expect(await claimsOf(b, dk2)).toMatchObject({ acct: accountId });

    // An unrelated device that started its own (later) trial adopts the earlier one on sign-in.
    const dk3 = await newDeviceKey("android-3");
    await h.licenseSync({ platform: "android", deviceKey: dk3, startTrial: true });
    const c = await h.licenseSync({ platform: "android", deviceKey: dk3 }, token);
    expect(c.json.license.trialStart).toBe(first);

    const acc = await h.get("/v1/account", { token });
    expect(acc.json.trial).toEqual({ start: first, end: first + 7 * 86_400 });
  });

  it("an invalid session token is ignored (sync still works anonymously)", async () => {
    const r = await h.licenseSync({ platform: "android", deviceKey: dk }, "bogus-token");
    expect(r.status).toBe(200);
    expect(r.json.license.acct).toBeNull();
  });
});

describe("license sync – Google Play verification", () => {
  const purchase = (token: string, productId = "lifetime_access") => ({ google: { purchases: [{ productId, purchaseToken: token }] } });

  it("purchaseState 0 → license (src google), acknowledged once", async () => {
    h.stores.googlePurchases.set("tok-1", { purchaseState: 0, acknowledgementState: 0, orderId: "GPA.1111" });
    const r = await h.licenseSync({ platform: "android", deviceKey: dk, ...purchase("tok-1") });
    expect(r.status).toBe(200);
    expect(await claimsOf(r)).toMatchObject({ purchased: true, src: "google" });
    expect(h.stores.count(/:acknowledge$/, "POST")).toBe(1);
    expect(h.stores.oauthCount).toBe(1);

    // Already acknowledged now → no second ack; the OAuth token is cached.
    const r2 = await h.licenseSync({ platform: "android", deviceKey: dk, ...purchase("tok-1") });
    expect(r2.json.license.purchased).toBe(true);
    expect(h.stores.count(/:acknowledge$/, "POST")).toBe(1);
    expect(h.stores.oauthCount).toBe(1);

    // The license sticks to the device even without re-presenting the token.
    const r3 = await h.licenseSync({ platform: "android", deviceKey: dk });
    expect(r3.json.license).toMatchObject({ purchased: true, src: "google" });
  });

  it("phone + TV with the same Google account share the purchase", async () => {
    h.stores.googlePurchases.set("tok-1", { purchaseState: 0, acknowledgementState: 1 });
    await h.licenseSync({ platform: "android", deviceKey: dk, ...purchase("tok-1") });
    const tv = await newDeviceKey("tv");
    const r = await h.licenseSync({ platform: "androidtv", deviceKey: tv, ...purchase("tok-1") });
    expect(await claimsOf(r, tv)).toMatchObject({ purchased: true, src: "google" });
    expect(h.stores.count(/:acknowledge$/)).toBe(0);
  });

  it("pending purchase (state 2) is ignored without error", async () => {
    h.stores.googlePurchases.set("tok-p", { purchaseState: 2 });
    const r = await h.licenseSync({ platform: "android", deviceKey: dk, ...purchase("tok-p") });
    expect(r.status).toBe(200);
    expect(r.json.license.purchased).toBe(false);
    expect(h.stores.count(/:acknowledge$/)).toBe(0);
  });

  it("422 store_verification_failed with details, but still a token for the remaining state", async () => {
    h.stores.googlePurchases.set("tok-ok", { purchaseState: 0, acknowledgementState: 1 });
    h.stores.googlePurchases.set("tok-cancel", { purchaseState: 1 });
    const r = await h.licenseSync({
      platform: "android",
      deviceKey: dk,
      startTrial: true,
      google: {
        purchases: [
          { productId: "lifetime_access", purchaseToken: "tok-unknown" },
          { productId: "lifetime_access", purchaseToken: "tok-cancel" },
          { productId: "some_other_sku", purchaseToken: "tok-ok" },
          { productId: "lifetime_access", purchaseToken: "tok-ok" },
        ],
      },
    });
    expect(r.status).toBe(422);
    expect(r.json.error).toBe("store_verification_failed");
    expect(r.json.details).toEqual([
      { store: "google", index: 0, productId: "lifetime_access", error: "invalid_purchase_token" },
      { store: "google", index: 1, productId: "lifetime_access", error: "purchase_canceled" },
      { store: "google", index: 2, productId: "some_other_sku", error: "unknown_product" },
    ]);
    const lic = await claimsOf(r);
    expect(lic.purchased).toBe(true);
    expect(lic.trialStart).toBe(T0S);
  });

  it("503 store_unavailable (with token) when Google is down", async () => {
    h.stores.googlePurchases.set("tok-1", { purchaseState: 0 });
    h.stores.googleDown = true;
    const r = await h.licenseSync({ platform: "android", deviceKey: dk, startTrial: true, ...purchase("tok-1") });
    expect(r.status).toBe(503);
    expect(r.json.error).toBe("store_unavailable");
    expect(r.headers.get("retry-after")).toBe("60");
    const lic = await claimsOf(r);
    expect(lic.purchased).toBe(false);
    expect(lic.trialStart).toBe(T0S);
  });

  it("503 when the service account is not configured", async () => {
    h = await Harness.create({ GOOGLE_SERVICE_ACCOUNT_JSON: undefined });
    const r = await h.licenseSync({ platform: "android", deviceKey: dk, ...purchase("tok-1") });
    expect(r.status).toBe(503);
    expect(r.json.details[0].error).toBe("store_unavailable");
  });

  it("a revoked (refunded) purchase is reported and not granted", async () => {
    h.stores.googlePurchases.set("tok-1", { purchaseState: 0, acknowledgementState: 1 });
    await h.licenseSync({ platform: "android", deviceKey: dk, ...purchase("tok-1") });
    h.stores.googlePurchases.set("tok-1", { purchaseState: 1 });
    const r = await h.licenseSync({ platform: "android", deviceKey: dk, ...purchase("tok-1") });
    expect(r.status).toBe(422);
    expect(r.json.details[0].error).toBe("purchase_revoked");
    expect(r.json.license.purchased).toBe(false);
  });

  it("does not leak purchase tokens or session tokens into logs", async () => {
    const secretToken = "purchase-token-very-secret-abcdef123456";
    h.stores.googlePurchases.set(secretToken, { purchaseState: 0 });
    const { token } = await h.login("logs@example.com");
    await h.licenseSync({ platform: "android", deviceKey: dk, ...purchase(secretToken) }, token);
    h.assertLogsExclude([secretToken, token, "logs@example.com", ADMIN_TOKEN]);
    expect(h.logs.length).toBeGreaterThan(0);
  });
});

describe("license sync – App Store verification", () => {
  let ios: string;
  beforeEach(async () => {
    ios = await newDeviceKey("ios-device");
  });

  it("lifetime transaction → license (src apple)", async () => {
    h.stores.appleTx.set("2000000001", { env: "Production", payload: appleTxPayload({ transactionId: "2000000001", productId: LIFETIME }) });
    const r = await h.licenseSync({ platform: "ios", deviceKey: ios, apple: { transactionIds: ["2000000001"] } });
    expect(r.status).toBe(200);
    expect(await claimsOf(r, ios)).toMatchObject({ purchased: true, src: "apple" });
    // Apple TV with the same Apple ID (Universal Purchase).
    const tv = await newDeviceKey("apple-tv");
    const r2 = await h.licenseSync({ platform: "tvos", deviceKey: tv, apple: { transactionIds: [2000000001] } });
    expect(r2.json.license).toMatchObject({ purchased: true, src: "apple" });
  });

  it("falls back to the Sandbox environment on 404", async () => {
    h.stores.appleTx.set("2000000002", { env: "Sandbox", payload: appleTxPayload({ transactionId: "2000000002", productId: LIFETIME, environment: "Sandbox" }) });
    const r = await h.licenseSync({ platform: "ios", deviceKey: ios, apple: { transactionIds: ["2000000002"] } });
    expect(r.status).toBe(200);
    expect(r.json.license.purchased).toBe(true);
    expect(h.stores.count(/api\.storekit\.itunes/)).toBe(1);
    expect(h.stores.count(/storekit-sandbox/)).toBe(1);
  });

  it("revocationDate set → not purchased, detail purchase_revoked", async () => {
    h.stores.appleTx.set("2000000003", {
      env: "Production",
      payload: appleTxPayload({ transactionId: "2000000003", productId: LIFETIME, revocationDate: T0 - 1000 }),
    });
    const r = await h.licenseSync({ platform: "ios", deviceKey: ios, apple: { transactionIds: ["2000000003"] } });
    expect(r.status).toBe(422);
    expect(r.json.details).toEqual([{ store: "apple", transactionId: "2000000003", error: "purchase_revoked" }]);
    expect(r.json.license.purchased).toBe(false);
  });

  it("bundle mismatch, unknown product and unknown transaction are rejected", async () => {
    h.stores.appleTx.set("1", { env: "Production", payload: appleTxPayload({ transactionId: "1", productId: LIFETIME, bundleId: "com.other" }) });
    h.stores.appleTx.set("2", { env: "Production", payload: appleTxPayload({ transactionId: "2", productId: "com.other.coins" }) });
    const r = await h.licenseSync({ platform: "ios", deviceKey: ios, apple: { transactionIds: ["1", "2", "3"] } });
    expect(r.status).toBe(422);
    expect(r.json.details.map((d: { error: string }) => d.error)).toEqual(["bundle_mismatch", "unknown_product", "invalid_transaction"]);
    expect(r.json.license.purchased).toBe(false);
  });

  it("503 when the App Store Server API is down", async () => {
    h.stores.appleDown = true;
    const r = await h.licenseSync({ platform: "ios", deviceKey: ios, apple: { transactionIds: ["2000000001"] } });
    expect(r.status).toBe(503);
    expect(r.json.token).toBeTruthy();
  });

  it("trial transaction → trial start = purchaseDate, snapshot of trialDays, shared per Apple ID", async () => {
    const purchaseDate = T0 - 2 * DAY + 123;
    h.stores.appleTx.set("2000000010", {
      env: "Production",
      payload: appleTxPayload({ transactionId: "2000000010", productId: TRIAL, purchaseDate }),
    });
    const r = await h.licenseSync({ platform: "ios", deviceKey: ios, apple: { trialTransactionId: "2000000010" } });
    expect(r.status).toBe(200);
    const start = Math.floor(purchaseDate / 1000);
    expect(await claimsOf(r, ios)).toEqual({ purchased: false, src: null, trialStart: start, trialEnd: start + 7 * 86_400, acct: null });

    // trialDays change later must not alter this Apple ID's trial (snapshot) – also on Apple TV.
    await h.admin("PUT", "/v1/admin/config", { trialDays: 30 });
    const tv = await newDeviceKey("apple-tv");
    const r2 = await h.licenseSync({ platform: "tvos", deviceKey: tv, apple: { trialTransactionId: "2000000010" } });
    expect(r2.json.license.trialStart).toBe(start);
    expect(r2.json.license.trialEnd).toBe(start + 7 * 86_400);
  });

  it("cross-store: Apple purchase while signed in → Android device of that account gets src account", async () => {
    const { token, accountId } = await h.login("cross@example.com");
    h.stores.appleTx.set("2000000020", { env: "Production", payload: appleTxPayload({ transactionId: "2000000020", productId: LIFETIME }) });
    const a = await h.licenseSync({ platform: "ios", deviceKey: ios, apple: { transactionIds: ["2000000020"] } }, token);
    expect(a.json.license).toMatchObject({ purchased: true, src: "apple", acct: accountId });

    const android = await newDeviceKey("android-x");
    const b = await h.licenseSync({ platform: "android", deviceKey: android }, token);
    expect(await claimsOf(b, android)).toMatchObject({ purchased: true, src: "account", acct: accountId });

    // Without the session the Android device has no access.
    const c = await h.licenseSync({ platform: "android", deviceKey: android });
    expect(c.json.license).toMatchObject({ purchased: false, src: null, acct: null });

    // A license belongs to the first account that presented it.
    const other = await h.login("other@example.com");
    const d = await h.licenseSync({ platform: "ios", deviceKey: await newDeviceKey("ios-2"), apple: { transactionIds: ["2000000020"] } }, other.token);
    expect(d.json.license.src).toBe("apple"); // device-level access via the Apple ID
    const e = await h.licenseSync({ platform: "android", deviceKey: await newDeviceKey("android-y") }, other.token);
    expect(e.json.license.purchased).toBe(false);

    // Refund → revoked on every platform.
    h.stores.appleTx.set("2000000020", {
      env: "Production",
      payload: appleTxPayload({ transactionId: "2000000020", productId: LIFETIME, revocationDate: T0 + 1 }),
    });
    await h.licenseSync({ platform: "ios", deviceKey: ios, apple: { transactionIds: ["2000000020"] } }, token);
    const f = await h.licenseSync({ platform: "android", deviceKey: android }, token);
    expect(f.json.license.purchased).toBe(false);
  });
});
