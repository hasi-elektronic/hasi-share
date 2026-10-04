import { optionalSession } from "../auth/session";
import { getConfig } from "../config";
import { appIds } from "../env";
import {
  HttpError,
  badRequest,
  json,
  optBool,
  optObject,
  optString,
  readJsonObject,
  reqString,
  type Ctx,
} from "../http";
import { rateLimit } from "../ratelimit";
import { AppStoreClient } from "../stores/apple";
import { GooglePlayClient } from "../stores/google";
import { applyAppleTransaction, verifyGooglePurchase, type Store } from "./repo";
import { buildPayload, signLicenseToken, type LicenseClaims, type LicenseSrc } from "./token";
import {
  earliest,
  getAccountTrial,
  getDeviceTrial,
  sameTrial,
  setAccountTrial,
  setDeviceTrial,
  startDeviceTrialOnce,
  type Trial,
} from "./trial";

const PLATFORMS = ["android", "androidtv", "ios", "tvos"] as const;
type Platform = (typeof PLATFORMS)[number];
export const DEVICE_KEY_RE = /^[0-9a-f]{64}$/;
const TX_ID_RE = /^[0-9]{1,32}$/;
const MAX_GOOGLE_PURCHASES = 10;
const MAX_APPLE_TRANSACTIONS = 20;

export function storeFamily(p: Platform): "google" | "apple" {
  return p === "android" || p === "androidtv" ? "google" : "apple";
}

interface Detail {
  store: "google" | "apple";
  error: string;
  index?: number;
  productId?: string;
  transactionId?: string;
}

interface ParsedRequest {
  platform: Platform;
  appId: string;
  appVersion: string | null;
  deviceKey: string;
  startTrial: boolean;
  googlePurchases: { productId: string; purchaseToken: string }[];
  appleIds: string[];
}

function parseRequest(c: Ctx, body: Record<string, unknown>): ParsedRequest {
  const platform = reqString(body, "platform", { max: 20 }) as Platform;
  if (!PLATFORMS.includes(platform)) throw badRequest("Unknown platform.");
  const appId = reqString(body, "appId", { max: 200 });
  if (!appIds(c.env).includes(appId)) throw badRequest("Unknown appId.");
  const appVersion = optString(body, "appVersion", { max: 64 }) ?? null;
  const deviceKey = reqString(body, "deviceKey", { max: 64 }).toLowerCase();
  if (!DEVICE_KEY_RE.test(deviceKey)) throw badRequest("'deviceKey' must be 64 hex characters.");
  const startTrial = optBool(body, "startTrial") ?? false;

  const googlePurchases: ParsedRequest["googlePurchases"] = [];
  const google = optObject(body, "google");
  if (google && google.purchases !== undefined && google.purchases !== null) {
    if (!Array.isArray(google.purchases)) throw badRequest("'google.purchases' must be an array.");
    if (google.purchases.length > MAX_GOOGLE_PURCHASES) throw badRequest("Too many Google purchases.");
    for (const p of google.purchases as unknown[]) {
      if (!p || typeof p !== "object") throw badRequest("Invalid Google purchase entry.");
      const o = p as Record<string, unknown>;
      googlePurchases.push({
        productId: reqString(o, "productId", { max: 200 }),
        purchaseToken: reqString(o, "purchaseToken", { max: 4096 }),
      });
    }
  }

  const appleIds: string[] = [];
  const apple = optObject(body, "apple");
  if (apple) {
    const push = (v: unknown, field: string) => {
      const s = typeof v === "number" ? String(v) : v;
      if (typeof s !== "string" || !TX_ID_RE.test(s)) throw badRequest(`Invalid Apple transaction id in '${field}'.`);
      if (!appleIds.includes(s)) appleIds.push(s);
    };
    if (apple.trialTransactionId !== undefined && apple.trialTransactionId !== null) {
      push(apple.trialTransactionId, "apple.trialTransactionId");
    }
    if (apple.transactionIds !== undefined && apple.transactionIds !== null) {
      if (!Array.isArray(apple.transactionIds)) throw badRequest("'apple.transactionIds' must be an array.");
      for (const id of apple.transactionIds as unknown[]) push(id, "apple.transactionIds");
    }
    if (appleIds.length > MAX_APPLE_TRANSACTIONS) throw badRequest("Too many Apple transactions.");
  }

  const family = storeFamily(platform);
  if (googlePurchases.length && family !== "google") throw badRequest("Google purchases are only accepted from Android devices.");
  if (appleIds.length && family !== "apple") throw badRequest("Apple transactions are only accepted from Apple devices.");
  return { platform, appId, appVersion, deviceKey, startTrial, googlePurchases, appleIds };
}

