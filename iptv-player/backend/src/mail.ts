import type { Ctx } from "./http";

export type Lang = "de" | "tr" | "en";

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (ch) =>
    ch === "&" ? "&amp;" : ch === "<" ? "&lt;" : ch === ">" ? "&gt;" : ch === '"' ? "&quot;" : "&#39;",
  );
}

export function loginCodeEmail(appName: string, code: string, lang: Lang): { subject: string; text: string; html: string } {
  const texts: Record<Lang, { subject: string; intro: string; validity: string; ignore: string }> = {
    de: {
      subject: `Ihr ${appName}-Anmeldecode: ${code}`,
      intro: `Verwenden Sie diesen Code, um sich bei Ihrem ${appName}-Konto anzumelden:`,
      validity: "Der Code ist 10 Minuten gültig.",
      ignore: "Falls Sie diese Anfrage nicht gestellt haben, können Sie diese E-Mail ignorieren.",
    },
    tr: {
      subject: `${appName} giriş kodunuz: ${code}`,
      intro: `${appName} hesabınıza giriş yapmak için bu kodu kullanın:`,
      validity: "Kod 10 dakika geçerlidir.",
      ignore: "Bu isteği siz yapmadıysanız bu e-postayı yok sayabilirsiniz.",
    },
    en: {
      subject: `Your ${appName} sign-in code: ${code}`,
      intro: `Use this code to sign in to your ${appName} account:`,
      validity: "The code is valid for 10 minutes.",
      ignore: "If you did not request this, you can ignore this e-mail.",
    },
  };
  const t = texts[lang];
  const text = `${t.intro}\n\n${code}\n\n${t.validity}\n${t.ignore}\n`;
  const html =
    `<!doctype html><html lang="${lang}"><body style="font-family:system-ui,sans-serif;color:#111">` +
    `<p>${escapeHtml(t.intro)}</p>` +
    `<p style="font-size:28px;font-weight:700;letter-spacing:6px">${escapeHtml(code)}</p>` +
    `<p>${escapeHtml(t.validity)}<br>${escapeHtml(t.ignore)}</p></body></html>`;
  return { subject: t.subject, text, html };
}

export type SendResult = "sent" | "skipped" | "failed";

/** Sends a login code via Resend (https://resend.com). Returns "skipped" without an API key. */
export async function sendLoginCode(c: Ctx, to: string, code: string, lang: Lang): Promise<SendResult> {
  const key = c.env.RESEND_API_KEY;
  if (!key) return "skipped";
  const appName = c.env.APP_NAME || "App";
  const mail = loginCodeEmail(appName, code, lang);
  try {
    const res = await c.deps.fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
      body: JSON.stringify({
        from: c.env.MAIL_FROM || `${appName} <no-reply@example.com>`,
        to: [to],
        subject: mail.subject,
        text: mail.text,
        html: mail.html,
      }),
    });
    if (!res.ok) {
      c.log.warn("mail.send_failed", { status: res.status });
      return "failed";
    }
    return "sent";
  } catch (e) {
    c.log.warn("mail.send_error", { err: e instanceof Error ? e.message : String(e) });
    return "failed";
  }
}
