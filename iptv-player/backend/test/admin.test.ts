import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { ADMIN_TOKEN, Harness, T0, appleTxPayload, newDeviceKey, resetDb } from "./helpers";

let h: Harness;
beforeEach(async () => {
  await resetDb();
  h = await Harness.create();
});

const T0S = Math.floor(T0 / 1000);

describe("admin auth", () => {
  const endpoints: [string, string, unknown?][] = [
    ["GET", "/v1/admin/config"],
    ["PUT", "/v1/admin/config", { trialDays: 5 }],
    ["POST", "/v1/admin/trials/extend", { accountId: "acc_x", days: 1 }],
    ["GET", "/v1/admin/licenses?query="],
    ["POST", "/v1/admin/licenses/lic_x/revoke"],
    ["POST", "/v1/admin/licenses/lic_x/restore"],
    ["POST", "/v1/admin/licenses/grant", { accountId: "acc_x" }],
  ];

  it.each(endpoints)("%s %s → 401 without / with a wrong token", async (method, path, body) => {
    const o = body !== undefined ? { body } : {};
    expect((await h.request(method, path, o)).status).toBe(401);
    const r = await h.request(method, path, { ...o, token: `${ADMIN_TOKEN}x` });
    expect(r.status).toBe(401);
    expect(r.json.error).toBe("unauthorized");
  });

  it("a user session token is not an admin token", async () => {
    const { token } = await h.login("user@example.com");
    expect((await h.get("/v1/admin/config", { token })).status).toBe(401);
  });

  it("admin API is disabled when ADMIN_TOKEN is missing or shorter than 32 chars", async () => {
    for (const ADMIN of [undefined, "short-token"]) {
      h = await Harness.create({ ADMIN_TOKEN: ADMIN });
      const r = await h.get("/v1/admin/config", { token: ADMIN ?? "" });
      expect(r.status).toBe(401);
    }
  });

  it("the admin token never appears in logs", async () => {
    await h.admin("GET", "/v1/admin/config");
    await h.get("/v1/admin/config", { token: "wrong-admin-token-attempt-1234567890" });
    h.assertLogsExclude([ADMIN_TOKEN, "wrong-admin-token-attempt-1234567890"]);
  });
});

describe("admin config", () => {
  it("GET returns defaults; PUT validates and persists; /v1/config reflects it", async () => {
    const g = await h.admin("GET", "/v1/admin/config");
    expect(g.json).toEqual({ trialDays: 7, minVersion: { android: 1, apple: 1 }, features: { accounts: true, pairing: true, sync: true } });

    for (const bad of [{ trialDays: 0 }, { trialDays: 91 }, { trialDays: 1.5 }, { trialDays: "7" }, {}, { minVersion: { android: -1 } }, { features: { sync: "no" } }]) {
      const r = await h.admin("PUT", "/v1/admin/config", bad);
      expect(r.status).toBe(400);
    }
    const p = await h.admin("PUT", "/v1/admin/config", { trialDays: 90, minVersion: { android: 3 }, features: { pairing: false } });
    expect(p.status).toBe(200);
    expect(p.json).toEqual({ trialDays: 90, minVersion: { android: 3, apple: 1 }, features: { accounts: true, pairing: false, sync: true } });
    const pub = await h.get("/v1/config");
    expect(pub.json).toMatchObject({ trialDays: 90, minVersion: { android: 3, apple: 1 }, features: { pairing: false } });
    expect((await h.admin("PUT", "/v1/admin/config", { trialDays: 1 })).json.trialDays).toBe(1);
  });
});

