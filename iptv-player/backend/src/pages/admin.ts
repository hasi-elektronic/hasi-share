import type { Ctx } from "../http";
import { clientStrings, pickLang, t, type StringKey } from "./i18n";
import { escapeHtml, langSwitch, renderPage, scriptJson } from "./layout";

const CLIENT_KEYS: StringKey[] = ["admin_saved", "admin_revoke", "admin_restore", "admin_none", "admin_unauthorized", "err_network"];

/** Client logic of /admin. The token is kept in sessionStorage (tab-scoped) only. */
const ADMIN_SCRIPT = `
(function () {
  "use strict";
  var T = JSON.parse(document.getElementById("i18n").textContent);
  var KEY = "adminToken";
  function $(id) { return document.getElementById(id); }
  function msg(id, text, kind) { var el = $(id); el.textContent = text || ""; el.className = "msg" + (kind ? " " + kind : ""); }
  function token() { try { return sessionStorage.getItem(KEY) || ""; } catch (e) { return ""; } }
  function setToken(v) { try { if (v) sessionStorage.setItem(KEY, v); else sessionStorage.removeItem(KEY); } catch (e) {} }
  function api(method, path, body) {
    var opts = { method: method, headers: { authorization: "Bearer " + token(), accept: "application/json" } };
    if (body !== undefined) { opts.headers["content-type"] = "application/json"; opts.body = JSON.stringify(body); }
    return fetch(path, opts).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (r.status === 401) { setToken(""); render(); throw new Error(T.admin_unauthorized); }
        if (!r.ok) throw new Error(j.message || ("HTTP " + r.status));
        return j;
      });
    });
  }
  function fail(id) { return function (e) { msg(id, e && e.message ? e.message : T.err_network, "err"); }; }
  function fmtTime(v, seconds) { if (v === null || v === undefined) return "–"; return new Date(seconds ? v * 1000 : v).toISOString().replace("T", " ").slice(0, 16) + "Z"; }
  function td(text) { var el = document.createElement("td"); el.textContent = text; return el; }
  function render() {
    var has = !!token();
    $("auth").hidden = has;
    $("panels").hidden = !has;
    if (has) loadConfig();
  }
  function loadConfig() {
    api("GET", "/v1/admin/config").then(function (c) {
      $("trialDays").value = c.trialDays;
      $("minAndroid").value = c.minVersion.android;
      $("minApple").value = c.minVersion.apple;
      $("fAccounts").checked = !!c.features.accounts;
      $("fPairing").checked = !!c.features.pairing;
      $("fSync").checked = !!c.features.sync;
    }).catch(fail("config-msg"));
  }
  $("auth-form").addEventListener("submit", function (ev) { ev.preventDefault(); setToken($("token").value.trim()); $("token").value = ""; render(); });
  $("forget").addEventListener("click", function () { setToken(""); render(); });
  $("config-form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    api("PUT", "/v1/admin/config", {
      trialDays: parseInt($("trialDays").value, 10),
      minVersion: { android: parseInt($("minAndroid").value, 10), apple: parseInt($("minApple").value, 10) },
      features: { accounts: $("fAccounts").checked, pairing: $("fPairing").checked, sync: $("fSync").checked }
    }).then(function () { msg("config-msg", T.admin_saved, "ok"); loadConfig(); }).catch(fail("config-msg"));
  });
  function target(v) { v = v.trim(); return /^acc_/.test(v) ? { accountId: v } : { deviceKey: v.toLowerCase() }; }
  $("extend-form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var body = target($("extTarget").value); body.days = parseInt($("extDays").value, 10);
    api("POST", "/v1/admin/trials/extend", body).then(function (r) {
      msg("extend-msg", r.scope + ": " + fmtTime(r.trialStart, true) + " → " + fmtTime(r.trialEnd, true), "ok");
    }).catch(fail("extend-msg"));
  });
  function action(id, what) {
    api("POST", "/v1/admin/licenses/" + encodeURIComponent(id) + "/" + what).then(search).catch(fail("search-msg"));
  }
  function search(ev) {
    if (ev && ev.preventDefault) ev.preventDefault();
    msg("search-msg", "");
    api("GET", "/v1/admin/licenses?query=" + encodeURIComponent($("query").value.trim())).then(function (r) {
      var extra = [];
      if (r.account) extra.push("account " + r.account.id + " " + r.account.email + " trial: " + (r.account.trial ? fmtTime(r.account.trial.start, true) + " → " + fmtTime(r.account.trial.end, true) : "–"));
      if (r.device) extra.push("device " + r.device.platform + " trial: " + (r.device.trial ? fmtTime(r.device.trial.start, true) + " → " + fmtTime(r.device.trial.end, true) : "–") + (r.device.accountId ? " account " + r.device.accountId : ""));
      $("search-extra").textContent = extra.join(" · ");
      var tbody = $("results"); tbody.textContent = "";
      if (!r.licenses.length) { msg("search-msg", T.admin_none); return; }
      r.licenses.forEach(function (l) {
        var tr = document.createElement("tr");
        tr.appendChild(td(l.id));
        tr.appendChild(td(l.store + " · " + l.productId));
        var st = td(""); var b = document.createElement("span"); b.className = "badge " + l.status; b.textContent = l.status + (l.revokeReason ? " (" + l.revokeReason + ")" : ""); st.appendChild(b); tr.appendChild(st);
        tr.appendChild(td(fmtTime(l.purchasedAt)));
        tr.appendChild(td((l.accountEmail || l.accountId || "–") + (l.deviceKeys.length ? " · " + l.deviceKeys.length + " device(s)" : "")));
        tr.appendChild(td((l.orderId || l.storeRef || "") + (l.note ? " · " + l.note : "")));
        var act = td(""); var btn = document.createElement("button"); btn.className = "small" + (l.status === "active" ? " secondary" : "");
        btn.textContent = l.status === "active" ? T.admin_revoke : T.admin_restore;
        btn.addEventListener("click", function () { action(l.id, l.status === "active" ? "revoke" : "restore"); });
        act.appendChild(btn); tr.appendChild(act);
        tbody.appendChild(tr);
      });
    }).catch(fail("search-msg"));
  }
  $("search-form").addEventListener("submit", search);
  $("grant-form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var body = target($("grantTarget").value); body.note = $("grantNote").value.trim();
    api("POST", "/v1/admin/licenses/grant", body).then(function (r) { msg("grant-msg", r.license.id, "ok"); }).catch(fail("grant-msg"));
  });
  render();
})();
`;

