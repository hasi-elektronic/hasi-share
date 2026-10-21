import { getConfig } from "./config";
import { b64Decode, decodeJwsPayloadUnverified, fromUtf8, timingSafeEqualStr } from "./crypto";
import { HttpError, json, noContent, readJsonObject, type Ctx } from "./http";
import { applyAppleTransaction, findLicense, revokeLicense, verifyGooglePurchase } from "./license/repo";
import { AppStoreClient, parseTransactionPayload } from "./stores/apple";
import { GooglePlayClient } from "./stores/google";

const DAY_MS = 86_400_000;

// ---------------- Google Play RTDN (Pub/Sub push) ----------------

interface DeveloperNotification {
  packageName?: string;
  eventTimeMillis?: string;
  oneTimeProductNotification?: { notificationType?: number; purchaseToken?: string; sku?: string };
  voidedPurchaseNotification?: { purchaseToken?: string; orderId?: string; productType?: number; refundType?: number };
  testNotification?: unknown;
}

/**
 * POST /v1/webhooks/google?token=… – always 204 (Pub/Sub must not retry) except 401 for a
 * wrong token. State only changes after re-querying Google.
 */
export async function googleWebhook(c: Ctx): Promise<Response> {
  const expected = c.env.GOOGLE_PUBSUB_TOKEN;
  const token = c.url.searchParams.get("token") ?? "";
  if (!expected || !token || !(await timingSafeEqualStr(token, expected))) {
    throw new HttpError(401, "unauthorized", "Invalid push token.");
  }
  let n: DeveloperNotification;
  try {
    const body = await readJsonObject(c.req, 64 * 1024);
    const msg = body.message as { data?: unknown } | undefined;
    if (!msg || typeof msg.data !== "string") throw new Error("missing message.data");
    n = JSON.parse(fromUtf8(b64Decode(msg.data))) as DeveloperNotification;
  } catch (e) {
    c.log.warn("rtdn.malformed", { err: e instanceof Error ? e.message : String(e) });
    return noContent();
  }
  if (n.packageName !== c.env.GOOGLE_PACKAGE_NAME) {
    c.log.warn("rtdn.wrong_package");
    return noContent();
  }
  const gp = new GooglePlayClient(c);
  try {
    if (n.oneTimeProductNotification) {
      const o = n.oneTimeProductNotification;
      c.log.info("rtdn.one_time", { type: o.notificationType ?? null });
      if (o.purchaseToken && o.sku && (o.notificationType === 1 || o.notificationType === 2)) {
        // PURCHASED: record + acknowledge server-side. CANCELED: re-query revokes if needed.
        const out = await verifyGooglePurchase(c, gp, o.sku, o.purchaseToken, {});
        c.log.info("rtdn.one_time_result", { status: out.status });
      }
    } else if (n.voidedPurchaseNotification) {
      const v = n.voidedPurchaseNotification;
      c.log.info("rtdn.voided", { productType: v.productType ?? null, refundType: v.refundType ?? null });
      if (v.purchaseToken) await handleGoogleVoided(c, gp, v.purchaseToken, Number(n.eventTimeMillis) || c.deps.now());
    } else if (n.testNotification) {
      c.log.info("rtdn.test");
    }
  } catch (e) {
    c.log.error("rtdn.error", { err: e instanceof Error ? e.message : String(e) });
  }
  return noContent();
}

/** Revokes a voided Google purchase after confirming it with Google. */
export async function handleGoogleVoided(c: Ctx, gp: GooglePlayClient, purchaseToken: string, eventTimeMs: number): Promise<void> {
  const lic = await findLicense(c, "google", purchaseToken);
  if (!lic) {
    c.log.info("rtdn.voided_unknown_license");
    return;
  }
  if (lic.status !== "active") return;
  const r = await gp.getProductPurchase(lic.product_id, purchaseToken);
  if ((r.ok && (r.data.purchaseState ?? 0) !== 0) || (!r.ok && r.kind === "invalid")) {
    await revokeLicense(c, lic.id, "store");
    return;
  }
  if (!r.ok) {
    c.log.warn("rtdn.voided_unconfirmed", { license: lic.id, reason: "store_unavailable" });
    return;
  }
  // products.get still says PURCHASED: confirm with the Voided Purchases API.
  const since = Math.max(c.deps.now() - 30 * DAY_MS + 60_000, eventTimeMs - 3 * DAY_MS);
  const voided = await gp.listVoided(since, 5);
  if (voided?.some((v) => v.purchaseToken === purchaseToken)) {
    await revokeLicense(c, lic.id, "store");
  } else {
    c.log.warn("rtdn.voided_unconfirmed", { license: lic.id, reason: "not_in_voided_list" });
  }
}

// ---------------- App Store Server Notifications V2 ----------------

const APPLE_STATE_TYPES = new Set(["REFUND", "REVOKE", "REFUND_REVERSED", "ONE_TIME_CHARGE", "REFUND_DECLINED"]);

/**
 * POST /v1/webhooks/apple {signedPayload}. The payload is only decoded; the referenced
 * transaction is re-fetched from Apple and its state applied (trust by re-query).
 * Returns 200, or 503 if Apple could not be reached (Apple then retries).
 */
export async function appleWebhook(c: Ctx): Promise<Response> {
  const body = await readJsonObject(c.req, 64 * 1024);
  const signed = typeof body.signedPayload === "string" ? body.signedPayload : "";
  const payload = decodeJwsPayloadUnverified(signed);
  if (!payload) throw new HttpError(400, "invalid_request", "Invalid signedPayload.");
  const type = typeof payload.notificationType === "string" ? payload.notificationType : "";
  const data = (payload.data && typeof payload.data === "object" ? payload.data : {}) as Record<string, unknown>;
  c.log.info("assn.received", { type, subtype: payload.subtype ?? null, env: data.environment ?? null });

  if (typeof data.bundleId === "string" && data.bundleId !== c.env.APPLE_BUNDLE_ID) {
    c.log.warn("assn.wrong_bundle");
    return json({ ok: true });
  }
  if (!APPLE_STATE_TYPES.has(type)) return json({ ok: true }); // CONSUMPTION_REQUEST, TEST, … → no-op

  const hint = parseTransactionPayload(
    typeof data.signedTransactionInfo === "string" ? decodeJwsPayloadUnverified(data.signedTransactionInfo) : null,
  );
  if (!hint) {
    c.log.warn("assn.no_transaction");
    return json({ ok: true });
  }
  const ap = new AppStoreClient(c);
  const r = await ap.getTransaction(hint.transactionId, typeof data.environment === "string" ? data.environment : undefined);
  if (!r.ok) {
    if (r.kind === "unavailable") {
      throw new HttpError(503, "store_unavailable", "App Store Server API unavailable; retry later.");
    }
    c.log.warn("assn.transaction_not_found");
    return json({ ok: true });
  }
  const tx = r.tx;
  if ((type === "REFUND" || type === "REVOKE") && tx.revocationDate === undefined) {
    c.log.warn("assn.revocation_not_confirmed", { type });
  }
  const cfg = await getConfig(c.env);
  const out = await applyAppleTransaction(c, tx, {}, cfg.trialDays);
  c.log.info("assn.applied", {
    type,
    kind: out.kind,
    license: out.kind === "license" ? (out.license?.id ?? null) : null,
    active: out.kind === "license" ? out.active : null,
  });
  return json({ ok: true });
}
