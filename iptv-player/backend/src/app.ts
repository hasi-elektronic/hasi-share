import { deleteAccount, getAccount, logout } from "./account";
import {
  adminExtendTrial,
  adminGetConfig,
  adminGrant,
  adminPutConfig,
  adminRestore,
  adminRevoke,
  adminSearchLicenses,
} from "./admin";
import { deviceApprove, devicePoll, deviceStart } from "./auth/device";
import { emailStart, emailVerify } from "./auth/email";
import { getConfig } from "./config";
import { runCron } from "./cron";
import { isDevMode, secretValues, type Deps, type Env } from "./env";
import { HttpError, corsHeaders, errorResponse, json, withHeaders, type Ctx } from "./http";
import { licenseSync } from "./license/sync";
import { Logger, type LogLevel, type LogSink } from "./log";
import { adminPage } from "./pages/admin";
import { linkPage } from "./pages/link";
import { pairPage } from "./pages/pair";
import { pairCreate, pairGetKey, pairPoll, pairPostPayload } from "./pair";
import { Router } from "./router";
import { syncGet, syncPost } from "./sync";
import { appleWebhook, googleWebhook } from "./webhooks";

/** GET /v1/config */
async function configHandler(c: Ctx): Promise<Response> {
  const cfg = await getConfig(c.env);
  return json(
    {
      trialDays: cfg.trialDays,
      minVersion: cfg.minVersion,
      products: {
        google: c.env.GOOGLE_PRODUCT_ID,
        appleLifetime: c.env.APPLE_PRODUCT_ID,
        appleTrial: c.env.APPLE_TRIAL_PRODUCT_ID,
      },
      features: cfg.features,
      serverTime: c.deps.now(),
    },
    200,
    { "cache-control": "public, max-age=300" },
  );
}

export function buildRouter(): Router {
  return new Router()
    .get("/", (c) => json({ ok: true, name: c.env.APP_NAME, serverTime: c.deps.now() }))
    .get("/healthz", () => json({ ok: true }))
    .get("/v1/config", configHandler)
    .post("/v1/license/sync", licenseSync)
    .post("/v1/auth/email/start", emailStart)
    .post("/v1/auth/email/verify", emailVerify)
    .post("/v1/auth/logout", logout)
    .get("/v1/account", getAccount)
    .delete("/v1/account", deleteAccount)
    .post("/v1/auth/device/start", deviceStart)
    .post("/v1/auth/device/poll", devicePoll)
    .post("/v1/auth/device/approve", deviceApprove)
    .get("/v1/sync", syncGet)
    .post("/v1/sync", syncPost)
    .post("/v1/pair/sessions", pairCreate)
    .get("/v1/pair/sessions/:code/key", pairGetKey)
    .post("/v1/pair/sessions/:code/payload", pairPostPayload)
    .get("/v1/pair/sessions/:code", pairPoll)
    .post("/v1/webhooks/google", googleWebhook)
    .post("/v1/webhooks/apple", appleWebhook)
    .get("/v1/admin/config", adminGetConfig)
    .put("/v1/admin/config", adminPutConfig)
    .post("/v1/admin/trials/extend", adminExtendTrial)
    .get("/v1/admin/licenses", adminSearchLicenses)
    .post("/v1/admin/licenses/grant", adminGrant)
    .post("/v1/admin/licenses/:id/revoke", adminRevoke)
    .post("/v1/admin/licenses/:id/restore", adminRestore)
    .get("/pair", pairPage)
    .get("/link", linkPage)
    .get("/admin", adminPage);
}

export interface WorkerOptions extends Partial<Deps> {
  /** Log sink override (tests capture lines here). */
  logSink?: LogSink;
}

/** Creates the Worker handlers; tests inject `fetch`, `now` and a log sink. */
export function createWorker(opts: WorkerOptions = {}) {
  const deps: Deps = {
    fetch: opts.fetch ?? ((input, init) => fetch(input, init)),
    now: opts.now ?? (() => Date.now()),
    cache: opts.cache ?? new Map(),
  };
  const router = buildRouter();

  function logger(env: Env, base: Record<string, unknown>): Logger {
    const level: LogLevel = isDevMode(env) ? "debug" : "info";
    return new Logger(secretValues(env), level, base, opts.logSink);
  }

  async function handle(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    const reqId = crypto.randomUUID().slice(0, 8);
    const log = logger(env, { req: reqId });
    const started = deps.now();
    const cors = corsHeaders(env, req);

    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }

    let res: Response;
    const m = router.match(req.method, url.pathname);
    if (m.kind === "not_found") {
      res = errorResponse(new HttpError(404, "not_found", "No such endpoint."));
    } else if (m.kind === "method_not_allowed") {
      res = errorResponse(
        new HttpError(405, "method_not_allowed", "Method not allowed.", {}, { allow: m.allow.join(", ") }),
      );
    } else {
      const c: Ctx = {
        env,
        deps,
        log,
        req,
        url,
        params: m.params,
        ip: req.headers.get("cf-connecting-ip") ?? "unknown",
        waitUntil: (p) => ctx.waitUntil(p),
      };
      try {
        res = await m.handler(c);
      } catch (e) {
        if (e instanceof HttpError) {
          res = errorResponse(e);
        } else {
          log.error("unhandled_error", { err: e instanceof Error ? e.message : String(e), path: url.pathname });
          res = errorResponse(new HttpError(500, "internal_error", "Internal server error."));
        }
      }
    }
    // Path only (no query: it may contain secrets such as the Pub/Sub token).
    log.info("request", { method: req.method, path: url.pathname, status: res.status, ms: deps.now() - started });
    res = withHeaders(res, { "x-content-type-options": "nosniff", ...cors });
    if (req.method === "HEAD") return new Response(null, res);
    return res;
  }

  return {
    fetch: handle,
    async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
      const log = logger(env, { cron: controller.cron });
      const c: Ctx = {
        env,
        deps,
        log,
        req: new Request("https://cron.internal/"),
        url: new URL("https://cron.internal/"),
        params: {},
        ip: "cron",
        waitUntil: (p) => ctx.waitUntil(p),
      };
      try {
        await runCron(c);
      } catch (e) {
        log.error("cron.failed", { err: e instanceof Error ? e.message : String(e) });
        throw e;
      }
    },
  } satisfies ExportedHandler<Env>;
}
