import type { Ctx } from "../http";

/** Trial window in epoch SECONDS (copied verbatim into token claims). */
export interface Trial {
  start: number;
  end: number;
  source: string;
}

/** Earliest start wins; on a tie the second argument (the established trial) is kept. */
export function earliest(a: Trial | null, b: Trial | null): Trial | null {
  if (!a) return b;
  if (!b) return a;
  return a.start < b.start ? a : b;
}

export function sameTrial(a: Trial | null, b: Trial | null): boolean {
  if (!a || !b) return a === b;
  return a.start === b.start && a.end === b.end;
}

export async function getDeviceTrial(c: Ctx, deviceKey: string): Promise<Trial | null> {
  const r = await c.env.DB.prepare("SELECT trial_start, trial_end, trial_source FROM devices WHERE device_key = ?1")
    .bind(deviceKey)
    .first<{ trial_start: number | null; trial_end: number | null; trial_source: string | null }>();
  if (!r || r.trial_start === null || r.trial_end === null) return null;
  return { start: r.trial_start, end: r.trial_end, source: r.trial_source ?? "server" };
}

export async function setDeviceTrial(c: Ctx, deviceKey: string, t: Trial): Promise<void> {
  await c.env.DB.prepare("UPDATE devices SET trial_start = ?2, trial_end = ?3, trial_source = ?4 WHERE device_key = ?1")
    .bind(deviceKey, t.start, t.end, t.source)
    .run();
}

/** Starts a server trial only if the device has none yet (one trial per deviceKey). */
export async function startDeviceTrialOnce(c: Ctx, deviceKey: string, t: Trial): Promise<void> {
  await c.env.DB.prepare(
    "UPDATE devices SET trial_start = ?2, trial_end = ?3, trial_source = ?4 WHERE device_key = ?1 AND trial_start IS NULL",
  )
    .bind(deviceKey, t.start, t.end, t.source)
    .run();
}

export async function getAccountTrial(c: Ctx, accountId: string): Promise<Trial | null> {
  const r = await c.env.DB.prepare("SELECT trial_start, trial_end, source FROM account_trials WHERE account_id = ?1")
    .bind(accountId)
    .first<{ trial_start: number; trial_end: number; source: string }>();
  return r ? { start: r.trial_start, end: r.trial_end, source: r.source } : null;
}

export async function setAccountTrial(c: Ctx, accountId: string, t: Trial): Promise<void> {
  await c.env.DB.prepare(
    "INSERT INTO account_trials (account_id, trial_start, trial_end, source, updated_at) VALUES (?1, ?2, ?3, ?4, ?5) " +
      "ON CONFLICT(account_id) DO UPDATE SET trial_start = excluded.trial_start, trial_end = excluded.trial_end, " +
      "source = excluded.source, updated_at = excluded.updated_at",
  )
    .bind(accountId, t.start, t.end, t.source, c.deps.now())
    .run();
}

/**
 * Admin extension. A device linked to an account that has a trial shares that trial,
 * so the account trial (and every device copy of it) is extended. Returns null if
 * there is no trial to extend.
 */
export async function extendTrial(
  c: Ctx,
  target: { deviceKey?: string; accountId?: string },
  days: number,
): Promise<{ scope: "device" | "account"; trial: Trial; accountId?: string } | null> {
  const delta = days * 86_400;
  let accountId = target.accountId;
  if (target.deviceKey) {
    const dev = await c.env.DB.prepare("SELECT account_id, trial_start FROM devices WHERE device_key = ?1")
      .bind(target.deviceKey)
      .first<{ account_id: string | null; trial_start: number | null }>();
    if (!dev) return null;
    const accTrial = dev.account_id ? await getAccountTrial(c, dev.account_id) : null;
    if (!accTrial) {
      const t = await getDeviceTrial(c, target.deviceKey);
      if (!t) return null;
      const nt = { ...t, end: Math.max(t.start, t.end + delta) };
      await setDeviceTrial(c, target.deviceKey, nt);
      return { scope: "device", trial: nt };
    }
    accountId = dev.account_id!;
  }
  if (!accountId) return null;
  const t = await getAccountTrial(c, accountId);
  if (!t) return null;
  const nt = { ...t, end: Math.max(t.start, t.end + delta) };
  await c.env.DB.batch([
    c.env.DB.prepare("UPDATE account_trials SET trial_end = ?2, updated_at = ?3 WHERE account_id = ?1").bind(
      accountId,
      nt.end,
      c.deps.now(),
    ),
    // Keep device copies of the shared trial coherent.
    c.env.DB.prepare("UPDATE devices SET trial_end = ?3 WHERE account_id = ?1 AND trial_start = ?2").bind(
      accountId,
      t.start,
      nt.end,
    ),
  ]);
  return { scope: "account", trial: nt, accountId };
}
