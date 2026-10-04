import { env } from "cloudflare:workers";
import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import licenseVectors from "../../spec/test-vectors/license-token.json";
import { createWorker } from "../src/app";
import { b64urlDecode, b64urlEncode, derToPem, fromUtf8, sha256Hex, utf8 } from "../src/crypto";
import type { Env } from "../src/env";

export const APP_ID = "de.hasielektronik.novaplayer";
export const ADMIN_TOKEN = "admin-token-0123456789abcdefghijklmnopqrstuvwxyz";
export const PUBSUB_TOKEN = "pubsub-shared-secret-xyz";
export const RESEND_KEY = "re_test_key_123456";
export const T0 = 1_759_570_000_000; // 2025-10-04T09:26:40Z
export const DAY = 86_400_000;

export const TEST_PUBLIC_KEYS = licenseVectors.keys as Record<string, JsonWebKey>;

const TABLES = [
  "config",
  "accounts",
  "devices",
  "account_trials",
  "apple_trials",
  "email_codes",
  "sessions",
  "licenses",
  "license_devices",
  "device_codes",
  "sync_items",
  "pair_sessions",
  "rate_limits",
];

export async function resetDb(): Promise<void> {
  await env.DB.batch(TABLES.map((t) => env.DB.prepare(`DELETE FROM ${t}`)));
}

/** CONTRACT §7.1 – the apps compute this on device; tests use it to build realistic keys. */
export async function deviceKeyFor(appId: string, rawId: string): Promise<string> {
  return sha256Hex(`iptvp-device-v1|${appId}|${rawId}`);
}

let cachedKeys: Promise<{
  licensePem: string;
  rsaPem: string;
  rsaPublic: CryptoKey;
  applePem: string;
  applePublic: CryptoKey;
}> | null = null;

