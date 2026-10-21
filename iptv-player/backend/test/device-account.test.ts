import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { normalizeUserCode } from "../src/auth/device";
import { DAY, Harness, T0, appleTxPayload, newDeviceKey, resetDb } from "./helpers";

let h: Harness;
beforeEach(async () => {
  await resetDb();
  h = await Harness.create();
});

describe("device-code flow (TV login)", () => {
  async function start() {
    const r = await h.post("/v1/auth/device/start", { platform: "tvos", deviceName: "Living room" });
    expect(r.status).toBe(200);
    return r.json as { deviceCode: string; userCode: string; verificationUrl: string; verificationUrlComplete: string; interval: number; expiresIn: number };
  }

  it("start returns the spec'd shape", async () => {
    const s = await start();
    expect(s.userCode).toMatch(/^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$/);
    expect(s.verificationUrl).toBe("https://tv.example.test/link");
    expect(s.verificationUrlComplete).toBe(`https://tv.example.test/link?c=${s.userCode.replace("-", "")}`);
    expect(s.interval).toBe(5);
    expect(s.expiresIn).toBe(600);
    expect(s.deviceCode).toMatch(/^[A-Za-z0-9_-]{43}$/);
  });

  it("400 for unknown platform", async () => {
    expect((await h.post("/v1/auth/device/start", { platform: "toaster" })).status).toBe(400);
  });

  it("pending → slow_down → approve → session (consumed once)", async () => {
    const s = await start();
    const p1 = await h.post("/v1/auth/device/poll", { deviceCode: s.deviceCode });
    expect(p1.status).toBe(428);
    expect(p1.json.error).toBe("authorization_pending");

    h.advance(1000);
    const p2 = await h.post("/v1/auth/device/poll", { deviceCode: s.deviceCode });
    expect(p2.status).toBe(429);
    expect(p2.json.error).toBe("slow_down");

    const { token, accountId } = await h.login("tv-owner@example.com");
    const ap = await h.post("/v1/auth/device/approve", { userCode: s.userCode.toLowerCase() }, { token });
    expect(ap.status).toBe(200);
    expect(ap.json).toEqual({ ok: true });

    h.advance(5000);
    const p3 = await h.post("/v1/auth/device/poll", { deviceCode: s.deviceCode });
    expect(p3.status).toBe(200);
    expect(p3.json.account).toEqual({ id: accountId, email: "tv-owner@example.com" });
    const tvToken = p3.json.sessionToken as string;
    const acc = await h.get("/v1/account", { token: tvToken });
    expect(acc.json.id).toBe(accountId);
    const sess = await env.DB.prepare("SELECT device_name FROM sessions WHERE account_id = ?1 AND device_name = 'Living room'").bind(accountId).first();
    expect(sess).not.toBeNull();

    h.advance(5000);
    const p4 = await h.post("/v1/auth/device/poll", { deviceCode: s.deviceCode });
    expect(p4.status).toBe(410);
    expect(p4.json.error).toBe("expired_token");
  });

  it("approve accepts the code without dash and with spaces", async () => {
    expect(normalizeUserCode("abcd efgh")).toBe("ABCDEFGH");
    expect(normalizeUserCode("ABCD-EFG1")).toBeNull(); // '1' not in alphabet
    const s = await start();
    const { token } = await h.login("x@example.com");
    expect((await h.post("/v1/auth/device/approve", { userCode: s.userCode.replace("-", " ") }, { token })).status).toBe(200);
  });

  it("410 expired_token after 10 minutes (poll and approve)", async () => {
    const s = await start();
    const { token } = await h.login("late@example.com");
    h.advance(600_000);
    const ap = await h.post("/v1/auth/device/approve", { userCode: s.userCode }, { token });
    expect(ap.status).toBe(410);
    const p = await h.post("/v1/auth/device/poll", { deviceCode: s.deviceCode });
    expect(p.status).toBe(410);
    expect(p.json.error).toBe("expired_token");
  });

  it("unknown device code → 410; approve requires a session; unknown user code → 404", async () => {
    expect((await h.post("/v1/auth/device/poll", { deviceCode: "nope" })).status).toBe(410);
    const s = await start();
    expect((await h.post("/v1/auth/device/approve", { userCode: s.userCode })).status).toBe(401);
    const { token } = await h.login("y@example.com");
    const r = await h.post("/v1/auth/device/approve", { userCode: "ZZZZ-ZZZZ" }, { token });
    expect(r.status).toBe(404);
    expect((await h.post("/v1/auth/device/approve", { userCode: "bad" }, { token })).status).toBe(404);
  });

  it("409 when another account already approved the code", async () => {
    const s = await start();
    const a = await h.login("a@example.com");
    const b = await h.login("b@example.com");
    expect((await h.post("/v1/auth/device/approve", { userCode: s.userCode }, { token: a.token })).status).toBe(200);
    expect((await h.post("/v1/auth/device/approve", { userCode: s.userCode }, { token: b.token })).status).toBe(409);
    expect((await h.post("/v1/auth/device/approve", { userCode: s.userCode }, { token: a.token })).status).toBe(200);
  });

  it("start is rate limited per IP (10/min, DEV_MODE off)", async () => {
    h = await Harness.create({ DEV_MODE: "false" });
    for (let i = 0; i < 10; i++) expect((await h.post("/v1/auth/device/start", { platform: "androidtv" })).status).toBe(200);
    expect((await h.post("/v1/auth/device/start", { platform: "androidtv" })).status).toBe(429);
  });
});

