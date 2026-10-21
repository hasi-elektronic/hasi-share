import type { Ctx } from "../http";
import { normalizePairCode } from "../pair";
import { clientStrings, pickLang, t, type StringKey } from "./i18n";
import { escapeHtml, langSwitch, renderPage, scriptJson } from "./layout";
import { pairEncryptSource } from "./pairCrypto";

const CLIENT_KEYS: StringKey[] = [
  "err_code_format",
  "err_code_unknown",
  "err_code_expired",
  "err_code_used",
  "err_required",
  "err_url",
  "err_network",
  "err_too_many",
  "err_crypto",
  "pair_sending",
];

/** Client logic of /pair (plain ES2017, no template literals, no external resources). */
const PAIR_SCRIPT = `
(function () {
  "use strict";
  var T = JSON.parse(document.getElementById("i18n").textContent);
  var ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
  var state = { code: null, key: null };
  function $(id) { return document.getElementById(id); }
  function msg(id, text, kind) { var el = $(id); el.textContent = text || ""; el.className = "msg" + (kind ? " " + kind : ""); }
  function norm(s) { return String(s || "").toUpperCase().replace(/[\\s-]+/g, ""); }
  function valid(c) { if (c.length !== 6) return false; for (var i = 0; i < c.length; i++) if (ALPHABET.indexOf(c[i]) < 0) return false; return true; }
  function fmt(c) { return c.slice(0, 3) + "-" + c.slice(3); }
  function isHttpUrl(s) { try { var u = new URL(s); return u.protocol === "http:" || u.protocol === "https:"; } catch (e) { return false; } }
  function hostOf(s) { try { return new URL(/^[a-z]+:\\/\\//i.test(s) ? s : "http://" + s).hostname; } catch (e) { return ""; } }
  function show(step) { ["step-code", "step-form", "step-done"].forEach(function (id) { $(id).hidden = id !== step; }); }
  function errorFor(status) {
    if (status === 404) return T.err_code_unknown;
    if (status === 410) return T.err_code_expired;
    if (status === 409) return T.err_code_used;
    if (status === 429) return T.err_too_many;
    return T.err_network;
  }
  if (!window.crypto || !window.crypto.subtle || typeof window.iptvpPairEncrypt !== "function") {
    msg("code-msg", T.err_crypto, "err");
    $("code-btn").disabled = true;
    return;
  }
  function lookup(code) {
    msg("code-msg", "");
    $("code-btn").disabled = true;
    return fetch("/v1/pair/sessions/" + encodeURIComponent(code) + "/key", { headers: { accept: "application/json" } })
      .then(function (r) {
        if (!r.ok) { msg("code-msg", errorFor(r.status), "err"); return; }
        return r.json().then(function (j) {
          state.code = code; state.key = j.publicKey;
          $("code-label").textContent = fmt(code);
          show("step-form");
          $("f-name").focus();
        });
      })
      .catch(function () { msg("code-msg", T.err_network, "err"); })
      .then(function () { $("code-btn").disabled = false; });
  }
  $("code-form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var c = norm($("code").value);
    if (!valid(c)) { msg("code-msg", T.err_code_format, "err"); return; }
    lookup(c);
  });
  function currentType() { return $("type-xtream").checked ? "xtream" : "m3u"; }
  function syncType() {
    var x = currentType() === "xtream";
    $("m3u-fields").hidden = x; $("xtream-fields").hidden = !x;
  }
  $("type-m3u").addEventListener("change", syncType);
  $("type-xtream").addEventListener("change", syncType);
  $("show-pw").addEventListener("change", function () { $("f-password").type = $("show-pw").checked ? "text" : "password"; });
  $("source-form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    msg("form-msg", "");
    var type = currentType();
    var name = $("f-name").value.trim();
    var payload;
    if (type === "m3u") {
      var url = $("f-url").value.trim(), epg = $("f-epg").value.trim();
      if (!url) { msg("form-msg", T.err_required, "err"); return; }
      if (!isHttpUrl(url) || (epg && !isHttpUrl(epg))) { msg("form-msg", T.err_url, "err"); return; }
      payload = { v: 1, type: "m3u", name: name || hostOf(url), url: url };
      if (epg) payload.epgUrl = epg;
    } else {
      var server = $("f-server").value.trim(), user = $("f-username").value, pass = $("f-password").value;
      if (!server || !user.trim() || !pass) { msg("form-msg", T.err_required, "err"); return; }
      if (/^[a-z][a-z0-9+.-]*:\\/\\//i.test(server) && !isHttpUrl(server)) { msg("form-msg", T.err_url, "err"); return; }
      payload = { v: 1, type: "xtream", name: name || hostOf(server), server: server, username: user.trim(), password: pass };
    }
    $("send-btn").disabled = true;
    msg("form-msg", T.pair_sending);
    window.iptvpPairEncrypt(state.key, JSON.stringify(payload))
      .then(function (enc) {
        payload = null;
        return fetch("/v1/pair/sessions/" + encodeURIComponent(state.code) + "/payload", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(enc)
        });
      })
      .then(function (r) {
        if (r.ok) {
          $("source-form").reset();
          show("step-done");
          return;
        }
        msg("form-msg", errorFor(r.status), "err");
      })
      .catch(function () { msg("form-msg", T.err_network, "err"); })
      .then(function () { $("send-btn").disabled = false; });
  });
  var pre = norm(new URLSearchParams(location.search).get("c"));
  if (pre) { $("code").value = fmt(pre); if (valid(pre)) lookup(pre); }
})();
`;