/** Converts the vector's private JWK to PKCS#8 PEM (the production secret format). */
async function jwkToPkcs8Pem(jwk: JsonWebKey): Promise<string> {
  const { key_ops: _o, ext: _e, ...clean } = jwk;
  const key = await crypto.subtle.importKey("jwk", clean, { name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", key)) as ArrayBuffer);
  return derToPem(der, "PRIVATE KEY");
}

export function testKeys() {
  cachedKeys ??= (async () => {
    const licensePem = await jwkToPkcs8Pem(licenseVectors.privateKeyForBackendTests.jwk as JsonWebKey);
    const rsa = (await crypto.subtle.generateKey(
      { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
      true,
      ["sign", "verify"],
    )) as CryptoKeyPair;
    const rsaPem = derToPem(new Uint8Array((await crypto.subtle.exportKey("pkcs8", rsa.privateKey)) as ArrayBuffer), "PRIVATE KEY");
    const apple = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const applePem = derToPem(new Uint8Array((await crypto.subtle.exportKey("pkcs8", apple.privateKey)) as ArrayBuffer), "PRIVATE KEY");
    return { licensePem, rsaPem, rsaPublic: rsa.publicKey, applePem, applePublic: apple.publicKey };
  })();
  return cachedKeys;
}

// ---------------------------------------------------------------------------
// Fake outbound HTTP (Google, Apple, Resend). Unexpected calls fail the test.
// ---------------------------------------------------------------------------

export interface FakeProductPurchase {
  purchaseState: number;
  acknowledgementState?: number;
  orderId?: string;
  purchaseTimeMillis?: string;
}

export interface FakeAppleTx {
  env: "Production" | "Sandbox";
  payload: Record<string, unknown>;
}

export interface Call {
  method: string;
  url: string;
  headers: Headers;
  body: string;
}

export function fakeJws(payload: Record<string, unknown>): string {
  return `${b64urlEncode(JSON.stringify({ alg: "ES256", x5c: ["MIIB-fake"] }))}.${b64urlEncode(JSON.stringify(payload))}.${b64urlEncode("not-a-real-signature")}`;
}

export function decodeJwtPart(token: string, i: number): Record<string, unknown> {
  return JSON.parse(fromUtf8(b64urlDecode(token.split(".")[i]!))) as Record<string, unknown>;
}

export class FakeStores {
  calls: Call[] = [];
  googlePurchases = new Map<string, FakeProductPurchase | number>();
  googleVoided: { purchaseToken: string; orderId?: string; voidedTimeMillis?: string }[] = [];
  googleDown = false;
  appleTx = new Map<string, FakeAppleTx>();
  appleDown = false;
  emails: { to: string[]; subject: string; text: string }[] = [];
  oauthCount = 0;

  constructor(private readonly keys: Awaited<ReturnType<typeof testKeys>>) {}

  fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const req = new Request(input as RequestInfo, init);
    const body = req.method === "GET" ? "" : await req.text();
    const call: Call = { method: req.method, url: req.url, headers: req.headers, body };
    this.calls.push(call);
    const url = new URL(req.url);

    if (url.href === "https://oauth2.googleapis.com/token") return this.googleToken(body);
    if (url.hostname === "androidpublisher.googleapis.com") {
      if (req.headers.get("authorization") !== "Bearer ya29.fake-access-token") return new Response("no auth", { status: 401 });
      if (this.googleDown) return new Response("down", { status: 503 });
      return this.google(req.method, url);
    }
    if (url.hostname === "api.storekit.itunes.apple.com" || url.hostname === "api.storekit-sandbox.itunes.apple.com") {
      await this.checkAppleJwt(req.headers.get("authorization"));
      if (this.appleDown) return new Response("down", { status: 503 });
      const env = url.hostname.includes("sandbox") ? "Sandbox" : "Production";
      const m = /^\/inApps\/v1\/transactions\/(\d+)$/.exec(url.pathname);
      const tx = m ? this.appleTx.get(m[1]!) : undefined;
      if (!tx || tx.env !== env) return Response.json({ errorCode: 4040010, errorMessage: "Transaction id not found." }, { status: 404 });
      return Response.json({ signedTransactionInfo: fakeJws(tx.payload) });
    }
    if (url.href === "https://api.resend.com/emails") {
      if (req.headers.get("authorization") !== `Bearer ${RESEND_KEY}`) return new Response("bad key", { status: 401 });
      const j = JSON.parse(body) as { to: string[]; subject: string; text: string };
      this.emails.push(j);
      return Response.json({ id: "email_1" });
    }
    throw new Error(`Unexpected outbound fetch: ${req.method} ${req.url}`);
  };

  private async googleToken(body: string): Promise<Response> {
    const params = new URLSearchParams(body);
    if (params.get("grant_type") !== "urn:ietf:params:oauth:grant-type:jwt-bearer") return new Response("bad grant", { status: 400 });
    const assertion = params.get("assertion") ?? "";
    const [h, p, s] = assertion.split(".");
    const ok = await crypto.subtle.verify(
      { name: "RSASSA-PKCS1-v1_5" },
      this.keys.rsaPublic,
      b64urlDecode(s!),
      utf8(`${h}.${p}`),
    );
    const claims = decodeJwtPart(assertion, 1);
    if (!ok || claims.scope !== "https://www.googleapis.com/auth/androidpublisher" || claims.aud !== "https://oauth2.googleapis.com/token") {
      return new Response("invalid assertion", { status: 400 });
    }
    this.oauthCount++;
    return Response.json({ access_token: "ya29.fake-access-token", expires_in: 3599, token_type: "Bearer" });
  }

  private google(method: string, url: URL): Response {
    const base = "/androidpublisher/v3/applications/de.hasielektronik.novaplayer/purchases";
    if (method === "GET" && url.pathname === `${base}/voidedpurchases`) {
      if (url.searchParams.get("type") !== "0") return new Response("type", { status: 400 });
      return Response.json({ voidedPurchases: this.googleVoided });
    }
    const m = /^\/androidpublisher\/v3\/applications\/de\.hasielektronik\.novaplayer\/purchases\/products\/([^/]+)\/tokens\/([^/:]+)(:acknowledge)?$/.exec(
      url.pathname,
    );
    if (!m) return new Response("not found", { status: 404 });
    const token = decodeURIComponent(m[2]!);
    const p = this.googlePurchases.get(token);
    if (p === undefined) return Response.json({ error: { code: 400, message: "Invalid Value" } }, { status: 400 });
    if (typeof p === "number") return new Response("error", { status: p });
    if (m[3]) {
      if (method !== "POST") return new Response("method", { status: 405 });
      p.acknowledgementState = 1;
      return new Response(null, { status: 204 });
    }
    return Response.json({
      kind: "androidpublisher#productPurchase",
      purchaseTimeMillis: p.purchaseTimeMillis ?? String(T0 - 60_000),
      purchaseState: p.purchaseState,
      consumptionState: 0,
      orderId: p.orderId ?? "GPA.1234-5678-9012-34567",
      acknowledgementState: p.acknowledgementState ?? 0,
      purchaseType: 0,
    });
  }

  private async checkAppleJwt(auth: string | null): Promise<void> {
    const token = auth?.replace(/^Bearer /, "") ?? "";
    const [h, p, s] = token.split(".");
    const header = decodeJwtPart(token, 0);
    const claims = decodeJwtPart(token, 1);
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      this.keys.applePublic,
      b64urlDecode(s!),
      utf8(`${h}.${p}`),
    );
    if (!ok || header.alg !== "ES256" || header.kid !== "APPLEKEY01" || claims.aud !== "appstoreconnect-v1" || claims.bid !== APP_ID || claims.iss !== "issuer-uuid") {
      throw new Error("invalid Apple API token");
    }
  }

  count(re: RegExp, method?: string): number {
    return this.calls.filter((c) => re.test(c.url) && (!method || c.method === method)).length;
  }
}

export function appleTxPayload(over: Partial<Record<string, unknown>> & { transactionId: string; productId: string }) {
  return {
    transactionId: over.transactionId,
    originalTransactionId: over.originalTransactionId ?? over.transactionId,
    bundleId: over.bundleId ?? APP_ID,
    productId: over.productId,
    purchaseDate: over.purchaseDate ?? T0 - 3_600_000,
    originalPurchaseDate: over.originalPurchaseDate ?? over.purchaseDate ?? T0 - 3_600_000,
    type: "Non-Consumable",
    inAppOwnershipType: "PURCHASED",
    environment: over.environment ?? "Production",
    signedDate: T0,
    ...(over.revocationDate !== undefined ? { revocationDate: over.revocationDate, revocationReason: 1 } : {}),
  };
}

// ---------------------------------------------------------------------------
// Test harness: worker with fake stores, a controllable clock and captured logs.
// ---------------------------------------------------------------------------

export interface ReqOptions {
  body?: unknown;
  rawBody?: string;
  token?: string;
  headers?: Record<string, string>;
  ip?: string;
}

export interface TestResponse {
  status: number;
  headers: Headers;
  text: string;
  json: Record<string, any>;
}

export class Harness {
  now = T0;
  logs: string[] = [];
  private ipCounter = 0;
  stores!: FakeStores;
  env!: Env;
  worker!: ReturnType<typeof createWorker>;

  static async create(envOverrides: Partial<Env> = {}): Promise<Harness> {
    const h = new Harness();
    const keys = await testKeys();
    h.stores = new FakeStores(keys);
    h.env = {
      ...(env as unknown as Env),
      LICENSE_SIGNING_KEY: keys.licensePem,
      LICENSE_KID: "test-1",
      ADMIN_TOKEN,
      GOOGLE_PUBSUB_TOKEN: PUBSUB_TOKEN,
      GOOGLE_SERVICE_ACCOUNT_JSON: JSON.stringify({
        type: "service_account",
        client_email: "play-api@test-project.iam.gserviceaccount.com",
        private_key_id: "key-id-1",
        private_key: keys.rsaPem,
        token_uri: "https://oauth2.googleapis.com/token",
      }),
      APPLE_ISSUER_ID: "issuer-uuid",
      APPLE_KEY_ID: "APPLEKEY01",
      APPLE_PRIVATE_KEY: keys.applePem,
      APPLE_ENVIRONMENT: "Production",
      DEV_MODE: "true",
      ...envOverrides,
    };
    h.worker = createWorker({
      fetch: h.stores.fetch,
      now: () => h.now,
      logSink: (_level, line) => h.logs.push(line),
    });
    return h;
  }

  advance(ms: number): void {
    this.now += ms;
  }

  async request(method: string, path: string, o: ReqOptions = {}): Promise<TestResponse> {
    const headers: Record<string, string> = { "cf-connecting-ip": o.ip ?? "203.0.113.7", ...(o.headers ?? {}) };
    if (o.token) headers.authorization = `Bearer ${o.token}`;
    let body: string | undefined = o.rawBody;
    if (o.body !== undefined) {
      body = JSON.stringify(o.body);
      headers["content-type"] = "application/json";
    }
    const ctx = createExecutionContext();
    const res = await this.worker.fetch(new Request(`https://tv.example.test${path}`, { method, headers, body }), this.env, ctx);
    await waitOnExecutionContext(ctx);
    const text = await res.text();
    let json: Record<string, any> = {};
    try {
      json = text ? (JSON.parse(text) as Record<string, any>) : {};
    } catch {
      /* html */
    }
    return { status: res.status, headers: res.headers, text, json };
  }

  get = (path: string, o?: ReqOptions) => this.request("GET", path, o);
  post = (path: string, body?: unknown, o: ReqOptions = {}) => this.request("POST", path, { ...o, body: body ?? {} });
  put = (path: string, body?: unknown, o: ReqOptions = {}) => this.request("PUT", path, { ...o, body: body ?? {} });
  del = (path: string, o?: ReqOptions) => this.request("DELETE", path, o);
  admin = (method: string, path: string, body?: unknown) =>
    this.request(method, path, { ...(body !== undefined ? { body } : {}), token: ADMIN_TOKEN });

  async runCron(): Promise<void> {
    const ctx = createExecutionContext();
    await this.worker.scheduled(createScheduledController({ cron: "17 3 * * *", scheduledTime: this.now }), this.env, ctx);
    await waitOnExecutionContext(ctx);
  }

  /** E-mail login (DEV_MODE devCode) → session token. */
  async login(email: string, deviceName = "Test device"): Promise<{ token: string; accountId: string }> {
    const s = await this.post("/v1/auth/email/start", { email, locale: "en" }, { ip: `198.51.100.${++this.ipCounter}` });
    if (s.status !== 200) throw new Error(`email/start failed: ${s.status} ${s.text}`);
    const code = s.json.devCode ?? this.lastEmailCode();
    const v = await this.post("/v1/auth/email/verify", { email, code, deviceName });
    if (v.status !== 200) throw new Error(`email/verify failed: ${v.status} ${v.text}`);
    return { token: v.json.sessionToken as string, accountId: v.json.account.id as string };
  }

  lastEmailCode(): string {
    const last = this.stores.emails[this.stores.emails.length - 1];
    const m = last ? /\b(\d{6})\b/.exec(last.text) : null;
    if (!m) throw new Error("no e-mail code captured");
    return m[1]!;
  }

  async licenseSync(body: Record<string, unknown>, token?: string): Promise<TestResponse> {
    return this.post("/v1/license/sync", { appId: APP_ID, appVersion: "1.0.0 (1)", ...body }, token ? { token } : {});
  }

  /** Asserts that no captured log line contains any of the given secret strings. */
  assertLogsExclude(secrets: string[]): void {
    for (const line of this.logs) {
      for (const s of secrets) {
        if (s && line.includes(s)) throw new Error(`log line leaks a secret (${s.slice(0, 6)}…): ${line}`);
      }
    }
  }
}

export async function newDeviceKey(seed: string): Promise<string> {
  return deviceKeyFor(APP_ID, seed);
}
