import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { DAY, Harness, T0, newDeviceKey, resetDb } from "./helpers";

let h: Harness;
beforeEach(async () => {
  await resetDb();
  h = await Harness.create();
});

async function buy(token: string, seed: string) {
  h.stores.googlePurchases.set(token, { purchaseState: 0, acknowledgementState: 1 });
  const dk = await newDeviceKey(seed);
  await h.licenseSync({ platform: "android", deviceKey: dk, google: { purchases: [{ productId: "lifetime_access", purchaseToken: token }] } });
  return dk;
}

const count = async (table: string) => (await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>())!.n;

describe("scheduled() – daily cron", () => {
  it("polls Google Voided Purchases (last 30 days, one-time products) and revokes matches", async () => {
    const a = await buy("void-a", "a");
    const b = await buy("void-b", "b");
    h.stores.googleVoided.push({ purchaseToken: "void-a", orderId: "GPA.A", voidedTimeMillis: String(T0) });
    h.stores.googleVoided.push({ purchaseToken: "unknown-token" });
    h.stores.calls = [];
    await h.runCron();

    const call = h.stores.calls.find((c) => c.url.includes("/voidedpurchases"))!;
    const q = new URL(call.url).searchParams;
    expect(q.get("type")).toBe("0");
    const start = Number(q.get("startTime"));
    expect(start).toBeGreaterThanOrEqual(T0 - 30 * DAY);
    expect(start).toBeLessThan(T0 - 29 * DAY);

    expect((await h.licenseSync({ platform: "android", deviceKey: a })).json.license.purchased).toBe(false);
    expect((await h.licenseSync({ platform: "android", deviceKey: b })).json.license.purchased).toBe(true);
    expect(h.logs.some((l) => l.includes('"msg":"cron.done"') && l.includes('"revoked":1') && l.includes('"voided":2'))).toBe(true);
  });

  it("follows Voided Purchases pagination", async () => {
    await buy("page-2-token", "p");
    const orig = h.stores.fetch;
    let page = 0;
    h.worker = (await import("../src/app")).createWorker({
      now: () => h.now,
      logSink: (_l, line) => h.logs.push(line),
      fetch: async (input, init) => {
        const url = new URL(new Request(input as RequestInfo, init).url);
        if (url.pathname.endsWith("/voidedpurchases")) {
          page++;
          if (!url.searchParams.get("token")) {
            return Response.json({ voidedPurchases: [{ purchaseToken: "x" }], tokenPagination: { nextPageToken: "P2" } });
          }
          expect(url.searchParams.get("token")).toBe("P2");
          return Response.json({ voidedPurchases: [{ purchaseToken: "page-2-token" }] });
        }
        return orig(input, init);
      },
    });
    await h.runCron();
    expect(page).toBe(2);
    const row = await env.DB.prepare("SELECT status FROM licenses WHERE store_ref = 'page-2-token'").first<{ status: string }>();
    expect(row?.status).toBe("revoked");
  });

  it("Google outage → no revocations, housekeeping still runs", async () => {
    await buy("tok", "x");
    h.stores.googleDown = true;
    await env.DB.prepare("INSERT INTO rate_limits (bucket, count, window_start) VALUES ('old', 1, ?1)").bind(T0 - 2 * DAY).run();
    await h.runCron();
    expect((await env.DB.prepare("SELECT status FROM licenses").first<{ status: string }>())?.status).toBe("active");
    expect(await env.DB.prepare("SELECT 1 AS x FROM rate_limits WHERE bucket = 'old'").first()).toBeNull();
    expect(await count("rate_limits")).toBe(1); // the current window of the sync above stays
  });

  it("without a Google service account only housekeeping runs (no outbound calls)", async () => {
    h = await Harness.create({ GOOGLE_SERVICE_ACCOUNT_JSON: undefined });
    await h.runCron();
    expect(h.stores.calls).toHaveLength(0);
    expect(h.logs.some((l) => l.includes("cron.google_not_configured"))).toBe(true);
  });

  it("housekeeping deletes expired codes, sessions, pairing sessions, rate limits and old tombstones only", async () => {
    const db = env.DB;
    const now = T0;
    await db.batch([
      db.prepare("INSERT INTO email_codes VALUES ('e-old', 'h', 0, 0, ?1)").bind(now - 2 * 3_600_000),
      db.prepare("INSERT INTO email_codes VALUES ('e-new', 'h', 0, 0, ?1)").bind(now + 60_000),
      db.prepare("INSERT INTO device_codes (device_code_hash, user_code, platform, created_at, expires_at) VALUES ('d-old', 'AAAAAAAA', 'tvos', 0, ?1)").bind(now - 2 * 3_600_000),
      db.prepare("INSERT INTO device_codes (device_code_hash, user_code, platform, created_at, expires_at) VALUES ('d-new', 'BBBBBBBB', 'tvos', 0, ?1)").bind(now + 60_000),
      db.prepare("INSERT INTO pair_sessions VALUES ('OLD111', 's', '{}', NULL, 0, ?1)").bind(now - 2 * DAY),
      db.prepare("INSERT INTO pair_sessions VALUES ('RECENT', 's', '{}', NULL, 0, ?1)").bind(now - 3_600_000),
      db.prepare("INSERT INTO sessions VALUES ('s-old', 'acc', NULL, 0, ?1, 0)").bind(now - 1),
      db.prepare("INSERT INTO sessions VALUES ('s-new', 'acc', NULL, 0, ?1, 0)").bind(now + DAY),
      db.prepare("INSERT INTO rate_limits VALUES ('r-old', 1, ?1)").bind(now - 2 * DAY),
      db.prepare("INSERT INTO rate_limits VALUES ('r-new', 1, ?1)").bind(now),
      db.prepare("INSERT INTO sync_items VALUES ('acc', 'fav:old', 'favorite', '{}', ?1, 1, 1)").bind(now - 181 * DAY),
      db.prepare("INSERT INTO sync_items VALUES ('acc', 'fav:recent', 'favorite', '{}', ?1, 1, 2)").bind(now - 10 * DAY),
      db.prepare("INSERT INTO sync_items VALUES ('acc', 'fav:live', 'favorite', '{}', ?1, 0, 3)").bind(now - 400 * DAY),
    ]);
    await h.runCron();
    const keys = async (sql: string) => (await db.prepare(sql).all<{ k: string }>()).results.map((r) => r.k).sort();
    expect(await keys("SELECT email_hash AS k FROM email_codes")).toEqual(["e-new"]);
    expect(await keys("SELECT device_code_hash AS k FROM device_codes")).toEqual(["d-new"]);
    expect(await keys("SELECT code AS k FROM pair_sessions")).toEqual(["RECENT"]);
    expect(await keys("SELECT token_hash AS k FROM sessions")).toEqual(["s-new"]);
    expect(await keys("SELECT bucket AS k FROM rate_limits")).toEqual(["r-new"]);
    expect(await keys("SELECT key AS k FROM sync_items")).toEqual(["fav:live", "fav:recent"]);
  });
});
