import { decodeJwsPayloadUnverified, importEs256PrivateKey, signJws } from "../crypto";
import type { Ctx } from "../http";

export const APPLE_PRODUCTION_URL = "https://api.storekit.itunes.apple.com";
export const APPLE_SANDBOX_URL = "https://api.storekit-sandbox.itunes.apple.com";

export type AppleEnvironment = "Production" | "Sandbox";

/** Subset of JWSTransactionDecodedPayload. Dates are epoch milliseconds. */
export interface AppleTransaction {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  purchaseDate: number;
  originalPurchaseDate?: number;
  type?: string;
  inAppOwnershipType?: string;
  environment?: string;
  revocationDate?: number;
  revocationReason?: number;
}

export type AppleResult =
  | { ok: true; tx: AppleTransaction; environment: AppleEnvironment }
  | { ok: false; kind: "not_found" | "invalid" | "unavailable"; status: number };

export function parseTransactionPayload(p: Record<string, unknown> | null): AppleTransaction | null {
  if (!p) return null;
  const str = (v: unknown) => (typeof v === "string" ? v : typeof v === "number" ? String(v) : undefined);
  const num = (v: unknown) => (typeof v === "number" ? v : typeof v === "string" && v !== "" ? Number(v) : undefined);
  const transactionId = str(p.transactionId);
  const originalTransactionId = str(p.originalTransactionId) ?? transactionId;
  const bundleId = str(p.bundleId);
  const productId = str(p.productId);
  const purchaseDate = num(p.purchaseDate);
  if (!transactionId || !originalTransactionId || !bundleId || !productId || purchaseDate === undefined || !Number.isFinite(purchaseDate)) {
    return null;
  }
  const tx: AppleTransaction = { transactionId, originalTransactionId, bundleId, productId, purchaseDate };
  const opd = num(p.originalPurchaseDate);
  if (opd !== undefined) tx.originalPurchaseDate = opd;
  if (typeof p.type === "string") tx.type = p.type;
  if (typeof p.inAppOwnershipType === "string") tx.inAppOwnershipType = p.inAppOwnershipType;
  if (typeof p.environment === "string") tx.environment = p.environment;
  const rd = num(p.revocationDate);
  if (rd !== undefined && Number.isFinite(rd)) tx.revocationDate = rd;
  const rr = num(p.revocationReason);
  if (rr !== undefined) tx.revocationReason = rr;
  return tx;
}

export class AppStoreClient {
  constructor(private readonly c: Ctx) {}

  get configured(): boolean {
    const e = this.c.env;
    return !!(e.APPLE_ISSUER_ID && e.APPLE_KEY_ID && e.APPLE_PRIVATE_KEY && e.APPLE_BUNDLE_ID);
  }

  /** ES256 API token (App Store Server API), cached for 20 of its 30 minutes. */
  private async apiToken(): Promise<string> {
    const e = this.c.env;
    const cacheKey = `apple_jwt:${e.APPLE_KEY_ID}`;
    const now = this.c.deps.now();
    const cached = this.c.deps.cache.get(cacheKey);
    if (cached && cached.expiresAt > now) return cached.value;
    const iat = Math.floor(now / 1000);
    const token = await signJws(
      { alg: "ES256", kid: e.APPLE_KEY_ID, typ: "JWT" },
      { iss: e.APPLE_ISSUER_ID, iat, exp: iat + 1800, aud: "appstoreconnect-v1", bid: e.APPLE_BUNDLE_ID },
      await importEs256PrivateKey(e.APPLE_PRIVATE_KEY ?? ""),
    );
    this.c.deps.cache.set(cacheKey, { value: token, expiresAt: now + 20 * 60_000 });
    return token;
  }

  /**
   * GET /inApps/v1/transactions/{id}. Tries the configured environment first (or `hint`),
   * then the other one on 404. Trust comes from TLS to Apple (payload is decoded, not verified).
   */
  async getTransaction(transactionId: string, hint?: string): Promise<AppleResult> {
    if (!this.configured) {
      this.c.log.error("apple.not_configured");
      return { ok: false, kind: "unavailable", status: 0 };
    }
    let token: string;
    try {
      token = await this.apiToken();
    } catch (e) {
      this.c.log.error("apple.token_error", { err: e instanceof Error ? e.message : String(e) });
      return { ok: false, kind: "unavailable", status: 0 };
    }
    const preferred: AppleEnvironment =
      (hint ?? this.c.env.APPLE_ENVIRONMENT ?? "Production").toLowerCase() === "sandbox" ? "Sandbox" : "Production";
    const order: AppleEnvironment[] = preferred === "Sandbox" ? ["Sandbox", "Production"] : ["Production", "Sandbox"];
    let last: AppleResult = { ok: false, kind: "not_found", status: 404 };
    for (const env of order) {
      const base = env === "Production" ? APPLE_PRODUCTION_URL : APPLE_SANDBOX_URL;
      let res: Response;
      try {
        res = await this.c.deps.fetch(`${base}/inApps/v1/transactions/${encodeURIComponent(transactionId)}`, {
          headers: { authorization: `Bearer ${token}` },
        });
      } catch (e) {
        this.c.log.warn("apple.network_error", { err: e instanceof Error ? e.message : String(e) });
        return { ok: false, kind: "unavailable", status: 0 };
      }
      if (res.status === 404) {
        last = { ok: false, kind: "not_found", status: 404 };
        continue;
      }
      if (res.status === 400) return { ok: false, kind: "invalid", status: 400 };
      if (!res.ok) {
        this.c.log.warn("apple.get_transaction_failed", { status: res.status, env });
        return { ok: false, kind: "unavailable", status: res.status };
      }
      const body = (await res.json()) as { signedTransactionInfo?: string };
      const tx = parseTransactionPayload(
        body.signedTransactionInfo ? decodeJwsPayloadUnverified(body.signedTransactionInfo) : null,
      );
      if (!tx) {
        this.c.log.warn("apple.malformed_transaction", { env });
        return { ok: false, kind: "unavailable", status: res.status };
      }
      return { ok: true, tx, environment: env };
    }
    return last;
  }
}
