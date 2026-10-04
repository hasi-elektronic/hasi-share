import type { Deps, Env } from "./env";
import type { Logger } from "./log";

/** Per-request context passed to every handler. */
export interface Ctx {
  env: Env;
  deps: Deps;
  log: Logger;
  req: Request;
  url: URL;
  params: Record<string, string>;
  /** Client IP (CF-Connecting-IP) – only ever used hashed. */
  ip: string;
  waitUntil: (p: Promise<unknown>) => void;
}

export type Handler = (c: Ctx) => Promise<Response> | Response;

/** Error that maps 1:1 to the API error format `{error, message, ...extra}`. */
export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly extra: Record<string, unknown> = {},
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
  }
}

export const badRequest = (message: string, extra?: Record<string, unknown>) =>
  new HttpError(400, "invalid_request", message, extra);
export const unauthorized = (message = "Authentication required.") =>
  new HttpError(401, "unauthorized", message);
export const notFound = (message = "Not found.") => new HttpError(404, "not_found", message);

export function json(data: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...headers,
    },
  });
}

export function noContent(): Response {
  return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
}

export function errorResponse(err: HttpError): Response {
  return json({ error: err.code, message: err.message, ...err.extra }, err.status, err.headers);
}

/** Reads the request body as text, enforcing a byte limit even without Content-Length. */
export async function readText(req: Request, maxBytes: number): Promise<string> {
  const declared = req.headers.get("content-length");
  if (declared !== null && Number(declared) > maxBytes) {
    throw new HttpError(413, "payload_too_large", `Request body exceeds ${maxBytes} bytes.`);
  }
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => undefined);
      throw new HttpError(413, "payload_too_large", `Request body exceeds ${maxBytes} bytes.`);
    }
    chunks.push(value);
  }
  const buf = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    buf.set(c, off);
    off += c.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: false }).decode(buf);
}

/** Parses a JSON object body (size-limited). */
export async function readJsonObject(req: Request, maxBytes = 16 * 1024): Promise<Record<string, unknown>> {
  const text = await readText(req, maxBytes);
  if (text.trim() === "") throw badRequest("Request body must be a JSON object.");
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw badRequest("Request body is not valid JSON.");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw badRequest("Request body must be a JSON object.");
  }
  return parsed as Record<string, unknown>;
}

// ---------- tiny validation helpers ----------

export function optString(
  obj: Record<string, unknown>,
  key: string,
  opts: { max?: number; min?: number; pattern?: RegExp } = {},
): string | undefined {
  const v = obj[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "string") throw badRequest(`'${key}' must be a string.`);
  const s = v.trim();
  if (opts.min !== undefined && s.length < opts.min) throw badRequest(`'${key}' is too short.`);
  if (s.length > (opts.max ?? 1024)) throw badRequest(`'${key}' is too long.`);
  if (opts.pattern && !opts.pattern.test(s)) throw badRequest(`'${key}' has an invalid format.`);
  return s;
}

export function reqString(
  obj: Record<string, unknown>,
  key: string,
  opts: { max?: number; min?: number; pattern?: RegExp } = {},
): string {
  const s = optString(obj, key, opts);
  if (s === undefined || s === "") throw badRequest(`'${key}' is required.`);
  return s;
}

export function optBool(obj: Record<string, unknown>, key: string): boolean | undefined {
  const v = obj[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "boolean") throw badRequest(`'${key}' must be a boolean.`);
  return v;
}

export function optInt(
  obj: Record<string, unknown>,
  key: string,
  opts: { min?: number; max?: number } = {},
): number | undefined {
  const v = obj[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "number" || !Number.isInteger(v)) throw badRequest(`'${key}' must be an integer.`);
  if (opts.min !== undefined && v < opts.min) throw badRequest(`'${key}' must be >= ${opts.min}.`);
  if (opts.max !== undefined && v > opts.max) throw badRequest(`'${key}' must be <= ${opts.max}.`);
  return v;
}

export function optObject(obj: Record<string, unknown>, key: string): Record<string, unknown> | undefined {
  const v = obj[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "object" || Array.isArray(v)) throw badRequest(`'${key}' must be an object.`);
  return v as Record<string, unknown>;
}

export function bearerToken(req: Request): string | null {
  const h = req.headers.get("authorization");
  if (!h) return null;
  const m = /^Bearer\s+(\S+)\s*$/i.exec(h);
  return m ? m[1]! : null;
}

// ---------- CORS ----------

export function allowedOrigins(env: Env): Set<string> {
  const set = new Set<string>();
  try {
    set.add(new URL(env.PUBLIC_BASE_URL).origin);
  } catch {
    /* ignore invalid base url */
  }
  for (const o of (env.CORS_ORIGINS ?? "").split(",")) {
    const t = o.trim();
    if (t) set.add(t.replace(/\/+$/, ""));
  }
  return set;
}

export function corsHeaders(env: Env, req: Request): Record<string, string> {
  const origin = req.headers.get("origin");
  if (!origin || !allowedOrigins(env).has(origin)) return {};
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "GET, POST, PUT, DELETE, OPTIONS",
    "access-control-allow-headers": "authorization, content-type",
    "access-control-max-age": "600",
    vary: "Origin",
  };
}

export function withHeaders(res: Response, headers: Record<string, string>): Response {
  if (Object.keys(headers).length === 0) return res;
  const out = new Response(res.body, res);
  for (const [k, v] of Object.entries(headers)) out.headers.set(k, v);
  return out;
}
