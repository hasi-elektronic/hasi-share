import { randomToken } from "../crypto";
import type { Lang } from "./i18n";

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (ch) =>
    ch === "&" ? "&amp;" : ch === "<" ? "&lt;" : ch === ">" ? "&gt;" : ch === '"' ? "&quot;" : "&#39;",
  );
}

/** JSON safe for embedding inside <script> (no "</script>", no U+2028/9 issues). */
export function scriptJson(v: unknown): string {
  return JSON.stringify(v)
    .replace(/</g, "\\u003c")
    .replace(/>/g, "\\u003e")
    .replace(/&/g, "\\u0026")
    .replace(new RegExp("\\u2028", "g"), "\\u2028")
    .replace(new RegExp("\\u2029", "g"), "\\u2029");
}

const CSS = `
:root{color-scheme:light dark;--bg:#0f1115;--fg:#e9ecf1;--muted:#9aa3af;--card:#181b22;--line:#2a2f3a;--acc:#4f8cff;--err:#ff6b6b;--ok:#3ecf8e}
@media (prefers-color-scheme: light){:root{--bg:#f5f6f8;--fg:#14171c;--muted:#5b6472;--card:#fff;--line:#dde1e7;--acc:#2f6fe0;--err:#c62828;--ok:#1b8a5a}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:560px;margin:0 auto;padding:24px 16px 48px}
main.wide{max-width:980px}
h1{font-size:1.5rem;margin:0 0 8px}
h2{font-size:1.1rem;margin:0 0 12px}
p{margin:0 0 12px}
.muted{color:var(--muted);font-size:.9rem}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px;margin:16px 0}
label{display:block;font-weight:600;margin:12px 0 4px}
input[type=text],input[type=email],input[type=url],input[type=password],input[type=number],select{width:100%;padding:12px;border-radius:10px;border:1px solid var(--line);background:var(--bg);color:var(--fg);font-size:1rem}
input.code{font-size:1.6rem;letter-spacing:.3em;text-transform:uppercase;text-align:center;font-family:ui-monospace,Menlo,monospace}
button{margin-top:16px;padding:12px 18px;border:0;border-radius:10px;background:var(--acc);color:#fff;font-size:1rem;font-weight:600;cursor:pointer}
button.secondary{background:transparent;color:var(--acc);border:1px solid var(--line)}
button.small{margin:0 4px 0 0;padding:6px 10px;font-size:.85rem}
button:disabled{opacity:.6;cursor:default}
.row{display:flex;gap:12px;flex-wrap:wrap;align-items:center}
.row > *{flex:1 1 160px}
.seg{display:flex;gap:8px;margin-top:6px}
.seg label{flex:1;margin:0;font-weight:500;border:1px solid var(--line);border-radius:10px;padding:10px;text-align:center;cursor:pointer}
.seg input{margin-right:6px}
.check{display:flex;align-items:center;gap:8px;font-weight:400}
.msg{margin-top:12px;min-height:1.2em}
.msg.err{color:var(--err)}
.msg.ok{color:var(--ok)}
.badge{display:inline-block;padding:2px 8px;border-radius:99px;font-size:.8rem;border:1px solid var(--line)}
.badge.active{color:var(--ok);border-color:var(--ok)}
.badge.revoked{color:var(--err);border-color:var(--err)}
table{width:100%;border-collapse:collapse;font-size:.85rem}
th,td{text-align:left;padding:6px;border-bottom:1px solid var(--line);vertical-align:top;word-break:break-all}
code{font-family:ui-monospace,Menlo,monospace;font-size:.85em}
[hidden]{display:none !important}
footer{margin-top:24px;color:var(--muted);font-size:.8rem}
`;

export interface PageParts {
  lang: Lang;
  title: string;
  appName: string;
  body: string;
  /** Inline script sources (each gets the CSP nonce). */
  scripts: string[];
  wide?: boolean;
}

/** Renders a standalone page with a strict nonce-based CSP (no external resources). */
export function renderPage(p: PageParts): Response {
  const nonce = randomToken(16);
  const html =
    `<!doctype html><html lang="${p.lang}"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width,initial-scale=1">` +
    `<meta name="robots" content="noindex">` +
    `<title>${escapeHtml(p.title)} · ${escapeHtml(p.appName)}</title>` +
    `<style nonce="${nonce}">${CSS}</style></head><body>` +
    `<main${p.wide ? ' class="wide"' : ""}>${p.body}</main>` +
    p.scripts.map((s) => `<script nonce="${nonce}">${s}</script>`).join("") +
    `</body></html>`;
  return new Response(html, {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "content-language": p.lang,
      "cache-control": "no-store",
      "content-security-policy":
        `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; ` +
        `connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'`,
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
      "x-frame-options": "DENY",
      vary: "Accept-Language",
    },
  });
}

export function langSwitch(lang: Lang, path: string, extraQuery = ""): string {
  const other: Lang = lang === "tr" ? "en" : "tr";
  const q = extraQuery ? `&${extraQuery}` : "";
  return `<p class="muted"><a href="${escapeHtml(`${path}?lang=${other}${q}`)}">${other === "tr" ? "Türkçe" : "English"}</a></p>`;
}
