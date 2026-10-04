import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { b64Encode, b64urlEncode, utf8 } from "../src/crypto";
import { DAY, Harness, PUBSUB_TOKEN, T0, appleTxPayload, fakeJws, newDeviceKey, resetDb } from "./helpers";

const LIFETIME = "de.hasielektronik.novaplayer.lifetime";
const TRIAL = "de.hasielektronik.novaplayer.trial";
const PKG = "de.hasielektronik.novaplayer";

let h: Harness;
beforeEach(async () => {
  await resetDb();
  h = await Harness.create();
});

async function licenseRow(store: string, ref: string) {
  return env.DB.prepare("SELECT * FROM licenses WHERE store = ?1 AND store_ref = ?2")
    .bind(store, ref)
    .first<{ id: string; status: string; revoke_reason: string | null; device_key: string | null }>();
}

// ---------------------------------------------------------------------------
// Google Play RTDN (Pub/Sub push)
// ---------------------------------------------------------------------------

function pubsub(notification: Record<string, unknown>, token: string | null = PUBSUB_TOKEN) {
  const body = {
    message: { data: b64Encode(utf8(JSON.stringify(notification))), messageId: "1", publishTime: "2025-10-04T09:00:00Z" },
    subscription: "projects/p/subscriptions/s",
  };
  return h.post(`/v1/webhooks/google${token === null ? "" : `?token=${encodeURIComponent(token)}`}`, body);
}

const oneTime = (type: number, purchaseToken: string, sku = "lifetime_access") => ({
  version: "1.0",
  packageName: PKG,
  eventTimeMillis: String(T0),
  oneTimeProductNotification: { version: "1.0", notificationType: type, purchaseToken, sku },
});

const voided = (purchaseToken: string) => ({
  version: "1.0",
  packageName: PKG,
  eventTimeMillis: String(T0),
  voidedPurchaseNotification: { purchaseToken, orderId: "GPA.1", productType: 2, refundType: 1 },
});

async function buyOnDevice(token: string) {
  h.stores.googlePurchases.set(token, { purchaseState: 0, acknowledgementState: 1 });
  const dk = await newDeviceKey("android-wh");
  const r = await h.licenseSync({ platform: "android", deviceKey: dk, google: { purchases: [{ productId: "lifetime_access", purchaseToken: token }] } });
  expect(r.json.license.purchased).toBe(true);
  return dk;
}

