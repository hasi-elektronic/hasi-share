import { normalizeUserCode } from "../auth/device";
import type { Ctx } from "../http";
import { clientStrings, pickLang, t, type StringKey } from "./i18n";
import { escapeHtml, langSwitch, renderPage, scriptJson } from "./layout";

const CLIENT_KEYS: StringKey[] = [
  "code_sent",
  "signed_in_as",
  "approved",
  "err_invalid_code",
  "err_code_expired_login",
  "err_too_many_attempts",
  "err_email",
  "err_tv_code",
  "err_mail",
  "err_network",
  "err_too_many",
];

/** Client logic of /link (device-code approval). Session token lives in sessionStorage only. */
const LINK_SCRIPT = `
(function () {
  "use strict";
  var T = JSON.parse(document.getElementById("i18n").textContent);
  var LANG = document.documentElement.lang || "en";
  var KEY = "linkSession";
  function $(id) { return document.getElementById(id); }
  function msg(id, text, kind) { var el = $(id); el.textContent = text || ""; el.className = "msg" + (kind ? " " + kind : ""); }
  function store(k, v) { try { if (v === null) sessionStorage.removeItem(k); else sessionStorage.setItem(k, v); } catch (e) {} }
  function load(k) { try { return sessionStorage.getItem(k); } catch (e) { return null; } }
  function api(path, body, token) {
    var headers = { "content-type": "application/json", accept: "application/json" };
    if (token) headers.authorization = "Bearer " + token;
    return fetch(path, { method: "POST", headers: headers, body: JSON.stringify(body || {}) })
      .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { return { status: r.status, body: j }; }); });
  }
  function fmtCode(s) { var c = String(s || "").toUpperCase().replace(/[\\s-]+/g, ""); return c.length > 4 ? c.slice(0, 4) + "-" + c.slice(4, 8) : c; }
  var email = null;
  function render() {
    var token = load(KEY);
    $("login").hidden = !!token;
    $("approve").hidden = !token;
    if (token) $("who").textContent = T.signed_in_as.replace("{0}", load(KEY + "Email") || "");
  }
  $("email-form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    email = $("email").value.trim();
    if (!/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(email)) { msg("email-msg", T.err_email, "err"); return; }
    $("email-btn").disabled = true;
    api("/v1/auth/email/start", { email: email, locale: LANG }).then(function (r) {
      if (r.status === 200) {
        msg("email-msg", T.code_sent.replace("{0}", email), "ok");
        $("otp-form").hidden = false;
        $("otp").focus();
      } else if (r.status === 429) msg("email-msg", T.err_too_many, "err");
      else if (r.status === 400) msg("email-msg", T.err_email, "err");
      else msg("email-msg", T.err_mail, "err");
    }).catch(function () { msg("email-msg", T.err_network, "err"); })
      .then(function () { $("email-btn").disabled = false; });
  });
  $("otp-form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    $("otp-btn").disabled = true;
    api("/v1/auth/email/verify", { email: email, code: $("otp").value.trim(), deviceName: "Web (/link)" }).then(function (r) {
      if (r.status === 200 && r.body.sessionToken) {
        store(KEY, r.body.sessionToken);
        store(KEY + "Email", r.body.account && r.body.account.email);
        msg("otp-msg", "");
        render();
      } else if (r.status === 410) msg("otp-msg", T.err_code_expired_login, "err");
      else if (r.status === 429) msg("otp-msg", T.err_too_many_attempts, "err");
      else msg("otp-msg", T.err_invalid_code, "err");
    }).catch(function () { msg("otp-msg", T.err_network, "err"); })
      .then(function () { $("otp-btn").disabled = false; });
  });
  $("approve-form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    $("approve-btn").disabled = true;
    api("/v1/auth/device/approve", { userCode: $("tvcode").value }, load(KEY)).then(function (r) {
      if (r.status === 200) { msg("approve-msg", T.approved, "ok"); }
      else if (r.status === 401) { store(KEY, null); render(); }
      else if (r.status === 429) msg("approve-msg", T.err_too_many, "err");
      else msg("approve-msg", T.err_tv_code, "err");
    }).catch(function () { msg("approve-msg", T.err_network, "err"); })
      .then(function () { $("approve-btn").disabled = false; });
  });
  $("logout").addEventListener("click", function () {
    var token = load(KEY);
    store(KEY, null); store(KEY + "Email", null);
    if (token) api("/v1/auth/logout", {}, token).catch(function () {});
    render();
  });
  var pre = new URLSearchParams(location.search).get("c");
  if (pre) $("tvcode").value = fmtCode(pre);
  render();
})();
`;

/** GET /link – e-mail login (if needed) + approve the TV's user code. */
export function linkPage(c: Ctx): Response {
  const lang = pickLang(c.req, c.url);
  const appName = c.env.APP_NAME || "App";
  const pre = normalizeUserCode(c.url.searchParams.get("c") ?? "");
  const e = (k: StringKey) => escapeHtml(t(lang, k));
  const body = `
<h1>${e("link_title")}</h1>
<p class="muted">${e("link_intro")}</p>
<section id="login" class="card">
  <form id="email-form" novalidate>
    <label for="email">${e("email")}</label>
    <input id="email" type="email" autocomplete="email" inputmode="email" maxlength="254">
    <button id="email-btn" type="submit">${e("send_code")}</button>
    <div id="email-msg" class="msg" role="status"></div>
  </form>
  <form id="otp-form" hidden novalidate>
    <label for="otp">${e("enter_code")}</label>
    <input id="otp" class="code" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="6">
    <button id="otp-btn" type="submit">${e("verify")}</button>
    <div id="otp-msg" class="msg" role="status"></div>
  </form>
</section>
<section id="approve" class="card" hidden>
  <p id="who" class="muted"></p>
  <form id="approve-form" novalidate>
    <label for="tvcode">${e("tv_code")}</label>
    <input id="tvcode" class="code" type="text" maxlength="9" placeholder="ABCD-EFGH" autocapitalize="characters" spellcheck="false" value="${pre ? escapeHtml(`${pre.slice(0, 4)}-${pre.slice(4)}`) : ""}">
    <button id="approve-btn" type="submit">${e("approve")}</button>
    <div id="approve-msg" class="msg" role="status"></div>
  </form>
  <button id="logout" class="secondary" type="button">${e("sign_out")}</button>
</section>
<footer>${langSwitch(lang, "/link", pre ? `c=${pre}` : "")}</footer>
<script type="application/json" id="i18n">${scriptJson(clientStrings(lang, CLIENT_KEYS))}</script>`;
  return renderPage({ lang, title: t(lang, "link_title"), appName, body, scripts: [LINK_SCRIPT] });
}