describe("GET/DELETE /v1/account", () => {
  it("returns id, email, createdAt, licenses and trial", async () => {
    const { token, accountId } = await h.login("acc@example.com");
    const empty = await h.get("/v1/account", { token });
    expect(empty.status).toBe(200);
    expect(empty.json).toMatchObject({ id: accountId, email: "acc@example.com", createdAt: T0, licenses: [], trial: null });

    const dk = await newDeviceKey("acc-android");
    h.stores.googlePurchases.set("acc-tok", { purchaseState: 0, acknowledgementState: 1, purchaseTimeMillis: String(T0 - 5000) });
    await h.licenseSync(
      { platform: "android", deviceKey: dk, startTrial: true, google: { purchases: [{ productId: "lifetime_access", purchaseToken: "acc-tok" }] } },
      token,
    );
    const r = await h.get("/v1/account", { token });
    expect(r.json.licenses).toEqual([{ store: "google", status: "active", purchasedAt: T0 - 5000, productId: "lifetime_access" }]);
    const s = Math.floor(T0 / 1000);
    expect(r.json.trial).toEqual({ start: s, end: s + 7 * 86_400 });
    // no store references / tokens leak to the client
    expect(r.text).not.toContain("acc-tok");
  });

  it("DELETE removes account, sessions, sync items and trial; licenses are detached but kept", async () => {
    const { token, accountId } = await h.login("del@example.com");
    const second = await h.login("del@example.com", "second device");
    const ios = await newDeviceKey("del-ios");
    h.stores.appleTx.set("4000000001", { env: "Production", payload: appleTxPayload({ transactionId: "4000000001", productId: "de.hasielektronik.novaplayer.lifetime" }) });
    await h.licenseSync({ platform: "ios", deviceKey: ios, apple: { transactionIds: ["4000000001"] } }, token);
    await h.post("/v1/sync", { items: [{ key: "fav:abc:live:1", kind: "favorite", data: { title: "X", contentKind: "live" }, updatedAt: T0, deleted: false }] }, { token });

    const r = await h.del("/v1/account", { token });
    expect(r.status).toBe(200);
    expect(r.json).toEqual({ ok: true });
    expect((await h.get("/v1/account", { token: second.token })).status).toBe(401);

    const db = env.DB;
    const n = async (sql: string) => (await db.prepare(sql).bind(accountId).first<{ n: number }>())!.n;
    expect(await n("SELECT COUNT(*) AS n FROM accounts WHERE id = ?1")).toBe(0);
    expect(await n("SELECT COUNT(*) AS n FROM sessions WHERE account_id = ?1")).toBe(0);
    expect(await n("SELECT COUNT(*) AS n FROM sync_items WHERE account_id = ?1")).toBe(0);
    expect(await n("SELECT COUNT(*) AS n FROM account_trials WHERE account_id = ?1")).toBe(0);
    expect(await n("SELECT COUNT(*) AS n FROM devices WHERE account_id = ?1")).toBe(0);
    const lic = await db.prepare("SELECT status, account_id FROM licenses").first<{ status: string; account_id: string | null }>();
    expect(lic).toEqual({ status: "active", account_id: null });

    // The device itself keeps its store purchase.
    expect((await h.licenseSync({ platform: "ios", deviceKey: ios })).json.license).toMatchObject({ purchased: true, src: "apple", acct: null });
    // Signing up again creates a fresh account.
    const again = await h.login("del@example.com");
    expect(again.accountId).not.toBe(accountId);
  });

  it("401 without session", async () => {
    expect((await h.del("/v1/account")).status).toBe(401);
  });

  it("account trial is visible after a sliding-session refresh", async () => {
    const { token } = await h.login("t@example.com");
    h.advance(2 * DAY);
    await h.licenseSync({ platform: "android", deviceKey: await newDeviceKey("t"), startTrial: true }, token);
    expect((await h.get("/v1/account", { token })).json.trial).not.toBeNull();
  });
});