describe("POST /v1/webhooks/google", () => {
  it("401 with a missing or wrong token", async () => {
    expect((await pubsub(oneTime(1, "t"), null)).status).toBe(401);
    expect((await pubsub(oneTime(1, "t"), "wrong")).status).toBe(401);
    expect(h.stores.calls).toHaveLength(0);
  });

  it("401 when GOOGLE_PUBSUB_TOKEN is not configured", async () => {
    h = await Harness.create({ GOOGLE_PUBSUB_TOKEN: undefined });
    expect((await pubsub(oneTime(1, "t"), "")).status).toBe(401);
  });

  it("204 for malformed bodies, other packages and test notifications (no Google calls)", async () => {
    expect((await h.post(`/v1/webhooks/google?token=${PUBSUB_TOKEN}`, { message: { data: "%%%" } })).status).toBe(204);
    expect((await h.post(`/v1/webhooks/google?token=${PUBSUB_TOKEN}`, { nothing: true })).status).toBe(204);
    expect((await pubsub({ ...oneTime(1, "t"), packageName: "com.other" })).status).toBe(204);
    expect((await pubsub({ version: "1.0", packageName: PKG, testNotification: { version: "1.0" } })).status).toBe(204);
    expect(h.stores.calls).toHaveLength(0);
  });

  it("PURCHASED (type 1) → re-queries Google, records the license and acknowledges", async () => {
    h.stores.googlePurchases.set("rt-1", { purchaseState: 0, acknowledgementState: 0 });
    const r = await pubsub(oneTime(1, "rt-1"));
    expect(r.status).toBe(204);
    expect(h.stores.count(/tokens\/rt-1$/, "GET")).toBe(1);
    expect(h.stores.count(/tokens\/rt-1:acknowledge$/, "POST")).toBe(1);
    expect((await licenseRow("google", "rt-1"))?.status).toBe("active");
  });

  it("PURCHASED for a still-pending purchase records nothing", async () => {
    h.stores.googlePurchases.set("rt-p", { purchaseState: 2 });
    expect((await pubsub(oneTime(1, "rt-p"))).status).toBe(204);
    expect(await licenseRow("google", "rt-p")).toBeNull();
  });

  it("CANCELED (type 2) → revokes only if Google confirms", async () => {
    await buyOnDevice("rt-2");
    // Google still says purchased → nothing changes.
    expect((await pubsub(oneTime(2, "rt-2"))).status).toBe(204);
    expect((await licenseRow("google", "rt-2"))?.status).toBe("active");
    // Google confirms cancellation.
    h.stores.googlePurchases.set("rt-2", { purchaseState: 1 });
    expect((await pubsub(oneTime(2, "rt-2"))).status).toBe(204);
    expect(await licenseRow("google", "rt-2")).toMatchObject({ status: "revoked", revoke_reason: "store" });
  });

  it("voidedPurchaseNotification → revoke when products.get reports canceled", async () => {
    const dk = await buyOnDevice("rt-3");
    h.stores.googlePurchases.set("rt-3", { purchaseState: 1 });
    expect((await pubsub(voided("rt-3"))).status).toBe(204);
    expect((await licenseRow("google", "rt-3"))?.status).toBe("revoked");
    const r = await h.licenseSync({ platform: "android", deviceKey: dk });
    expect(r.json.license.purchased).toBe(false);
  });

  it("voidedPurchaseNotification → revoke when the token is gone at Google (410)", async () => {
    await buyOnDevice("rt-4");
    h.stores.googlePurchases.set("rt-4", 410);
    expect((await pubsub(voided("rt-4"))).status).toBe(204);
    expect((await licenseRow("google", "rt-4"))?.status).toBe("revoked");
  });

  it("voided while products.get still says PURCHASED → confirmed via the Voided Purchases API", async () => {
    await buyOnDevice("rt-5");
    expect((await pubsub(voided("rt-5"))).status).toBe(204);
    expect((await licenseRow("google", "rt-5"))?.status).toBe("active"); // not in voided list → unconfirmed
    h.stores.googleVoided.push({ purchaseToken: "rt-5", orderId: "GPA.1", voidedTimeMillis: String(T0) });
    expect((await pubsub(voided("rt-5"))).status).toBe(204);
    expect((await licenseRow("google", "rt-5"))?.status).toBe("revoked");
  });

  it("forged voided notification is harmless (Google says purchased, not voided)", async () => {
    await buyOnDevice("rt-6");
    await pubsub(voided("rt-6"));
    expect((await licenseRow("google", "rt-6"))?.status).toBe("active");
  });

  it("Google outage during a voided notification → no state change, still 204", async () => {
    await buyOnDevice("rt-7");
    h.stores.googleDown = true;
    expect((await pubsub(voided("rt-7"))).status).toBe(204);
    expect((await licenseRow("google", "rt-7"))?.status).toBe("active");
  });

  it("voided purchases are final: a later products.get=0 does not restore", async () => {
    const dk = await buyOnDevice("rt-8");
    h.stores.googlePurchases.set("rt-8", { purchaseState: 1 });
    await pubsub(voided("rt-8"));
    h.stores.googlePurchases.set("rt-8", { purchaseState: 0, acknowledgementState: 1 });
    const r = await h.licenseSync({ platform: "android", deviceKey: dk, google: { purchases: [{ productId: "lifetime_access", purchaseToken: "rt-8" }] } });
    expect(r.json.license.purchased).toBe(false);
  });

  it("unknown license in a voided notification → 204, no change", async () => {
    expect((await pubsub(voided("never-seen"))).status).toBe(204);
  });

  it("never logs the push token or purchase tokens", async () => {
    await buyOnDevice("purchase-token-secret-0123456789");
    h.stores.googlePurchases.set("purchase-token-secret-0123456789", { purchaseState: 1 });
    await pubsub(voided("purchase-token-secret-0123456789"));
    await pubsub(oneTime(1, "x"), "wrong-token-value");
    h.assertLogsExclude([PUBSUB_TOKEN, "purchase-token-secret-0123456789", "wrong-token-value"]);
  });
});