/** GET /pair – phone page that encrypts a source for the TV (CONTRACT §9). */
export function pairPage(c: Ctx): Response {
  const lang = pickLang(c.req, c.url);
  const appName = c.env.APP_NAME || "App";
  const pre = normalizePairCode(c.url.searchParams.get("c") ?? "");
  const e = (k: StringKey) => escapeHtml(t(lang, k));
  const body = `
<h1>${e("pair_title")}</h1>
<p class="muted">${e("pair_intro")}</p>
<section id="step-code" class="card">
  <form id="code-form" autocomplete="off" novalidate>
    <label for="code">${e("pair_code")}</label>
    <input id="code" class="code" type="text" inputmode="text" maxlength="7" placeholder="ABC-123" autocapitalize="characters" spellcheck="false" value="${pre ? escapeHtml(`${pre.slice(0, 3)}-${pre.slice(3)}`) : ""}">
    <button id="code-btn" type="submit">${e("pair_continue")}</button>
    <div id="code-msg" class="msg" role="status"></div>
  </form>
</section>
<section id="step-form" class="card" hidden>
  <p>${e("pair_for_code")}: <strong id="code-label"></strong></p>
  <form id="source-form" autocomplete="off" novalidate>
    <label>${e("pair_type")}</label>
    <div class="seg">
      <label><input type="radio" name="type" id="type-m3u" value="m3u" checked>${e("pair_m3u")}</label>
      <label><input type="radio" name="type" id="type-xtream" value="xtream">${e("pair_xtream")}</label>
    </div>
    <label for="f-name">${e("field_name")}</label>
    <input id="f-name" type="text" maxlength="100">
    <div id="m3u-fields">
      <label for="f-url">${e("field_m3u_url")}</label>
      <input id="f-url" type="url" inputmode="url" spellcheck="false" autocapitalize="off" placeholder="https://">
      <label for="f-epg">${e("field_epg_url")}</label>
      <input id="f-epg" type="url" inputmode="url" spellcheck="false" autocapitalize="off" placeholder="https://">
    </div>
    <div id="xtream-fields" hidden>
      <label for="f-server">${e("field_server")}</label>
      <input id="f-server" type="url" inputmode="url" spellcheck="false" autocapitalize="off" placeholder="http://host:port">
      <label for="f-username">${e("field_username")}</label>
      <input id="f-username" type="text" spellcheck="false" autocapitalize="off">
      <label for="f-password">${e("field_password")}</label>
      <input id="f-password" type="password" autocomplete="new-password">
      <label class="check"><input id="show-pw" type="checkbox">${e("show_password")}</label>
    </div>
    <button id="send-btn" type="submit">${e("pair_send")}</button>
    <div id="form-msg" class="msg" role="status"></div>
  </form>
  <p class="muted">🔒 ${e("pair_e2e")}</p>
</section>
<section id="step-done" class="card" hidden>
  <h2>${e("pair_done_title")}</h2>
  <p>${e("pair_done")}</p>
</section>
<footer><p>${e("legal_no_content")}</p>${langSwitch(lang, "/pair", pre ? `c=${pre}` : "")}</footer>
<script type="application/json" id="i18n">${scriptJson(clientStrings(lang, CLIENT_KEYS))}</script>`;
  return renderPage({ lang, title: t(lang, "pair_title"), appName, body, scripts: [pairEncryptSource(), PAIR_SCRIPT] });
}