describe("admin trials/extend", () => {
  it("extends and shortens a device trial (days may be negative)", async () => {
    const dk = await newDeviceKey("ext-1");
    await h.licenseSync({ platform: "android", deviceKey: dk, startTrial: true });
    const r = await h.admin("POST", "/v1/admin/trials/extend", { deviceKey: dk.toUpperCase(), days: 3 });
    expect(r.status).toBe(200);
    expect(r.json).toEqual({ ok: true, scope: "device", accountId: null, trialStart: T0S, trialEnd: T0S + 10 * 86_400 });
    expect((await h.licenseSync({ platform: "android", deviceKey: dk })).json.license.trialEnd).toBe(T0S + 10 * 86_400);

    const s = await h.admin("POST", "/v1/admin/trials/extend", { deviceKey: dk, days: -5 });
    expect(s.json.trialEnd).toBe(T0S + 5 * 86_400);
    // never before the start
    const s2 = await h.admin("POST", "/v1/admin/trials/extend", { deviceKey: dk, days: -100 });
    expect(s2.json.trialEnd).toBe(T0S);
  });

  it("an account trial is extended for every device of the account", async () => {
    const { token, accountId } = await h.login("ext@example.com");
    const a = await newDeviceKey("ext-a");
    const b = await newDeviceKey("ext-b");
    await h.licenseSync({ platform: "android", deviceKey: a, startTrial: true }, token);
    await h.licenseSync({ platform: "androidtv", deviceKey: b }, token);
    const r = await h.admin("POST", "/v1/admin/trials/extend", { deviceKey: b, days: 7 });
    expect(r.json).toMatchObject({ scope: "account", accountId, trialEnd: T0S + 14 * 86_400 });
    // device a, even when syncing anonymously, holds the extended copy
    expect((await h.licenseSync({ platform: "android", deviceKey: a })).json.license.trialEnd).toBe(T0S + 14 * 86_400);
    const r2 = await h.admin("POST", "/v1/admin/trials/extend", { accountId, days: 1 });
    expect(r2.json.trialEnd).toBe(T0S + 15 * 86_400);
    expect((await h.get("/v1/account", { token })).json.trial.end).toBe(T0S + 15 * 86_400);
  });

  it("validation and 404 trial_not_found", async () => {
    const dk = await newDeviceKey("none");
    expect((await h.admin("POST", "/v1/admin/trials/extend", { days: 1 })).status).toBe(400);
    expect((await h.admin("POST", "/v1/admin/trials/extend", { deviceKey: dk, accountId: "acc_1", days: 1 })).status).toBe(400);
    expect((await h.admin("POST", "/v1/admin/trials/extend", { deviceKey: dk, days: 0 })).status).toBe(400);
    expect((await h.admin("POST", "/v1/admin/trials/extend", { deviceKey: "xyz", days: 1 })).status).toBe(400);
    const r = await h.admin("POST", "/v1/admin/trials/extend", { deviceKey: dk, days: 1 });
    expect(r.status).toBe(404);
    expect(r.json.error).toBe("trial_not_found");
    await h.licenseSync({ platform: "android", deviceKey: dk }); // device known, no trial
    expect((await h.admin("POST", "/v1/admin/trials/extend", { deviceKey: dk, days: 1 })).status).toBe(404);
  });
});

