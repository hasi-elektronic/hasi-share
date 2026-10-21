import { getConfig, setConfigValues, TRIAL_DAYS_MAX, TRIAL_DAYS_MIN } from "./config";
import { randomId, timingSafeEqualStr } from "./crypto";
import { HttpError, badRequest, bearerToken, json, notFound, optObject, optString, readJsonObject, type Ctx } from "./http";
import { linkLicense, restoreLicense, revokeLicense, type LicenseRow } from "./license/repo";
import { DEVICE_KEY_RE } from "./license/sync";
import { extendTrial } from "./license/trial";

const MIN_ADMIN_TOKEN_LENGTH = 32;

/** Bearer ADMIN_TOKEN, constant-time compare. Disabled when the secret is missing/short. */
export async function requireAdmin(c: Ctx): Promise<void> {
  const expected = c.env.ADMIN_TOKEN;
  const given = bearerToken(c.req);
  if (!expected || expected.length < MIN_ADMIN_TOKEN_LENGTH) {
    c.log.error("admin.not_configured");
    throw new HttpError(401, "unauthorized", "Admin access is not configured.");
  }
  if (!given || !(await timingSafeEqualStr(given, expected))) {
    throw new HttpError(401, "unauthorized", "Invalid admin token.");
  }
}

/** GET /v1/admin/config */
export async function adminGetConfig(c: Ctx): Promise<Response> {
  await requireAdmin(c);
  return json(await getConfig(c.env));
}

/** PUT /v1/admin/config {trialDays (1..90), minVersion?, features?} */
export async function adminPutConfig(c: Ctx): Promise<Response> {
  await requireAdmin(c);
  const body = await readJsonObject(c.req);
  const values: Record<string, unknown> = {};
  if (body.trialDays !== undefined) {
    const td = body.trialDays;
    if (typeof td !== "number" || !Number.isInteger(td) || td < TRIAL_DAYS_MIN || td > TRIAL_DAYS_MAX) {
      throw badRequest(`'trialDays' must be an integer between ${TRIAL_DAYS_MIN} and ${TRIAL_DAYS_MAX}.`);
    }
    values.trialDays = td;
  }
  const mv = optObject(body, "minVersion");
  if (mv) {
    const cur = (await getConfig(c.env)).minVersion;
    for (const k of ["android", "apple"] as const) {
      const v = mv[k];
      if (v === undefined) continue;
      if (typeof v !== "number" || !Number.isInteger(v) || v < 0) throw badRequest(`'minVersion.${k}' must be a non-negative integer.`);
      cur[k] = v;
    }
    values.minVersion = cur;
  }
  const f = optObject(body, "features");
  if (f) {
    const cur = (await getConfig(c.env)).features;
    for (const k of ["accounts", "pairing", "sync"] as const) {
      const v = f[k];
      if (v === undefined) continue;
      if (typeof v !== "boolean") throw badRequest(`'features.${k}' must be a boolean.`);
      cur[k] = v;
    }
    values.features = cur;
  }
  if (Object.keys(values).length === 0) throw badRequest("Nothing to update.");
  await setConfigValues(c.env, values, c.deps.now());
  c.log.info("admin.config_updated", { keys: Object.keys(values) });
  return json(await getConfig(c.env));
}

/** POST /v1/admin/trials/extend {deviceKey? | accountId?, days} */
export async function adminExtendTrial(c: Ctx): Promise<Response> {
  await requireAdmin(c);
  const body = await readJsonObject(c.req);
  const deviceKey = optString(body, "deviceKey", { max: 64 })?.toLowerCase();
  const accountId = optString(body, "accountId", { max: 64 });
  if (!!deviceKey === !!accountId) throw badRequest("Provide exactly one of 'deviceKey' or 'accountId'.");
  if (deviceKey && !DEVICE_KEY_RE.test(deviceKey)) throw badRequest("'deviceKey' must be 64 hex characters.");
  const days = body.days;
  if (typeof days !== "number" || !Number.isInteger(days) || days === 0 || Math.abs(days) > 3650) {
    throw badRequest("'days' must be a non-zero integer (-3650..3650).");
  }
  const r = await extendTrial(c, deviceKey ? { deviceKey } : { accountId: accountId! }, days);
  if (!r) throw new HttpError(404, "trial_not_found", "No trial found for this target.");
  c.log.info("admin.trial_extended", { scope: r.scope, days });
  return json({ ok: true, scope: r.scope, accountId: r.accountId ?? null, trialStart: r.trial.start, trialEnd: r.trial.end });
}