/**
 * `purchased` = any active license linked to this device, or (with a valid session) to
 * its account. Device licenses report their store; account-only licenses report "account"
 * (or "admin" when every account license is an admin grant).
 */
export async function computePurchase(
  c: Ctx,
  deviceKey: string,
  accountId: string | null,
  family: "google" | "apple",
): Promise<{ purchased: boolean; src: LicenseSrc }> {
  const { results: direct } = await c.env.DB.prepare(
    "SELECT l.store FROM licenses l JOIN license_devices d ON d.license_id = l.id " +
      "WHERE d.device_key = ?1 AND l.status = 'active'",
  )
    .bind(deviceKey)
    .all<{ store: Store }>();
  if (direct.length > 0) {
    const stores = direct.map((r) => r.store);
    const src: LicenseSrc = stores.includes(family) ? family : stores.includes("admin") ? "admin" : stores[0]!;
    return { purchased: true, src };
  }
  if (accountId) {
    const { results: acct } = await c.env.DB.prepare(
      "SELECT store FROM licenses WHERE account_id = ?1 AND status = 'active'",
    )
      .bind(accountId)
      .all<{ store: Store }>();
    if (acct.length > 0) {
      return { purchased: true, src: acct.every((r) => r.store === "admin") ? "admin" : "account" };
    }
  }
  return { purchased: false, src: null };
}

