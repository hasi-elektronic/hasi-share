import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { DAY, Harness, RESEND_KEY, T0, resetDb } from "./helpers";

let h: Harness;
beforeEach(async () => {
  await resetDb();
  h = await Harness.create();
});

/** Production-like harness: DEV_MODE off (strict limits, no devCode), Resend configured. */
const prod = () => Harness.create({ DEV_MODE: "false", RESEND_API_KEY: RESEND_KEY });

describe("POST /v1/auth/email/start", () => {
  it("DEV_MODE=true returns devCode (6 digits) and works without Resend", async () => {
    const r = await h.post("/v1/auth/email/start", { email: "Dev@Example.com", locale: "en" });
    expect(r.status).toBe(200);
    expect(r.json.ok).toBe(true);
    expect(r.json.devCode).toMatch(/^\d{6}$/);
    expect(h.stores.emails).toHaveLength(0);
  });

  it("production: sends the code via Resend, no devCode in the response", async () => {
    h = await prod();
    const r = await h.post("/v1/auth/email/start", { email: "user@example.com", locale: "tr" });
    expect(r.status).toBe(200);
    expect(r.json).toEqual({ ok: true });
    expect(h.stores.emails).toHaveLength(1);
    const mail = h.stores.emails[0]!;
    expect(mail.to).toEqual(["user@example.com"]);
    expect(mail.subject).toContain("giriş kodunuz");
    expect(mail.text).toMatch(/\b\d{6}\b/);
    const en = await h.post("/v1/auth/email/start", { email: "user2@example.com", locale: "en" });
    expect(en.status).toBe(200);
    expect(h.stores.emails[1]!.subject).toMatch(/^Your NovaPlayer sign-in code: \d{6}$/);
  });

  it("production without RESEND_API_KEY → 503 email_unavailable", async () => {
    h = await Harness.create({ DEV_MODE: "false" });
    const r = await h.post("/v1/auth/email/start", { email: "user@example.com", locale: "en" });
    expect(r.status).toBe(503);
    expect(r.json.error).toBe("email_unavailable");
  });

  it("400 for invalid e-mail addresses", async () => {
    for (const email of ["", "nope", "a@b", "a b@example.com", "<x>@example.com"]) {
      const r = await h.post("/v1/auth/email/start", { email, locale: "en" });
      expect(r.status).toBe(400);
      expect(r.json.error).toBe("invalid_request");
    }
  });

  it("rate limit: 5/hour per e-mail", async () => {
    h = await prod();
    for (let i = 0; i < 5; i++) {
      expect((await h.post("/v1/auth/email/start", { email: "rl@example.com", locale: "en" }, { ip: `10.0.0.${i}` })).status).toBe(200);
    }
    const r = await h.post("/v1/auth/email/start", { email: "RL@example.com", locale: "en" }, { ip: "10.0.0.99" });
    expect(r.status).toBe(429);
    expect(r.json.error).toBe("rate_limited");
    expect(h.stores.emails).toHaveLength(5);
    h.advance(3_600_000);
    expect((await h.post("/v1/auth/email/start", { email: "rl@example.com", locale: "en" })).status).toBe(200);
  });

  it("rate limit: 20/hour per IP", async () => {
    h = await prod();
    for (let i = 0; i < 20; i++) {
      expect((await h.post("/v1/auth/email/start", { email: `u${i}@example.com`, locale: "en" }, { ip: "192.0.2.1" })).status).toBe(200);
    }
    expect((await h.post("/v1/auth/email/start", { email: "u99@example.com", locale: "en" }, { ip: "192.0.2.1" })).status).toBe(429);
    expect((await h.post("/v1/auth/email/start", { email: "u99@example.com", locale: "en" }, { ip: "192.0.2.2" })).status).toBe(200);
  });

  it("DEV_MODE relaxes rate limits", async () => {
    for (let i = 0; i < 8; i++) {
      expect((await h.post("/v1/auth/email/start", { email: "dev-rl@example.com", locale: "en" })).status).toBe(200);
    }
  });

  it("403 feature_disabled when accounts are switched off", async () => {
    await h.admin("PUT", "/v1/admin/config", { features: { accounts: false } });
    const r = await h.post("/v1/auth/email/start", { email: "a@example.com", locale: "en" });
    expect(r.status).toBe(403);
    expect(r.json.error).toBe("feature_disabled");
    expect((await h.post("/v1/auth/device/start", { platform: "tvos" })).status).toBe(403);
  });
});