function maskRef(store: string, ref: string): string {
  // Purchase tokens are bearer-like secrets; Apple transaction ids are not.
  if (store !== "google") return ref;
  return ref.length > 12 ? `${ref.slice(0, 8)}…${ref.slice(-4)}` : "…";
}

async function describeLicenses(c: Ctx, rows: LicenseRow[]) {
  const out = [];
  for (const l of rows) {
    const { results: devs } = await c.env.DB.prepare("SELECT device_key FROM license_devices WHERE license_id = ?1")
      .bind(l.id)
      .all<{ device_key: string }>();
    const email = l.account_id
      ? (await c.env.DB.prepare("SELECT email FROM accounts WHERE id = ?1").bind(l.account_id).first<{ email: string }>())?.email
      : null;
    out.push({
      id: l.id,
      store: l.store,
      storeRef: maskRef(l.store, l.store_ref),
      orderId: l.order_id,
      productId: l.product_id,
      status: l.status,
      purchasedAt: l.purchased_at,
      revokedAt: l.revoked_at,
      revokeReason: l.revoke_reason,
      accountId: l.account_id,
      accountEmail: email ?? null,
      deviceKeys: devs.map((d) => d.device_key),
      note: l.note,
      createdAt: l.created_at,
    });
  }
  return out;
}

/** GET /v1/admin/licenses?query= (store ref / order id / account e-mail / account id / deviceKey / license id) */
export async function adminSearchLicenses(c: Ctx): Promise<Response> {
  await requireAdmin(c);
  const q = (c.url.searchParams.get("query") ?? "").trim();
  if (q.length > 4096) throw badRequest("Query too long.");
  const db = c.env.DB;
  let rows: LicenseRow[] = [];
  let device: unknown = null;
  let account: unknown = null;
  if (q === "") {
    rows = (await db.prepare("SELECT * FROM licenses ORDER BY created_at DESC LIMIT 50").all<LicenseRow>()).results;
  } else if (q.includes("@") || q.startsWith("acc_")) {
    const acc = await db
      .prepare("SELECT id, email, created_at FROM accounts WHERE email = ?1 OR id = ?1")
      .bind(q.includes("@") ? q.toLowerCase() : q)
      .first<{ id: string; email: string; created_at: number }>();
    if (acc) {
      const trial = await db
        .prepare("SELECT trial_start, trial_end FROM account_trials WHERE account_id = ?1")
        .bind(acc.id)
        .first<{ trial_start: number; trial_end: number }>();
      account = { id: acc.id, email: acc.email, createdAt: acc.created_at, trial: trial ? { start: trial.trial_start, end: trial.trial_end } : null };
      rows = (await db.prepare("SELECT * FROM licenses WHERE account_id = ?1 ORDER BY created_at DESC").bind(acc.id).all<LicenseRow>()).results;
    }
  } else if (DEVICE_KEY_RE.test(q.toLowerCase())) {
    const dk = q.toLowerCase();
    const d = await db
      .prepare("SELECT device_key, platform, app_version, account_id, trial_start, trial_end, trial_source, created_at, last_seen_at FROM devices WHERE device_key = ?1")
      .bind(dk)
      .first<Record<string, unknown>>();
    if (d) {
      device = {
        deviceKey: d.device_key,
        platform: d.platform,
        appVersion: d.app_version,
        accountId: d.account_id,
        trial: d.trial_start !== null ? { start: d.trial_start, end: d.trial_end, source: d.trial_source } : null,
        createdAt: d.created_at,
        lastSeenAt: d.last_seen_at,
      };
    }
    rows = (
      await db
        .prepare(
          "SELECT DISTINCT l.* FROM licenses l LEFT JOIN license_devices ld ON ld.license_id = l.id " +
            "WHERE ld.device_key = ?1 OR l.device_key = ?1 ORDER BY l.created_at DESC",
        )
        .bind(dk)
        .all<LicenseRow>()
    ).results;
  } else {
    rows = (
      await db
        .prepare("SELECT * FROM licenses WHERE id = ?1 OR store_ref = ?1 OR order_id = ?1 ORDER BY created_at DESC LIMIT 50")
        .bind(q)
        .all<LicenseRow>()
    ).results;
  }
  return json({ licenses: await describeLicenses(c, rows), device, account });
}

