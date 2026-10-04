/** Worker bindings: [vars] from wrangler.toml plus secrets (`wrangler secret put`). */
export interface Env {
  DB: D1Database;

  PUBLIC_BASE_URL: string;
  APP_NAME: string;
  APP_IDS: string;

  /** Secret: ES256 private key, PKCS#8 PEM (a private JWK JSON string is accepted too). */
  LICENSE_SIGNING_KEY?: string;
  LICENSE_KID: string;

  /** Secret: admin bearer token (>= 32 chars). */
  ADMIN_TOKEN?: string;

  /** Secret: Google Play Developer API service account JSON. */
  GOOGLE_SERVICE_ACCOUNT_JSON?: string;
  GOOGLE_PACKAGE_NAME: string;
  GOOGLE_PRODUCT_ID: string;
  /** Secret: shared token in the Pub/Sub push URL. */
  GOOGLE_PUBSUB_TOKEN?: string;

  APPLE_ISSUER_ID?: string;
  APPLE_KEY_ID?: string;
  /** Secret: App Store Connect In-App Purchase key (.p8, PKCS#8 PEM). */
  APPLE_PRIVATE_KEY?: string;
  APPLE_BUNDLE_ID: string;
  APPLE_PRODUCT_ID: string;
  APPLE_TRIAL_PRODUCT_ID: string;
  APPLE_ENVIRONMENT?: string;

  /** Secret (optional): Resend API key for login e-mails. */
  RESEND_API_KEY?: string;
  MAIL_FROM?: string;

  DEV_MODE?: string;
  DEFAULT_TRIAL_DAYS?: string;
  MIN_VERSION_ANDROID?: string;
  MIN_VERSION_APPLE?: string;
  CORS_ORIGINS?: string;
}

/** Injectable dependencies (tests replace them; production uses the globals). */
export interface Deps {
  /** All outbound HTTP (Google, Apple, Resend) goes through this. */
  fetch: typeof fetch;
  /** Current time in epoch milliseconds. */
  now: () => number;
  /** Per-worker-instance in-memory cache (OAuth access tokens, Apple JWTs). */
  cache: Map<string, { value: string; expiresAt: number }>;
}

export function isDevMode(env: Env): boolean {
  return (env.DEV_MODE ?? "").toLowerCase() === "true";
}

export function appIds(env: Env): string[] {
  return (env.APP_IDS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

export function baseUrl(env: Env): string {
  return (env.PUBLIC_BASE_URL ?? "").replace(/\/+$/, "");
}

/** Secret values that must never appear in logs (CONTRACT §10 rule 1). */
export function secretValues(env: Env): string[] {
  const out: string[] = [];
  for (const v of [env.ADMIN_TOKEN, env.GOOGLE_PUBSUB_TOKEN, env.RESEND_API_KEY]) {
    if (v && v.length >= 3) out.push(v);
  }
  return out;
}