/** GET /admin – minimal single-file admin UI (talks to /v1/admin/* with the bearer token). */
export function adminPage(c: Ctx): Response {
  const lang = pickLang(c.req, c.url);
  const appName = c.env.APP_NAME || "App";
  const e = (k: StringKey) => escapeHtml(t(lang, k));
  const body = `
<h1>${escapeHtml(appName)} · ${e("admin_title")}</h1>
<section id="auth" class="card">
  <form id="auth-form" autocomplete="off">
    <label for="token">${e("admin_token")}</label>
    <input id="token" type="password" autocomplete="off">
    <button type="submit">${e("admin_save_token")}</button>
  </form>
</section>
<div id="panels" hidden>
  <section class="card">
    <h2>${e("admin_config")}</h2>
    <form id="config-form">
      <label for="trialDays">${e("admin_trial_days")}</label>
      <input id="trialDays" type="number" min="1" max="90" required>
      <div class="row">
        <div><label for="minAndroid">${e("admin_min_android")}</label><input id="minAndroid" type="number" min="0"></div>
        <div><label for="minApple">${e("admin_min_apple")}</label><input id="minApple" type="number" min="0"></div>
      </div>
      <label>${e("admin_features")}</label>
      <label class="check"><input id="fAccounts" type="checkbox">accounts</label>
      <label class="check"><input id="fPairing" type="checkbox">pairing</label>
      <label class="check"><input id="fSync" type="checkbox">sync</label>
      <button type="submit">${e("admin_save")}</button>
      <div id="config-msg" class="msg" role="status"></div>
    </form>
  </section>
  <section class="card">
    <h2>${e("admin_extend")}</h2>
    <form id="extend-form">
      <div class="row">
        <div><label for="extTarget">${e("admin_target")}</label><input id="extTarget" type="text" required spellcheck="false"></div>
        <div><label for="extDays">${e("admin_days")}</label><input id="extDays" type="number" required></div>
      </div>
      <button type="submit">${e("admin_apply")}</button>
      <div id="extend-msg" class="msg" role="status"></div>
    </form>
  </section>
  <section class="card">
    <h2>${e("admin_licenses")}</h2>
    <form id="search-form">
      <label for="query">${e("admin_search_hint")}</label>
      <input id="query" type="text" spellcheck="false">
      <button type="submit">${e("admin_search")}</button>
    </form>
    <p id="search-extra" class="muted"></p>
    <table><thead><tr><th>id</th><th>store</th><th>status</th><th>purchased</th><th>account / devices</th><th>ref</th><th></th></tr></thead><tbody id="results"></tbody></table>
    <div id="search-msg" class="msg" role="status"></div>
  </section>
  <section class="card">
    <h2>${e("admin_grant")}</h2>
    <form id="grant-form">
      <label for="grantTarget">${e("admin_target")}</label>
      <input id="grantTarget" type="text" required spellcheck="false">
      <label for="grantNote">${e("admin_note")}</label>
      <input id="grantNote" type="text" maxlength="500">
      <button type="submit">${e("admin_apply")}</button>
      <div id="grant-msg" class="msg" role="status"></div>
    </form>
  </section>
  <button id="forget" class="secondary" type="button">${e("admin_forget")}</button>
</div>
<footer>${langSwitch(lang, "/admin")}</footer>
<script type="application/json" id="i18n">${scriptJson(clientStrings(lang, CLIENT_KEYS))}</script>`;
  return renderPage({ lang, title: t(lang, "admin_title"), appName, body, scripts: [ADMIN_SCRIPT], wide: true });
}