describe("admin licenses", () => {
  async function seed() {
    const { token, accountId } = await h.login("buyer@example.com");
    const dk = await newDeviceKey("buyer-android");
    const purchaseToken = "google-purchase-token-abcdefghijklmnop";
    h.stores.googlePurchases.set(purchaseToken, { purchaseState: 0, acknowledgementState: 1, orderId: "GPA.9999-0000" });
    await h.licenseSync({ platform: "android", deviceKey: dk, google: { purchases: [{ productId: "lifetime_access", purchaseToken }] } }, token);
    const ios = await newDeviceKey("buyer-ios");
    h.stores.appleTx.set("5000000001", { env: "Production", payload: appleTxPayload({ transactionId: "5000000001", productId: "de.hasielektronik.novaplayer.lifetime" }) });
    await h.licenseSync({ platform: "ios", deviceKey: ios, apple: { transactionIds: ["5000000001"] } });
    return { token, accountId, dk, ios, purchaseToken };
  }

  it("search by e-mail, account id, device key, order id, store ref and license id; Google tokens masked", async () => {
    const s = await seed();
    const byEmail = await h.admin("GET", "/v1/admin/licenses?query=BUYER@example.com");
    expect(byEmail.json.account).toMatchObject({ id: s.accountId, email: "buyer@example.com" });
    expect(byEmail.json.licenses).toHaveLength(1);
    const lic = byEmail.json.licenses[0];
    expect(lic).toMatchObject({ store: "google", status: "active", orderId: "GPA.9999-0000", accountId: s.accountId, accountEmail: "buyer@example.com", deviceKeys: [s.dk] });
    expect(lic.storeRef).not.toBe(s.purchaseToken);
    expect(byEmail.text).not.toContain(s.purchaseToken);

    expect((await h.admin("GET", `/v1/admin/licenses?query=${s.accountId}`)).json.licenses).toHaveLength(1);
    const byDevice = await h.admin("GET", `/v1/admin/licenses?query=${s.ios}`);
    expect(byDevice.json.device).toMatchObject({ deviceKey: s.ios, platform: "ios" });
    expect(byDevice.json.licenses[0]).toMatchObject({ store: "apple", storeRef: "5000000001" });
    expect((await h.admin("GET", "/v1/admin/licenses?query=GPA.9999-0000")).json.licenses[0].id).toBe(lic.id);
    expect((await h.admin("GET", `/v1/admin/licenses?query=${encodeURIComponent(s.purchaseToken)}`)).json.licenses[0].id).toBe(lic.id);
    expect((await h.admin("GET", `/v1/admin/licenses?query=${lic.id}`)).json.licenses).toHaveLength(1);
    expect((await h.admin("GET", "/v1/admin/licenses?query=")).json.licenses).toHaveLength(2);
    expect((await h.admin("GET", "/v1/admin/licenses?query=nobody@example.com")).json).toEqual({ licenses: [], device: null, account: null });
  });

  it("revoke / restore (admin revocation is not undone by a store re-check)", async () => {
    const s = await seed();
    const id = (await h.admin("GET", `/v1/admin/licenses?query=${s.accountId}`)).json.licenses[0].id as string;
    const rv = await h.admin("POST", `/v1/admin/licenses/${id}/revoke`);
    expect(rv.json).toMatchObject({ ok: true, changed: true, license: { status: "revoked", revokeReason: "admin", revokedAt: T0 } });
    expect((await h.admin("POST", `/v1/admin/licenses/${id}/revoke`)).json.changed).toBe(false);
    // the device re-presents the (still valid) Google purchase: stays revoked
    const again = await h.licenseSync(
      { platform: "android", deviceKey: s.dk, google: { purchases: [{ productId: "lifetime_access", purchaseToken: s.purchaseToken }] } },
      s.token,
    );
    expect(again.json.license.purchased).toBe(false);
    const rs = await h.admin("POST", `/v1/admin/licenses/${id}/restore`);
    expect(rs.json).toMatchObject({ ok: true, changed: true, license: { status: "active", revokeReason: null } });
    expect((await h.licenseSync({ platform: "android", deviceKey: s.dk }, s.token)).json.license.purchased).toBe(true);
    expect((await h.admin("POST", "/v1/admin/licenses/lic_nope/revoke")).status).toBe(404);
  });

  it("grant to an account → src admin on all its devices; grant to a device", async () => {
    const { token, accountId } = await h.login("promo@example.com");
    const g = await h.admin("POST", "/v1/admin/licenses/grant", { accountId, note: "Support #42" });
    expect(g.status).toBe(200);
    expect(g.json.license).toMatchObject({ store: "admin", productId: "admin_grant", status: "active", accountId, note: "Support #42" });
    const dk = await newDeviceKey("promo-dev");
    expect((await h.licenseSync({ platform: "tvos", deviceKey: dk }, token)).json.license).toMatchObject({ purchased: true, src: "admin" });
    expect((await h.licenseSync({ platform: "tvos", deviceKey: dk })).json.license.purchased).toBe(false);

    const dev = await newDeviceKey("grant-device");
    expect((await h.admin("POST", "/v1/admin/licenses/grant", { deviceKey: dev })).status).toBe(404); // never synced
    await h.licenseSync({ platform: "android", deviceKey: dev });
    const g2 = await h.admin("POST", "/v1/admin/licenses/grant", { deviceKey: dev, note: "promo" });
    expect(g2.json.license.deviceKeys).toEqual([dev]);
    expect((await h.licenseSync({ platform: "android", deviceKey: dev })).json.license).toMatchObject({ purchased: true, src: "admin" });

    expect((await h.admin("POST", "/v1/admin/licenses/grant", { accountId: "acc_missing" })).status).toBe(404);
    expect((await h.admin("POST", "/v1/admin/licenses/grant", {})).status).toBe(400);
    expect((await h.admin("POST", "/v1/admin/licenses/grant", { accountId, deviceKey: dev })).status).toBe(400);
  });

  it("license rows contain no personal data besides the account link", async () => {
    await seed();
    const rows = (await env.DB.prepare("SELECT raw_state FROM licenses").all<{ raw_state: string }>()).results;
    for (const r of rows) expect(r.raw_state).not.toMatch(/@|token/i);
  });
});

describe("GET /admin page", () => {
  it("renders without a token, contains no secrets, strict CSP, token kept in sessionStorage only", async () => {
    const r = await h.get("/admin", { headers: { "accept-language": "tr-TR,tr;q=0.9" } });
    expect(r.status).toBe(200);
    expect(r.headers.get("content-type")).toBe("text/html; charset=utf-8");
    expect(r.text).toContain("Yönetim");
    expect(r.text).toContain('type="password"');
    expect(r.text).toContain("sessionStorage");
    expect(r.text).not.toContain("localStorage");
    expect(r.text).not.toContain(ADMIN_TOKEN);
    const csp = r.headers.get("content-security-policy")!;
    expect(csp).toContain("default-src 'none'");
    expect(csp).toContain("frame-ancestors 'none'");
    expect(r.headers.get("x-frame-options")).toBe("DENY");
    const nonce = /script-src 'nonce-([^']+)'/.exec(csp)![1]!;
    expect(r.text).toContain(`<script nonce="${nonce}">`);
    expect(r.text).not.toMatch(/<script(?![^>]*nonce=)(?![^>]*type="application\/json")/);
  });

  it("English by default", async () => {
    const r = await h.get("/admin");
    expect(r.text).toContain('<html lang="en">');
    expect(r.text).toContain("Grant a license");
  });

  it("German via Accept-Language and ?lang=de", async () => {
    for (const r of [await h.get("/admin", { headers: { "accept-language": "de-DE" } }), await h.get("/admin?lang=de")]) {
      expect(r.text).toContain('<html lang="de">');
      expect(r.text).toContain("Lizenz vergeben");
      expect(r.text).toContain('href="/admin?lang=tr"');
    }
  });
});
