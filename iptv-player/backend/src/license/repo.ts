import { randomId } from "../crypto";
import type { Ctx } from "../http";
import type { AppleTransaction } from "../stores/apple";
import type { GooglePlayClient } from "../stores/google";
import type { Trial } from "./trial";

export type Store = "google" | "apple" | "admin";

export interface LicenseRow {
  id: string;
  store: Store;
  store_ref: string;
  order_id: string | null;
  product_id: string;
  status: "active" | "revoked";
  purchased_at: number | null;
  revoked_at: number | null;
  revoke_reason: string | null;
  device_key: string | null;
  account_id: string | null;
  note: string | null;
  created_at: number;
}

export interface Link {
  deviceKey?: string | null;
  accountId?: string | null;
}

export async function findLicense(c: Ctx, store: Store, storeRef: string): Promise<LicenseRow | null> {
  return c.env.DB.prepare("SELECT * FROM licenses WHERE store = ?1 AND store_ref = ?2")
    .bind(store, storeRef)
    .first<LicenseRow>();
}

export async function linkLicense(c: Ctx, licenseId: string, link: Link): Promise<void> {
  const now = c.deps.now();
  const stmts: D1PreparedStatement[] = [];
  if (link.deviceKey) {
    stmts.push(
      c.env.DB.prepare("INSERT OR IGNORE INTO license_devices (license_id, device_key, created_at) VALUES (?1, ?2, ?3)").bind(
        licenseId,
        link.deviceKey,
        now,
      ),
    );
  }
  if (link.accountId) {
    // A license belongs to the first account that presents it (no hopping between accounts).
    stmts.push(
      c.env.DB.prepare("UPDATE licenses SET account_id = ?2, updated_at = ?3 WHERE id = ?1 AND account_id IS NULL").bind(
        licenseId,
        link.accountId,
        now,
      ),
    );
  }
  if (stmts.length) await c.env.DB.batch(stmts);
}

export async function revokeLicense(c: Ctx, id: string, reason: "store" | "admin"): Promise<boolean> {
  const now = c.deps.now();
  const r = await c.env.DB.prepare(
    "UPDATE licenses SET status = 'revoked', revoked_at = ?2, revoke_reason = ?3, updated_at = ?2 WHERE id = ?1 AND status = 'active'",
  )
    .bind(id, now, reason)
    .run();
  const changed = (r.meta.changes ?? 0) > 0;
  if (changed) c.log.info("license.revoked", { license: id, reason });
  return changed;
}

export async function restoreLicense(c: Ctx, id: string): Promise<boolean> {
  const r = await c.env.DB.prepare(
    "UPDATE licenses SET status = 'active', revoked_at = NULL, revoke_reason = NULL, updated_at = ?2 WHERE id = ?1 AND status = 'revoked'",
  )
    .bind(id, c.deps.now())
    .run();
  const changed = (r.meta.changes ?? 0) > 0;
  if (changed) c.log.info("license.restored", { license: id });
  return changed;
}

interface StoreVerdict {
  store: "google" | "apple";
  storeRef: string;
  orderId: string | null;
  productId: string;
  purchasedAt: number | null;
  /** The store's current verdict (verified by re-query). */
  active: boolean;
  /** May an active verdict undo an earlier *store* revocation? (admin revocations are sticky) */
  allowRestore: boolean;
  rawState: Record<string, unknown>;
}

/** Applies a verified store verdict: insert/update the license, transition status, link. */
export async function applyStoreVerdict(c: Ctx, v: StoreVerdict, link: Link): Promise<LicenseRow | null> {
  const now = c.deps.now();
  let row = await findLicense(c, v.store, v.storeRef);
  if (!row) {
    if (!v.active) return null; // nothing to track for purchases that were never valid here
    await c.env.DB.prepare(
      "INSERT INTO licenses (id, store, store_ref, order_id, product_id, status, purchased_at, device_key, account_id, raw_state, created_at, updated_at) " +
        "VALUES (?1, ?2, ?3, ?4, ?5, 'active', ?6, ?7, ?8, ?9, ?10, ?10) ON CONFLICT(store, store_ref) DO NOTHING",
    )
      .bind(
        randomId("lic_"),
        v.store,
        v.storeRef,
        v.orderId,
        v.productId,
        v.purchasedAt,
        link.deviceKey ?? null,
        link.accountId ?? null,
        JSON.stringify(v.rawState),
        now,
      )
      .run();
    row = await findLicense(c, v.store, v.storeRef);
    if (!row) return null;
    c.log.info("license.created", { license: row.id, store: v.store });
  } else {
    await c.env.DB.prepare(
      "UPDATE licenses SET order_id = COALESCE(?2, order_id), purchased_at = COALESCE(purchased_at, ?3), " +
        "device_key = COALESCE(device_key, ?4), raw_state = ?5, updated_at = ?6 WHERE id = ?1",
    )
      .bind(row.id, v.orderId, v.purchasedAt, link.deviceKey ?? null, JSON.stringify(v.rawState), now)
      .run();
  }
  if (!v.active && row.status === "active") {
    await revokeLicense(c, row.id, "store");
    row.status = "revoked";
  } else if (v.active && row.status === "revoked" && row.revoke_reason === "store" && v.allowRestore) {
    await restoreLicense(c, row.id);
    row.status = "active";
  }
  await linkLicense(c, row.id, link);
  return row;
}