async function licenseById(c: Ctx): Promise<LicenseRow> {
  const id = c.params.id ?? "";
  const row = await c.env.DB.prepare("SELECT * FROM licenses WHERE id = ?1").bind(id).first<LicenseRow>();
  if (!row) throw notFound("License not found.");
  return row;
}

/** POST /v1/admin/licenses/{id}/revoke */
export async function adminRevoke(c: Ctx): Promise<Response> {
  await requireAdmin(c);
  const row = await licenseById(c);
  const changed = await revokeLicense(c, row.id, "admin");
  const [out] = await describeLicenses(c, [await licenseById(c)]);
  return json({ ok: true, changed, license: out });
}

/** POST /v1/admin/licenses/{id}/restore */
export async function adminRestore(c: Ctx): Promise<Response> {
  await requireAdmin(c);
  const row = await licenseById(c);
  const changed = await restoreLicense(c, row.id);
  const [out] = await describeLicenses(c, [await licenseById(c)]);
  return json({ ok: true, changed, license: out });
}

/** POST /v1/admin/licenses/grant {accountId | deviceKey, note} → license with store "admin" */
export async function adminGrant(c: Ctx): Promise<Response> {
  await requireAdmin(c);
  const body = await readJsonObject(c.req);
  const deviceKey = optString(body, "deviceKey", { max: 64 })?.toLowerCase();
  const accountId = optString(body, "accountId", { max: 64 });
  const note = optString(body, "note", { max: 500 }) ?? null;
  if (!!deviceKey === !!accountId) throw badRequest("Provide exactly one of 'deviceKey' or 'accountId'.");
  const db = c.env.DB;
  if (deviceKey) {
    if (!DEVICE_KEY_RE.test(deviceKey)) throw badRequest("'deviceKey' must be 64 hex characters.");
    if (!(await db.prepare("SELECT 1 AS x FROM devices WHERE device_key = ?1").bind(deviceKey).first())) {
      throw notFound("Device not found (it must have synced at least once).");
    }
  } else if (!(await db.prepare("SELECT 1 AS x FROM accounts WHERE id = ?1").bind(accountId!).first())) {
    throw notFound("Account not found.");
  }
  const id = randomId("lic_");
  const now = c.deps.now();
  await db
    .prepare(
      "INSERT INTO licenses (id, store, store_ref, order_id, product_id, status, purchased_at, device_key, account_id, note, raw_state, created_at, updated_at) " +
        "VALUES (?1, 'admin', ?2, NULL, 'admin_grant', 'active', ?3, ?4, ?5, ?6, '{}', ?3, ?3)",
    )
    .bind(id, randomId("adm_", 8), now, deviceKey ?? null, accountId ?? null, note)
    .run();
  if (deviceKey) await linkLicense(c, id, { deviceKey });
  c.log.info("admin.license_granted", { license: id, target: deviceKey ? "device" : "account" });
  const row = await db.prepare("SELECT * FROM licenses WHERE id = ?1").bind(id).first<LicenseRow>();
  const [out] = await describeLicenses(c, [row!]);
  return json({ ok: true, license: out });
}
