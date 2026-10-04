import type { Ctx } from "./http";
import { revokeLicense } from "./license/repo";
import { GooglePlayClient } from "./stores/google";

const DAY_MS = 86_400_000;
const IN_CHUNK = 90;

/** Daily job: Google Voided Purchases poll (last 30 days) → revoke, then housekeeping. */
export async function runCron(c: Ctx): Promise<{ voided: number; revoked: number }> {
  let voided = 0;
  let revoked = 0;
  const gp = new GooglePlayClient(c);
  if (gp.configured) {
    // startTime must lie within the last 30 days.
    const list = await gp.listVoided(c.deps.now() - 30 * DAY_MS + 60_000);
    if (list) {
      voided = list.length;
      const tokens = [...new Set(list.map((v) => v.purchaseToken).filter((t): t is string => !!t))];
      for (let i = 0; i < tokens.length; i += IN_CHUNK) {
        const chunk = tokens.slice(i, i + IN_CHUNK);
        const ph = chunk.map((_, j) => `?${j + 1}`).join(",");
        const { results } = await c.env.DB.prepare(
          `SELECT id FROM licenses WHERE store = 'google' AND status = 'active' AND store_ref IN (${ph})`,
        )
          .bind(...chunk)
          .all<{ id: string }>();
        for (const r of results) if (await revokeLicense(c, r.id, "store")) revoked++;
      }
    }
  } else {
    c.log.info("cron.google_not_configured");
  }
  await cleanup(c);
  c.log.info("cron.done", { voided, revoked });
  return { voided, revoked };
}

export async function cleanup(c: Ctx): Promise<void> {
  const now = c.deps.now();
  const db = c.env.DB;
  await db.batch([
    db.prepare("DELETE FROM email_codes WHERE expires_at < ?1").bind(now - 3_600_000),
    db.prepare("DELETE FROM device_codes WHERE expires_at < ?1").bind(now - 3_600_000),
    // Expired pairing sessions stay one day so polls get 410 instead of 404.
    db.prepare("DELETE FROM pair_sessions WHERE expires_at < ?1").bind(now - DAY_MS),
    db.prepare("DELETE FROM sessions WHERE expires_at < ?1").bind(now),
    db.prepare("DELETE FROM rate_limits WHERE window_start < ?1").bind(now - DAY_MS),
    // Sync tombstones are kept for 180 days.
    db.prepare("DELETE FROM sync_items WHERE deleted = 1 AND updated_at < ?1").bind(now - 180 * DAY_MS),
  ]);
}