/** POST /v1/license/sync */
export async function licenseSync(c: Ctx): Promise<Response> {
  const body = await readJsonObject(c.req, 64 * 1024);
  const req = parseRequest(c, body);
  await rateLimit(c, "license_sync", req.deviceKey, 30, 60);

  const signingKey = c.env.LICENSE_SIGNING_KEY;
  if (!signingKey) throw new HttpError(500, "server_misconfigured", "License signing key is not configured.");

  const session = await optionalSession(c);
  const accountId = session?.accountId ?? null;
  const cfg = await getConfig(c.env);
  const now = c.deps.now();
  const nowSec = Math.floor(now / 1000);
  const family = storeFamily(req.platform);
  const log = c.log.child({ device: req.deviceKey.slice(0, 8) });

  // 1. Device upsert (+ account link when signed in).
  await c.env.DB.prepare(
    "INSERT INTO devices (device_key, platform, app_id, app_version, account_id, created_at, last_seen_at) " +
      "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6) ON CONFLICT(device_key) DO UPDATE SET platform = excluded.platform, " +
      "app_id = excluded.app_id, app_version = excluded.app_version, " +
      "account_id = COALESCE(excluded.account_id, devices.account_id), last_seen_at = excluded.last_seen_at",
  )
    .bind(req.deviceKey, req.platform, req.appId, req.appVersion, accountId, now)
    .run();

  const link = { deviceKey: req.deviceKey, accountId };
  const details: Detail[] = [];
  let unavailable = false;

  // 2. Google purchases.
  if (req.googlePurchases.length > 0) {
    const gp = new GooglePlayClient(c);
    for (const [index, p] of req.googlePurchases.entries()) {
      const out = await verifyGooglePurchase(c, gp, p.productId, p.purchaseToken, link);
      const d = (error: string) => details.push({ store: "google", index, productId: p.productId, error });
      switch (out.status) {
        case "active":
        case "pending": // pending purchases are ignored (no access until PURCHASED)
          break;
        case "invalid":
          d("invalid_purchase_token");
          break;
        case "unknown_product":
          d("unknown_product");
          break;
        case "canceled":
          d("purchase_canceled");
          break;
        case "revoked":
          d("purchase_revoked");
          break;
        case "unavailable":
          unavailable = true;
          d("store_unavailable");
          break;
      }
    }
  }

  // 3. Apple transactions (lifetime and trial marker).
  let appleTrial: Trial | null = null;
  if (req.appleIds.length > 0) {
    const ap = new AppStoreClient(c);
    for (const id of req.appleIds) {
      const d = (error: string) => details.push({ store: "apple", transactionId: id, error });
      const r = await ap.getTransaction(id);
      if (!r.ok) {
        if (r.kind === "unavailable") {
          unavailable = true;
          d("store_unavailable");
        } else d("invalid_transaction");
        continue;
      }
      const out = await applyAppleTransaction(c, r.tx, link, cfg.trialDays);
      if (out.kind === "bundle_mismatch") d("bundle_mismatch");
      else if (out.kind === "unknown_product") d("unknown_product");
      else if (out.kind === "license" && !out.active) d("purchase_revoked");
      else if (out.kind === "trial") appleTrial = earliest(out.trial, appleTrial);
    }
  }

  // 4. Trial.
  let devTrial = await getDeviceTrial(c, req.deviceKey);
  if (appleTrial) {
    const m = earliest(appleTrial, devTrial);
    if (m && !sameTrial(m, devTrial)) {
      await setDeviceTrial(c, req.deviceKey, m);
      devTrial = m;
    }
  }
  const accTrial = accountId ? await getAccountTrial(c, accountId) : null;
  if (req.startTrial && family === "google" && !devTrial) {
    // Snapshot: trial_end = start + trial_days as configured *now*. A signed-in device of an
    // account that already had a trial inherits that trial instead of starting a new one.
    const t: Trial = accTrial ?? { start: nowSec, end: nowSec + cfg.trialDays * 86_400, source: "server" };
    await startDeviceTrialOnce(c, req.deviceKey, t);
    devTrial = await getDeviceTrial(c, req.deviceKey);
    log.info("trial.started", { source: t.source });
  }
  let effective = devTrial;
  if (accountId) {
    // Earliest trial across the account applies; persist it on both sides.
    const merged = earliest(devTrial, accTrial);
    if (merged) {
      if (!sameTrial(merged, accTrial)) await setAccountTrial(c, accountId, merged);
      if (!sameTrial(merged, devTrial)) await setDeviceTrial(c, req.deviceKey, merged);
    }
    effective = merged;
  }

  // 5. Purchase state.
  const purchase = await computePurchase(c, req.deviceKey, accountId, family);

  // 6. Signed license token.
  const lic: LicenseClaims = {
    purchased: purchase.purchased,
    src: purchase.src,
    trialStart: effective?.start ?? null,
    trialEnd: effective?.end ?? null,
    acct: accountId,
  };
  const token = await signLicenseToken(buildPayload(req.appId, req.deviceKey, nowSec, lic), signingKey, c.env.LICENSE_KID);
  const result = { token, license: lic, serverTime: now };

  if (unavailable) {
    return json(
      { error: "store_unavailable", message: "A store could not be reached. Try again later.", details, ...result },
      503,
      { "retry-after": "60" },
    );
  }
  if (details.length > 0) {
    log.info("license.verification_failed", { count: details.length });
    return json(
      { error: "store_verification_failed", message: "Some purchases could not be verified.", details, ...result },
      422,
    );
  }
  return json(result);
}