describe("POST /v1/auth/email/verify", () => {
  async function start(email = "v@example.com") {
    return (await h.post("/v1/auth/email/start", { email, locale: "en" })).json.devCode as string;
  }
  const wrong = (code: string) => (code === "000000" ? "111111" : "000000");

  it("valid code → session token (32 bytes base64url) + account; e-mail is case-insensitive", async () => {
    const code = await start("Verify@Example.com");
    const r = await h.post("/v1/auth/email/verify", { email: "verify@example.COM", code, deviceName: "Pixel" });
    expect(r.status).toBe(200);
    expect(r.json.sessionToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(r.json.account.email).toBe("verify@example.com");
    expect(r.json.account.id).toMatch(/^acc_/);
    // stored hashed only
    const row = await env.DB.prepare("SELECT token_hash, expires_at, device_name FROM sessions").first<{ token_hash: string; expires_at: number; device_name: string }>();
    expect(row!.token_hash).not.toBe(r.json.sessionToken);
    expect(row!.token_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(row!.expires_at).toBe(T0 + 180 * DAY);
    expect(row!.device_name).toBe("Pixel");
    // same account on a second login
    const code2 = await start("verify@example.com");
    const r2 = await h.post("/v1/auth/email/verify", { email: "verify@example.com", code: code2 });
    expect(r2.json.account.id).toBe(r.json.account.id);
  });

  it("codes are single use", async () => {
    const code = await start();
    expect((await h.post("/v1/auth/email/verify", { email: "v@example.com", code })).status).toBe(200);
    const again = await h.post("/v1/auth/email/verify", { email: "v@example.com", code });
    expect(again.status).toBe(400);
    expect(again.json.error).toBe("invalid_code");
  });

  it("400 invalid_code with attemptsLeft; 429 too_many_attempts after 5 wrong codes (even with the right code)", async () => {
    const code = await start();
    for (let i = 1; i <= 4; i++) {
      const r = await h.post("/v1/auth/email/verify", { email: "v@example.com", code: wrong(code) });
      expect(r.status).toBe(400);
      expect(r.json).toMatchObject({ error: "invalid_code", attemptsLeft: 5 - i });
    }
    const fifth = await h.post("/v1/auth/email/verify", { email: "v@example.com", code: wrong(code) });
    expect(fifth.status).toBe(429);
    expect(fifth.json.error).toBe("too_many_attempts");
    const right = await h.post("/v1/auth/email/verify", { email: "v@example.com", code });
    expect(right.status).toBe(429);
    // a new code resets the attempts
    const code2 = await start();
    expect((await h.post("/v1/auth/email/verify", { email: "v@example.com", code: code2 })).status).toBe(200);
  });

  it("410 code_expired after 10 minutes", async () => {
    const code = await start();
    h.advance(10 * 60_000);
    const r = await h.post("/v1/auth/email/verify", { email: "v@example.com", code });
    expect(r.status).toBe(410);
    expect(r.json.error).toBe("code_expired");
  });

  it("still valid just before 10 minutes", async () => {
    const code = await start();
    h.advance(10 * 60_000 - 1);
    expect((await h.post("/v1/auth/email/verify", { email: "v@example.com", code })).status).toBe(200);
  });

  it("400 invalid_code when no code was requested; malformed codes count as attempts", async () => {
    expect((await h.post("/v1/auth/email/verify", { email: "none@example.com", code: "123456" })).json.error).toBe("invalid_code");
    await start();
    const r = await h.post("/v1/auth/email/verify", { email: "v@example.com", code: "12ab" });
    expect(r.status).toBe(400);
    expect(r.json.attemptsLeft).toBe(4);
  });

  it("a new code replaces the previous one", async () => {
    const first = await start();
    const second = await start();
    if (first !== second) {
      expect((await h.post("/v1/auth/email/verify", { email: "v@example.com", code: first })).status).toBe(400);
    }
    expect((await h.post("/v1/auth/email/verify", { email: "v@example.com", code: second })).status).toBe(200);
  });

  it("logs never contain the code, the session token or the plain e-mail", async () => {
    h = await prod();
    await h.post("/v1/auth/email/start", { email: "secret.person@example.com", locale: "en" });
    const code = h.lastEmailCode();
    const r = await h.post("/v1/auth/email/verify", { email: "secret.person@example.com", code });
    h.assertLogsExclude([code, r.json.sessionToken, "secret.person@example.com", "secret.person", RESEND_KEY]);
  });
});

describe("sessions", () => {
  it("logout invalidates the token", async () => {
    const { token } = await h.login("out@example.com");
    expect((await h.get("/v1/account", { token })).status).toBe(200);
    const r = await h.post("/v1/auth/logout", {}, { token });
    expect(r.status).toBe(200);
    expect(r.json).toEqual({ ok: true });
    const after = await h.get("/v1/account", { token });
    expect(after.status).toBe(401);
    expect(after.json.error).toBe("unauthorized");
    expect((await h.post("/v1/auth/logout", {}, { token })).status).toBe(401);
  });

  it("401 without / with malformed bearer token", async () => {
    expect((await h.get("/v1/account")).status).toBe(401);
    expect((await h.get("/v1/account", { headers: { authorization: "Basic abc" } })).status).toBe(401);
    expect((await h.get("/v1/account", { token: "x".repeat(200) })).status).toBe(401);
  });

  it("180-day sliding lifetime", async () => {
    const { token } = await h.login("slide@example.com");
    // used every 100 days → stays valid well past 180 days
    for (let i = 0; i < 3; i++) {
      h.advance(100 * DAY);
      expect((await h.get("/v1/account", { token })).status).toBe(200);
    }
    // idle for 180 days → expired and removed
    h.advance(180 * DAY);
    expect((await h.get("/v1/account", { token })).status).toBe(401);
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM sessions").first<{ n: number }>())!.n).toBe(0);
  });

  it("an unused session expires after exactly 180 days", async () => {
    const { token } = await h.login("idle@example.com");
    h.advance(180 * DAY - 1);
    expect((await h.get("/v1/account", { token })).status).toBe(200);
    h.advance(180 * DAY);
    expect((await h.get("/v1/account", { token })).status).toBe(401);
  });
});
