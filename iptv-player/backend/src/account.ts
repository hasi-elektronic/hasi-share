import { requireSession } from "./auth/session";
import { json, type Ctx } from "./http";

/** POST /v1/auth/logout (session) */
export async function logout(c: Ctx): Promise<Response> {
  const s = await requireSession(c);
  await c.env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?1").bind(s.tokenHash).run();
  return json({ ok: true });
}

/** GET /v1/account (session) */
export async function getAccount(c: Ctx): Promise<Response> {
  const s = await requireSession(c);
  const acc = await c.env.DB.prepare("SELECT id, email, created_at FROM accounts WHERE id = ?1")
    .bind(s.accountId)
    .first<{ id: string; email: string; created_at: number }>();
  const { results: lic } = await c.env.DB.prepare(
    "SELECT store, status, purchased_at, product_id FROM licenses WHERE account_id = ?1 ORDER BY created_at",
  )
    .bind(s.accountId)
    .all<{ store: string; status: string; purchased_at: number | null; product_id: string }>();
  const trial = await c.env.DB.prepare("SELECT trial_start, trial_end FROM account_trials WHERE account_id = ?1")
    .bind(s.accountId)
    .first<{ trial_start: number; trial_end: number }>();
  return json({
    id: acc?.id ?? s.accountId,
    email: acc?.email ?? s.email,
    createdAt: acc?.created_at ?? null,
    licenses: lic.map((l) => ({
      store: l.store,
      status: l.status,
      purchasedAt: l.purchased_at,
      productId: l.product_id,
    })),
    // Epoch seconds, same values as the license token's trialStart / trialEnd.
    trial: trial ? { start: trial.trial_start, end: trial.trial_end } : null,
  });
}

/**
 * DELETE /v1/account (session) – Apple guideline 5.1.1(v).
 * Deletes the account, its sessions, sync data, pending codes and trial record.
 * Licenses are kept (store refund bookkeeping) but detached from the account.
 */
export async function deleteAccount(c: Ctx): Promise<Response> {
  const s = await requireSession(c);
  const id = s.accountId;
  const db = c.env.DB;
  await db.batch([
    db.prepare("DELETE FROM sessions WHERE account_id = ?1").bind(id),
    db.prepare("DELETE FROM sync_items WHERE account_id = ?1").bind(id),
    db.prepare("DELETE FROM device_codes WHERE account_id = ?1").bind(id),
    db.prepare("DELETE FROM account_trials WHERE account_id = ?1").bind(id),
    db.prepare("UPDATE licenses SET account_id = NULL, updated_at = ?2 WHERE account_id = ?1").bind(id, c.deps.now()),
    db.prepare("UPDATE devices SET account_id = NULL WHERE account_id = ?1").bind(id),
    db.prepare("DELETE FROM accounts WHERE id = ?1").bind(id),
  ]);
  c.log.info("account.deleted", { account: id });
  return json({ ok: true });
}
