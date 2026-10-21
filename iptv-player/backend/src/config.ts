import type { Env } from "./env";

export interface AppConfig {
  trialDays: number;
  minVersion: { android: number; apple: number };
  features: { accounts: boolean; pairing: boolean; sync: boolean };
}

export const TRIAL_DAYS_MIN = 1;
export const TRIAL_DAYS_MAX = 90;

function intOr(v: string | undefined, fallback: number): number {
  const n = Number(v);
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

export function defaultConfig(env: Env): AppConfig {
  const td = intOr(env.DEFAULT_TRIAL_DAYS, 7);
  return {
    trialDays: Math.min(TRIAL_DAYS_MAX, Math.max(TRIAL_DAYS_MIN, td)),
    minVersion: {
      android: intOr(env.MIN_VERSION_ANDROID, 1),
      apple: intOr(env.MIN_VERSION_APPLE, 1),
    },
    features: { accounts: true, pairing: true, sync: true },
  };
}

/** Effective config: D1 `config` rows override the [vars] defaults. */
export async function getConfig(env: Env): Promise<AppConfig> {
  const cfg = defaultConfig(env);
  const { results } = await env.DB.prepare("SELECT key, value FROM config").all<{ key: string; value: string }>();
  for (const row of results) {
    try {
      const v = JSON.parse(row.value) as unknown;
      if (row.key === "trialDays" && typeof v === "number" && Number.isInteger(v)) {
        if (v >= TRIAL_DAYS_MIN && v <= TRIAL_DAYS_MAX) cfg.trialDays = v;
      } else if (row.key === "minVersion" && v && typeof v === "object") {
        const mv = v as Record<string, unknown>;
        if (typeof mv.android === "number") cfg.minVersion.android = mv.android;
        if (typeof mv.apple === "number") cfg.minVersion.apple = mv.apple;
      } else if (row.key === "features" && v && typeof v === "object") {
        const f = v as Record<string, unknown>;
        for (const k of ["accounts", "pairing", "sync"] as const) {
          if (typeof f[k] === "boolean") cfg.features[k] = f[k] as boolean;
        }
      }
    } catch {
      /* ignore malformed rows */
    }
  }
  return cfg;
}

export async function setConfigValues(env: Env, values: Record<string, unknown>, now: number): Promise<void> {
  const stmts = Object.entries(values).map(([k, v]) =>
    env.DB.prepare(
      "INSERT INTO config (key, value, updated_at) VALUES (?1, ?2, ?3) " +
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
    ).bind(k, JSON.stringify(v), now),
  );
  if (stmts.length > 0) await env.DB.batch(stmts);
}