// ---------------------------------------------------------------------------
// App Store Server Notifications V2
// ---------------------------------------------------------------------------

function assn(type: string, txId: string, extra: Record<string, unknown> = {}) {
  const signedTransactionInfo = fakeJws(appleTxPayload({ transactionId: txId, productId: LIFETIME }));
  return h.post("/v1/webhooks/apple", {
    signedPayload: fakeJws({
      notificationType: type,
      notificationUUID: crypto.randomUUID(),
      version: "2.0",
      signedDate: T0,
      data: { bundleId: PKG, environment: "Production", signedTransactionInfo, ...extra },
    }),
  });
}

async function buyApple(txId: string) {
  h.stores.appleTx.set(txId, { env: "Production", payload: appleTxPayload({ transactionId: txId, productId: LIFETIME }) });
  const dk = await newDeviceKey(`ios-${txId}`);
  const r = await h.licenseSync({ platform: "ios", deviceKey: dk, apple: { transactionIds: [txId] } });
  expect(r.json.license.purchased).toBe(true);
  return dk;
}

const refundedTx = (txId: string) => ({
  env: "Production" as const,
  payload: appleTxPayload({ transactionId: txId, productId: LIFETIME, revocationDate: T0 + 1000 }),
});

describe("POST /v1/webhooks/apple", () => {
  it("400 for a missing or undecodable signedPayload", async () => {
    expect((await h.post("/v1/webhooks/apple", {})).status).toBe(400);
    expect((await h.post("/v1/webhooks/apple", { signedPayload: "a.b" })).status).toBe(400);
    expect((await h.post("/v1/webhooks/apple", { signedPayload: `x.${b64urlEncode("[1]")}.y` })).status).toBe(400);
  });

  it("REFUND → re-fetches from Apple and revokes", async () => {
    const dk = await buyApple("3000000001");
    h.stores.appleTx.set("3000000001", refundedTx("3000000001"));
    const r = await assn("REFUND", "3000000001");
    expect(r.status).toBe(200);
    expect(r.json).toEqual({ ok: true });
    expect(await licenseRow("apple", "3000000001")).toMatchObject({ status: "revoked", revoke_reason: "store" });
    expect((await h.licenseSync({ platform: "ios", deviceKey: dk })).json.license.purchased).toBe(false);
  });

  it("REVOKE (family sharing) → revoke", async () => {
    await buyApple("3000000002");
    h.stores.appleTx.set("3000000002", refundedTx("3000000002"));
    await assn("REVOKE", "3000000002");
    expect((await licenseRow("apple", "3000000002"))?.status).toBe("revoked");
  });

  it("trust by re-query: a forged REFUND for a non-revoked transaction changes nothing", async () => {
    await buyApple("3000000003");
    const r = await assn("REFUND", "3000000003");
    expect(r.status).toBe(200);
    expect((await licenseRow("apple", "3000000003"))?.status).toBe("active");
  });

  it("REFUND_REVERSED → restore", async () => {
    const dk = await buyApple("3000000004");
    h.stores.appleTx.set("3000000004", refundedTx("3000000004"));
    await assn("REFUND", "3000000004");
    h.stores.appleTx.set("3000000004", { env: "Production", payload: appleTxPayload({ transactionId: "3000000004", productId: LIFETIME }) });
    await assn("REFUND_REVERSED", "3000000004");
    expect((await licenseRow("apple", "3000000004"))?.status).toBe("active");
    expect((await h.licenseSync({ platform: "ios", deviceKey: dk })).json.license.purchased).toBe(true);
  });

  it("an admin revocation is sticky (REFUND_REVERSED does not undo it)", async () => {
    await buyApple("3000000005");
    const id = (await licenseRow("apple", "3000000005"))!.id;
    expect((await h.admin("POST", `/v1/admin/licenses/${id}/revoke`)).status).toBe(200);
    await assn("REFUND_REVERSED", "3000000005");
    expect(await licenseRow("apple", "3000000005")).toMatchObject({ status: "revoked", revoke_reason: "admin" });
  });

  it("CONSUMPTION_REQUEST and other types → 200 no-op (no Apple call)", async () => {
    for (const t of ["CONSUMPTION_REQUEST", "TEST", "PRICE_INCREASE", "DID_RENEW"]) {
      const r = await assn(t, "3000000006");
      expect(r.status).toBe(200);
    }
    expect(h.stores.calls).toHaveLength(0);
  });

  it("wrong bundle id → 200 ignored", async () => {
    await buyApple("3000000007");
    h.stores.appleTx.set("3000000007", refundedTx("3000000007"));
    const before = h.stores.calls.length;
    await assn("REFUND", "3000000007", { bundleId: "com.other.app" });
    expect(h.stores.calls.length).toBe(before);
    expect((await licenseRow("apple", "3000000007"))?.status).toBe("active");
  });

  it("uses the notification's environment as the first lookup", async () => {
    h.stores.appleTx.set("3000000008", { env: "Sandbox", payload: appleTxPayload({ transactionId: "3000000008", productId: LIFETIME, environment: "Sandbox" }) });
    await h.licenseSync({ platform: "ios", deviceKey: await newDeviceKey("sbx"), apple: { transactionIds: ["3000000008"] } });
    h.stores.calls = [];
    h.stores.appleTx.set("3000000008", { env: "Sandbox", payload: appleTxPayload({ transactionId: "3000000008", productId: LIFETIME, environment: "Sandbox", revocationDate: T0 }) });
    await assn("REFUND", "3000000008", { environment: "Sandbox" });
    expect(h.stores.calls.map((c) => new URL(c.url).hostname)).toEqual(["api.storekit-sandbox.itunes.apple.com"]);
    expect((await licenseRow("apple", "3000000008"))?.status).toBe("revoked");
  });

  it("503 when Apple is unavailable (Apple retries)", async () => {
    await buyApple("3000000009");
    h.stores.appleDown = true;
    const r = await assn("REFUND", "3000000009");
    expect(r.status).toBe(503);
    expect(r.json.error).toBe("store_unavailable");
  });

  it("unknown transaction → 200, nothing created", async () => {
    const r = await assn("REFUND", "3000000010");
    expect(r.status).toBe(200);
    expect(await licenseRow("apple", "3000000010")).toBeNull();
  });

  it("REFUND of a trial marker revokes the Apple trial record", async () => {
    h.stores.appleTx.set("3000000011", { env: "Production", payload: appleTxPayload({ transactionId: "3000000011", productId: TRIAL, purchaseDate: T0 - DAY }) });
    await h.licenseSync({ platform: "ios", deviceKey: await newDeviceKey("trial-ios"), apple: { trialTransactionId: "3000000011" } });
    h.stores.appleTx.set("3000000011", {
      env: "Production",
      payload: appleTxPayload({ transactionId: "3000000011", productId: TRIAL, purchaseDate: T0 - DAY, revocationDate: T0 }),
    });
    const signedTransactionInfo = fakeJws(appleTxPayload({ transactionId: "3000000011", productId: TRIAL }));
    await h.post("/v1/webhooks/apple", {
      signedPayload: fakeJws({ notificationType: "REFUND", data: { bundleId: PKG, environment: "Production", signedTransactionInfo } }),
    });
    const row = await env.DB.prepare("SELECT revoked FROM apple_trials WHERE original_transaction_id = '3000000011'").first<{ revoked: number }>();
    expect(row?.revoked).toBe(1);
  });
});
