import { importRs256PrivateKey, signJws } from "../crypto";
import type { Ctx } from "../http";

export const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
export const ANDROID_PUBLISHER = "https://androidpublisher.googleapis.com/androidpublisher/v3";
const SCOPE = "https://www.googleapis.com/auth/androidpublisher";

/** Subset of `ProductPurchase` (purchases.products.get). */
export interface ProductPurchase {
  purchaseTimeMillis?: string;
  /** 0 purchased, 1 canceled, 2 pending */
  purchaseState?: number;
  /** 0 not yet acknowledged, 1 acknowledged */
  acknowledgementState?: number;
  consumptionState?: number;
  orderId?: string;
  purchaseType?: number;
  regionCode?: string;
  productId?: string;
}

export interface VoidedPurchase {
  purchaseToken: string;
  orderId?: string;
  purchaseTimeMillis?: string;
  voidedTimeMillis?: string;
  voidedSource?: number;
  voidedReason?: number;
}

export type GoogleResult<T> =
  | { ok: true; data: T }
  /** invalid: Google says the token/purchase does not exist (400/404/410). */
  | { ok: false; kind: "invalid" | "unavailable"; status: number };

interface ServiceAccount {
  client_email: string;
  private_key: string;
  private_key_id?: string;
  token_uri?: string;
}

export class GooglePlayClient {
  constructor(private readonly c: Ctx) {}

  get configured(): boolean {
    return !!this.c.env.GOOGLE_SERVICE_ACCOUNT_JSON && !!this.c.env.GOOGLE_PACKAGE_NAME;
  }

  private serviceAccount(): ServiceAccount {
    const raw = this.c.env.GOOGLE_SERVICE_ACCOUNT_JSON;
    if (!raw) throw new Error("GOOGLE_SERVICE_ACCOUNT_JSON is not configured");
    const sa = JSON.parse(raw) as ServiceAccount;
    if (!sa.client_email || !sa.private_key) throw new Error("service account JSON is incomplete");
    return sa;
  }

  /** OAuth 2.0 access token via the JWT bearer grant (RS256), cached until shortly before expiry. */
  async accessToken(): Promise<string> {
    const sa = this.serviceAccount();
    const cacheKey = `google_token:${sa.client_email}`;
    const now = this.c.deps.now();
    const cached = this.c.deps.cache.get(cacheKey);
    if (cached && cached.expiresAt > now + 60_000) return cached.value;

    const iat = Math.floor(now / 1000);
    const tokenUrl = sa.token_uri || GOOGLE_TOKEN_URL;
    const header: Record<string, unknown> = { alg: "RS256", typ: "JWT" };
    if (sa.private_key_id) header.kid = sa.private_key_id;
    const assertion = await signJws(
      header,
      { iss: sa.client_email, scope: SCOPE, aud: tokenUrl, iat, exp: iat + 3600 },
      await importRs256PrivateKey(sa.private_key),
    );
    const res = await this.c.deps.fetch(tokenUrl, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion,
      }).toString(),
    });
    if (!res.ok) throw new Error(`google oauth failed with HTTP ${res.status}`);
    const body = (await res.json()) as { access_token?: string; expires_in?: number };
    if (!body.access_token) throw new Error("google oauth response without access_token");
    this.c.deps.cache.set(cacheKey, {
      value: body.access_token,
      expiresAt: now + (body.expires_in ?? 3600) * 1000,
    });
    return body.access_token;
  }

  private async call(url: string, init: RequestInit = {}): Promise<Response | null> {
    let token: string;
    try {
      token = await this.accessToken();
    } catch (e) {
      this.c.log.error("google.oauth_error", { err: e instanceof Error ? e.message : String(e) });
      return null;
    }
    try {
      const headers = new Headers(init.headers);
      headers.set("authorization", `Bearer ${token}`);
      return await this.c.deps.fetch(url, { ...init, headers });
    } catch (e) {
      this.c.log.warn("google.network_error", { err: e instanceof Error ? e.message : String(e) });
      return null;
    }
  }

  private productUrl(productId: string, purchaseToken: string): string {
    const pkg = encodeURIComponent(this.c.env.GOOGLE_PACKAGE_NAME);
    return `${ANDROID_PUBLISHER}/applications/${pkg}/purchases/products/${encodeURIComponent(productId)}/tokens/${encodeURIComponent(purchaseToken)}`;
  }

  /** purchases.products.get */
  async getProductPurchase(productId: string, purchaseToken: string): Promise<GoogleResult<ProductPurchase>> {
    const res = await this.call(this.productUrl(productId, purchaseToken));
    if (!res) return { ok: false, kind: "unavailable", status: 0 };
    if (res.ok) return { ok: true, data: (await res.json()) as ProductPurchase };
    if (res.status === 400 || res.status === 404 || res.status === 410) {
      return { ok: false, kind: "invalid", status: res.status };
    }
    this.c.log.warn("google.products_get_failed", { status: res.status });
    return { ok: false, kind: "unavailable", status: res.status };
  }

  /** purchases.products.acknowledge – server-side acknowledgement (avoids the 3-day auto refund). */
  async acknowledge(productId: string, purchaseToken: string): Promise<boolean> {
    const res = await this.call(`${this.productUrl(productId, purchaseToken)}:acknowledge`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    if (!res || !res.ok) {
      this.c.log.warn("google.acknowledge_failed", { status: res?.status ?? 0 });
      return false;
    }
    return true;
  }

  /**
   * purchases.voidedpurchases.list for one-time products (type=0), following pagination.
   * Returns null when Google is unavailable.
   */
  async listVoided(startTimeMs: number, maxPages = 20): Promise<VoidedPurchase[] | null> {
    const pkg = encodeURIComponent(this.c.env.GOOGLE_PACKAGE_NAME);
    const out: VoidedPurchase[] = [];
    let pageToken: string | undefined;
    for (let page = 0; page < maxPages; page++) {
      const q = new URLSearchParams({ startTime: String(startTimeMs), type: "0", maxResults: "1000" });
      if (pageToken) q.set("token", pageToken);
      const res = await this.call(`${ANDROID_PUBLISHER}/applications/${pkg}/purchases/voidedpurchases?${q}`);
      if (!res || !res.ok) {
        this.c.log.warn("google.voided_list_failed", { status: res?.status ?? 0 });
        return null;
      }
      const body = (await res.json()) as {
        voidedPurchases?: VoidedPurchase[];
        tokenPagination?: { nextPageToken?: string };
      };
      out.push(...(body.voidedPurchases ?? []));
      pageToken = body.tokenPagination?.nextPageToken;
      if (!pageToken) break;
    }
    return out;
  }
}