// ---------------- Google ----------------

export type GoogleOutcome =
  | { status: "active"; license: LicenseRow }
  | { status: "revoked"; license: LicenseRow | null }
  | { status: "pending" | "canceled" | "invalid" | "unavailable" | "unknown_product" };

/** Verifies a Play purchase token with purchases.products.get and applies the result. */
export async function verifyGooglePurchase(
  c: Ctx,
  gp: GooglePlayClient,
  productId: string,
  purchaseToken: string,
  link: Link,
): Promise<GoogleOutcome> {
  if (productId !== c.env.GOOGLE_PRODUCT_ID) return { status: "unknown_product" };
  const r = await gp.getProductPurchase(productId, purchaseToken);
  if (!r.ok) return { status: r.kind === "invalid" ? "invalid" : "unavailable" };
  const p = r.data;
  const state = p.purchaseState ?? 0;
  if (state === 2) return { status: "pending" };
  const verdict: StoreVerdict = {
    store: "google",
    storeRef: purchaseToken,
    orderId: p.orderId ?? null,
    productId,
    purchasedAt: p.purchaseTimeMillis ? Number(p.purchaseTimeMillis) : null,
    active: state === 0,
    // Google voids are final; a stale products.get must not undo a voided-purchase revocation.
    allowRestore: false,
    rawState: {
      purchaseState: state,
      acknowledgementState: p.acknowledgementState ?? 0,
      consumptionState: p.consumptionState ?? 0,
      purchaseType: p.purchaseType ?? null,
      verifiedAt: c.deps.now(),
    },
  };
  const license = await applyStoreVerdict(c, verdict, link);
  if (state !== 0) return license ? { status: "revoked", license } : { status: "canceled" };
  if ((p.acknowledgementState ?? 0) === 0) await gp.acknowledge(productId, purchaseToken);
  return license ? (license.status === "active" ? { status: "active", license } : { status: "revoked", license }) : { status: "invalid" };
}

// ---------------- Apple ----------------

export type AppleOutcome =
  | { kind: "license"; license: LicenseRow | null; active: boolean }
  | { kind: "trial"; trial: Trial | null }
  | { kind: "bundle_mismatch" }
  | { kind: "unknown_product" };

/** Applies a transaction re-fetched from the App Store Server API. */
export async function applyAppleTransaction(
  c: Ctx,
  tx: AppleTransaction,
  link: Link,
  trialDays: number,
): Promise<AppleOutcome> {
  if (tx.bundleId !== c.env.APPLE_BUNDLE_ID) return { kind: "bundle_mismatch" };
  const revoked = tx.revocationDate !== undefined;
  if (tx.productId === c.env.APPLE_PRODUCT_ID) {
    const license = await applyStoreVerdict(
      c,
      {
        store: "apple",
        storeRef: tx.originalTransactionId,
        orderId: tx.transactionId,
        productId: tx.productId,
        purchasedAt: tx.originalPurchaseDate ?? tx.purchaseDate,
        active: !revoked,
        allowRestore: true, // REFUND_REVERSED clears revocationDate
        rawState: {
          environment: tx.environment ?? null,
          type: tx.type ?? null,
          inAppOwnershipType: tx.inAppOwnershipType ?? null,
          revoked,
          revocationReason: tx.revocationReason ?? null,
          verifiedAt: c.deps.now(),
        },
      },
      link,
    );
    return { kind: "license", license, active: !!license && license.status === "active" };
  }
  if (tx.productId === c.env.APPLE_TRIAL_PRODUCT_ID) {
    if (revoked) {
      await c.env.DB.prepare("UPDATE apple_trials SET revoked = 1 WHERE original_transaction_id = ?1")
        .bind(tx.originalTransactionId)
        .run();
      return { kind: "trial", trial: null };
    }
    // trialStart = purchaseDate of the trial transaction (earliest known), snapshot of trial_days.
    const startMs = Math.min(tx.purchaseDate, tx.originalPurchaseDate ?? tx.purchaseDate);
    const start = Math.floor(startMs / 1000);
    await c.env.DB.prepare(
      "INSERT OR IGNORE INTO apple_trials (original_transaction_id, trial_start, trial_end, revoked, created_at) VALUES (?1, ?2, ?3, 0, ?4)",
    )
      .bind(tx.originalTransactionId, start, start + trialDays * 86_400, c.deps.now())
      .run();
    const row = await c.env.DB.prepare(
      "SELECT trial_start, trial_end, revoked FROM apple_trials WHERE original_transaction_id = ?1",
    )
      .bind(tx.originalTransactionId)
      .first<{ trial_start: number; trial_end: number; revoked: number }>();
    if (!row || row.revoked) return { kind: "trial", trial: null };
    return { kind: "trial", trial: { start: row.trial_start, end: row.trial_end, source: "apple" } };
  }
  return { kind: "unknown_product" };
}
