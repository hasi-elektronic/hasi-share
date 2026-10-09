import { beforeEach, describe, expect, it } from "vitest";
import { pickLang } from "../src/pages/i18n";
import { Harness, T0, resetDb } from "./helpers";

let h: Harness;
beforeEach(async () => {
  await resetDb();
  h = await Harness.create();
});

describe("GET /v1/config", () => {
  it("matches BACKEND_API.md and is cacheable for 5 minutes", async () => {
    const r = await h.get("/v1/config");
    expect(r.status).toBe(200);
    expect(r.headers.get("cache-control")).toBe("public, max-age=300");
    expect(r.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(r.json).toEqual({
      trialDays: 7,
      minVersion: { android: 1, apple: 1 },
      products: {
        google: "lifetime_access",
        appleLifetime: "de.hasielektronik.novaplayer.lifetime",
        appleTrial: "de.hasielektronik.novaplayer.trial",
      },
      features: { accounts: true, pairing: true, sync: true },
      serverTime: T0,
    });
  });

  it("DEFAULT_TRIAL_DAYS var is used until an admin stores a value", async () => {
    h = await Harness.create({ DEFAULT_TRIAL_DAYS: "10" });
    expect((await h.get("/v1/config")).json.trialDays).toBe(10);
  });

  it("HEAD works and has no body", async () => {
    const r = await h.request("HEAD", "/v1/config");
    expect(r.status).toBe(200);
    expect(r.text).toBe("");
  });
});

describe("routing & error format", () => {
  it("404 not_found / 405 method_not_allowed as JSON errors", async () => {
    const nf = await h.get("/v1/nope");
    expect(nf.status).toBe(404);
    expect(nf.json).toEqual({ error: "not_found", message: "No such endpoint." });
    const na = await h.request("DELETE", "/v1/config");
    expect(na.status).toBe(405);
    expect(na.json.error).toBe("method_not_allowed");
    expect(na.headers.get("allow")).toBe("GET");
  });

  it("unexpected exceptions → 500 internal_error without internals", async () => {
    h = await Harness.create({ DB: undefined as never });
    const r = await h.get("/v1/config");
    expect(r.status).toBe(500);
    expect(r.json).toEqual({ error: "internal_error", message: "Internal server error." });
    expect(h.logs.some((l) => l.includes("unhandled_error"))).toBe(true);
  });

  it("every response has nosniff; JSON is no-store by default", async () => {
    const r = await h.get("/healthz");
    expect(r.json).toEqual({ ok: true });
    expect(r.headers.get("x-content-type-options")).toBe("nosniff");
    expect(r.headers.get("cache-control")).toBe("no-store");
  });

  it("request log lines contain the path but never the query string", async () => {
    await h.get("/v1/pair/sessions/ABCDEF?secret=top-secret-value");
    const line = h.logs.find((l) => l.includes('"msg":"request"'))!;
    expect(line).toContain('"path":"/v1/pair/sessions/ABCDEF"');
    h.assertLogsExclude(["top-secret-value"]);
  });
});

describe("CORS", () => {
  it("allows the PUBLIC_BASE_URL origin", async () => {
    const r = await h.get("/v1/config", { headers: { origin: "https://tv.example.test" } });
    expect(r.headers.get("access-control-allow-origin")).toBe("https://tv.example.test");
    expect(r.headers.get("access-control-allow-headers")).toBe("authorization, content-type");
    expect(r.headers.get("vary")).toBe("Origin");
  });

  it("does not echo foreign origins", async () => {
    const r = await h.get("/v1/config", { headers: { origin: "https://evil.example" } });
    expect(r.status).toBe(200);
    expect(r.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("CORS_ORIGINS adds origins; preflight returns 204", async () => {
    h = await Harness.create({ CORS_ORIGINS: "https://admin.example.org/, https://x.example" });
    const pre = await h.request("OPTIONS", "/v1/admin/config", {
      headers: { origin: "https://admin.example.org", "access-control-request-method": "PUT" },
    });
    expect(pre.status).toBe(204);
    expect(pre.headers.get("access-control-allow-origin")).toBe("https://admin.example.org");
    expect(pre.headers.get("access-control-allow-methods")).toContain("PUT");
    const denied = await h.request("OPTIONS", "/v1/admin/config", { headers: { origin: "https://evil.example" } });
    expect(denied.status).toBe(204);
    expect(denied.headers.get("access-control-allow-origin")).toBeNull();
  });
});

describe("language selection", () => {
  const req = (al?: string) => new Request("https://x/", al ? { headers: { "accept-language": al } } : {});
  it.each([
    [undefined, "", "en"],
    ["tr-TR,tr;q=0.9,en;q=0.8", "", "tr"],
    ["de-DE,de;q=0.9,tr;q=0.5,en;q=0.4", "", "de"],
    ["fr-FR,de;q=0.7,tr;q=0.5", "", "de"],
    ["fr-FR,tr;q=0.9,de;q=0.8", "", "tr"],
    ["en-US,tr;q=0.9", "", "en"],
    ["tr;q=0", "", "en"],
    ["de", "", "de"],
    ["de-AT", "", "de"],
    ["fr", "", "en"],
    ["tr", "?lang=en", "en"],
    ["en", "?lang=de", "de"],
    [undefined, "?lang=tr", "tr"],
    [undefined, "?lang=xx", "en"],
  ])("Accept-Language %s %s → %s", (al, q, lang) => {
    expect(pickLang(req(al), new URL(`https://x/${q}`))).toBe(lang);
  });
});

describe("GET /pair", () => {
  it("Turkish page by Accept-Language with the encryption routine inlined", async () => {
    const r = await h.get("/pair", { headers: { "accept-language": "tr-TR" } });
    expect(r.status).toBe(200);
    expect(r.headers.get("content-language")).toBe("tr");
    expect(r.headers.get("vary")).toBe("Accept-Language");
    expect(r.text).toContain('<html lang="tr">');
    expect(r.text).toContain("TV&#39;nize kaynak ekleyin");
    expect(r.text).toContain("window.iptvpPairEncrypt");
    expect(r.text).toContain("iptvp-pair-v1");
    expect(r.text).toContain("Uygulama içerik sağlamaz");
    // client-side strings are embedded as JSON in the page language
    const i18n = JSON.parse(/<script type="application\/json" id="i18n">([^<]*)<\/script>/.exec(r.text)![1]!);
    expect(i18n.err_code_unknown).toBe("Bu kod bulunamadı. TV'nizdeki kodu kontrol edin.");
  });

  it("English page, prefilled code from ?c=, form posts only to same-origin API", async () => {
    const r = await h.get("/pair?c=abc234");
    expect(r.text).toContain('<html lang="en">');
    expect(r.text).toContain("Add a source to your TV");
    expect(r.text).toContain('value="ABC-234"');
    expect(r.headers.get("content-security-policy")).toContain("connect-src 'self'");
    expect(r.text).not.toMatch(/<(script|link|img)[^>]+(src|href)="https?:/); // no external resources
    expect(r.text).toContain('href="/pair?lang=tr&amp;c=ABC234"');
  });

  it("an invalid / hostile ?c= is not reflected", async () => {
    const r = await h.get(`/pair?c=${encodeURIComponent('"><script>alert(1)</script>')}`);
    expect(r.status).toBe(200);
    expect(r.text).not.toContain("alert(1)");
    expect(r.text).toContain('placeholder="ABC-123" autocapitalize="characters" spellcheck="false" value=""');
  });

  it("?lang=tr overrides the header", async () => {
    const r = await h.get("/pair?lang=tr", { headers: { "accept-language": "en" } });
    expect(r.text).toContain('<html lang="tr">');
  });

  it("German page by Accept-Language, client strings in German", async () => {
    const r = await h.get("/pair?c=abc234", { headers: { "accept-language": "de-DE,de;q=0.9,en;q=0.5" } });
    expect(r.status).toBe(200);
    expect(r.headers.get("content-language")).toBe("de");
    expect(r.text).toContain('<html lang="de">');
    expect(r.text).toContain("Quelle zum TV hinzufügen");
    expect(r.text).toContain("Diese App stellt keine Inhalte bereit");
    const i18n = JSON.parse(/<script type="application\/json" id="i18n">([^<]*)<\/script>/.exec(r.text)![1]!);
    expect(i18n.err_code_unknown).toBe("Dieser Code ist unbekannt. Bitte den Code auf Ihrem TV prüfen.");
  });

  it("language switcher: Deutsch · Türkçe · English, current one not linked, ?c= kept", async () => {
    const de = await h.get("/pair?lang=de&c=abc234");
    expect(de.text).toContain('<html lang="de">');
    const sw = /<p class="muted lang-switch">(.*?)<\/p>/.exec(de.text)![1]!;
    expect(sw.replace(/<[^>]+>/g, "")).toBe("Deutsch · Türkçe · English");
    expect(sw).toContain('<strong lang="de" aria-current="true">Deutsch</strong>');
    expect(sw).toContain('href="/pair?lang=tr&amp;c=ABC234"');
    expect(sw).toContain('href="/pair?lang=en&amp;c=ABC234"');
    expect(sw).not.toContain("lang=de");
  });
});

describe("GET /link", () => {
  it("renders EN/TR/DE and pre-fills the TV code from ?c=", async () => {
    const en = await h.get("/link?c=ABCDEFGH");
    expect(en.status).toBe(200);
    expect(en.text).toContain("Sign in on your TV");
    expect(en.text).toContain('value="ABCD-EFGH"');
    expect(en.text).toContain("/v1/auth/device/approve");
    expect(en.text).toContain("sessionStorage");

    const tr = await h.get("/link", { headers: { "accept-language": "tr" } });
    expect(tr.text).toContain("TV&#39;nizde oturum açın");
    expect(tr.text).toContain('value=""');

    const de = await h.get("/link?lang=de&c=ABCDEFGH");
    expect(de.text).toContain('<html lang="de">');
    expect(de.text).toContain("Auf dem TV anmelden");
    expect(de.text).toContain("TV-Anmeldung bestätigen");
    expect(de.text).toContain('href="/link?lang=en&amp;c=ABCDEFGH"');
  });

  it("ignores invalid codes", async () => {
    const r = await h.get("/link?c=<b>1</b>");
    expect(r.text).not.toContain("<b>1</b>");
  });
});
