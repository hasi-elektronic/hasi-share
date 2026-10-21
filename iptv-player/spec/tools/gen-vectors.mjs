// Generates the computed cross-platform test vectors in spec/test-vectors/.
// Run: node spec/tools/gen-vectors.mjs   (Node >= 20, no dependencies)
// Crypto vectors are regenerated with fresh keys each run; commit the output.
import { createHash, webcrypto } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const subtle = webcrypto.subtle;
const out = join(dirname(fileURLToPath(import.meta.url)), '..', 'test-vectors');
const write = (name, obj) => writeFileSync(join(out, name), JSON.stringify(obj, null, 2) + '\n');
const sha256hex = (s) => createHash('sha256').update(s, 'utf8').digest('hex');
const b64u = (buf) => Buffer.from(buf).toString('base64url');
const enc = new TextEncoder();

// ---------- content keys (CONTRACT §1.1) ----------
function normalizeUrl(u) {
  const t = u.trim();
  const m = t.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^/?#]*)(.*)$/);
  if (!m) return t;
  let [, scheme, authority, rest] = m;
  scheme = scheme.toLowerCase();
  let userinfo = '';
  const at = authority.lastIndexOf('@');
  if (at >= 0) { userinfo = authority.slice(0, at + 1); authority = authority.slice(at + 1); }
  let host = authority, port = '';
  const pm = authority.match(/^(.*):(\d+)$/);
  if (pm) { host = pm[1]; port = pm[2]; }
  host = host.toLowerCase();
  if ((scheme === 'http' && port === '80') || (scheme === 'https' && port === '443')) port = '';
  return `${scheme}://${userinfo}${host}${port ? ':' + port : ''}${rest}`;
}
const fpXtream = (host, user) => sha256hex(`xtream|${host.toLowerCase()}|${user}`).slice(0, 16);
const fpM3u = (url) => sha256hex(`m3u|${normalizeUrl(url)}`).slice(0, 16);
const m3uItemId = (url) => 'u' + sha256hex(url).slice(0, 16);
const keyCases = [];
for (const [host, user, kind, id] of [
  ['iptv.example.com', 'user1', 'live', '1001'],
  ['IPTV.Example.com', 'user1', 'movie', '5001'],
  ['iptv.example.com', 'User1', 'series', '7000'],
  ['panel.example.com', 'ali.veli', 'episode', '70001'],
]) keyCases.push({ type: 'xtream', host, username: user, kind, itemId: id,
  fingerprint: fpXtream(host, user), contentKey: `${fpXtream(host, user)}:${kind}:${id}` });
for (const [url, entryUrl, kind] of [
  ['http://IPTV.example.com:80/get.php?username=a&password=b&type=m3u_plus', 'http://iptv.example.com:8080/live/a/b/1001.ts', 'live'],
  ['https://lists.example.com:443/my%20list.m3u', 'https://cdn.example.com/movies/inception.mkv', 'movie'],
  [' https://lists.example.com/list.m3u?token=XYZ ', 'http://iptv.example.com:8080/series/a/b/7002.mp4', 'episode'],
]) keyCases.push({ type: 'm3u', url, normalizedUrl: normalizeUrl(url), kind, entryUrl,
  fingerprint: fpM3u(url), itemId: m3uItemId(entryUrl), contentKey: `${fpM3u(url)}:${kind}:${m3uItemId(entryUrl)}` });
const devKey = (appId, raw) => sha256hex(`iptvp-device-v1|${appId}|${raw}`);
write('content-keys.json', {
  _note: 'CONTRACT §1.1 and §7.1. sha256 over UTF-8; hex lowercase.',
  cases: keyCases,
  deviceKeys: [
    { appId: 'de.hasielektronik.novaplayer', rawId: '9774d56d682e549c', expected: devKey('de.hasielektronik.novaplayer', '9774d56d682e549c') },
    { appId: 'de.hasielektronik.novaplayer', rawId: 'E621E1F8-C36C-495A-93FC-0C247A3E6E5F', expected: devKey('de.hasielektronik.novaplayer', 'E621E1F8-C36C-495A-93FC-0C247A3E6E5F') },
  ],
});

// ---------- license token (CONTRACT §7.2) ----------
const kp = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
const pubJwk = await subtle.exportKey('jwk', kp.publicKey);
const privJwk = await subtle.exportKey('jwk', kp.privateKey);
const other = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
async function sign(header, payload, key = kp.privateKey) {
  const input = `${b64u(enc.encode(JSON.stringify(header)))}.${b64u(enc.encode(JSON.stringify(payload)))}`;
  const sig = await subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(input));
  return `${input}.${b64u(sig)}`;
}
const iat = 1759570000;
const base = { iss: 'iptvp-license', aud: 'de.hasielektronik.novaplayer', sub: devKey('de.hasielektronik.novaplayer', '9774d56d682e549c'), iat, exp: iat + 14 * 86400,
  lic: { purchased: false, src: null, trialStart: iat, trialEnd: iat + 7 * 86400, acct: null } };
const hdr = { alg: 'ES256', kid: 'test-1', typ: 'JWT' };
const valid = await sign(hdr, base);
const purchased = await sign(hdr, { ...base, lic: { purchased: true, src: 'google', trialStart: iat, trialEnd: iat + 7 * 86400, acct: 'acc_123' } });
const [h, p, s] = valid.split('.');
const tamperedPayload = b64u(enc.encode(JSON.stringify({ ...base, lic: { ...base.lic, purchased: true } })));
write('license-token.json', {
  _note: 'CONTRACT §7.2. nowEpochSeconds is the verification time. stale = exp passed (still valid).',
  keys: { 'test-1': { kty: 'EC', crv: 'P-256', x: pubJwk.x, y: pubJwk.y } },
  privateKeyForBackendTests: { kid: 'test-1', jwk: privJwk },
  issuer: 'iptvp-license', audience: 'de.hasielektronik.novaplayer',
  cases: [
    { name: 'valid', token: valid, nowEpochSeconds: iat + 60, expected: { valid: true, stale: false, claims: base } },
    { name: 'valid-purchased', token: purchased, nowEpochSeconds: iat + 60, expected: { valid: true, stale: false, claims: { ...base, lic: { purchased: true, src: 'google', trialStart: iat, trialEnd: iat + 7 * 86400, acct: 'acc_123' } } } },
    { name: 'stale-but-valid', token: valid, nowEpochSeconds: iat + 15 * 86400, expected: { valid: true, stale: true, claims: base } },
    { name: 'tampered-payload', token: `${h}.${tamperedPayload}.${s}`, nowEpochSeconds: iat + 60, expected: { valid: false, reason: 'signature' } },
    { name: 'unknown-kid', token: await sign({ ...hdr, kid: 'nope' }, base), nowEpochSeconds: iat + 60, expected: { valid: false, reason: 'kid' } },
    { name: 'wrong-key', token: await sign(hdr, base, other.privateKey), nowEpochSeconds: iat + 60, expected: { valid: false, reason: 'signature' } },
    { name: 'alg-none', token: `${b64u(enc.encode(JSON.stringify({ alg: 'none', kid: 'test-1', typ: 'JWT' })))}.${p}.`, nowEpochSeconds: iat + 60, expected: { valid: false, reason: 'alg' } },
    { name: 'wrong-audience', token: await sign(hdr, { ...base, aud: 'com.other.app' }), nowEpochSeconds: iat + 60, expected: { valid: false, reason: 'aud' } },
    { name: 'wrong-issuer', token: await sign(hdr, { ...base, iss: 'someone' }), nowEpochSeconds: iat + 60, expected: { valid: false, reason: 'iss' } },
    { name: 'malformed', token: 'abc.def', nowEpochSeconds: iat + 60, expected: { valid: false, reason: 'format' } },
  ],
});

// ---------- pairing crypto (CONTRACT §9) ----------
const tv = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
const eph = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
const z = await subtle.deriveBits({ name: 'ECDH', public: tv.publicKey }, eph.privateKey, 256);
const hk = await subtle.importKey('raw', z, 'HKDF', false, ['deriveKey']);
const aes = await subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: enc.encode('iptvp-pair-v1') },
  hk, { name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']);
const rawKey = await subtle.exportKey('raw', aes);
const iv = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
const plaintext = JSON.stringify({ v: 1, type: 'xtream', name: 'Ev', server: 'http://iptv.example.com:8080', username: 'user1', password: 'p@ss/w rd çğ' });
const ct = await subtle.encrypt({ name: 'AES-GCM', iv }, aes, enc.encode(plaintext));
const pub = (j) => ({ kty: 'EC', crv: 'P-256', x: j.x, y: j.y });
write('pair-crypto.json', {
  _note: 'CONTRACT §9. ct = AES-256-GCM ciphertext || 16-byte tag. HKDF salt empty, info "iptvp-pair-v1".',
  tvPrivateJwk: await subtle.exportKey('jwk', tv.privateKey),
  tvPublicJwk: pub(await subtle.exportKey('jwk', tv.publicKey)),
  senderPrivateJwk: await subtle.exportKey('jwk', eph.privateKey),
  senderPublicJwk: pub(await subtle.exportKey('jwk', eph.publicKey)),
  sharedSecretHex: Buffer.from(z).toString('hex'),
  aesKeyHex: Buffer.from(rawKey).toString('hex'),
  payload: { epk: pub(await subtle.exportKey('jwk', eph.publicKey)), iv: b64u(iv), ct: b64u(ct) },
  plaintext,
});

// ---------- trusted clock (CONTRACT §7.3) ----------
const st = { serverMs: 10000, monoMs: 100, bootId: 'a' };
write('trusted-clock.json', {
  _note: 'CONTRACT §7.3. expected = trusted now in ms.',
  cases: [
    { name: 'no-state', state: null, wallMs: 1000, monoMs: 50, bootId: 'a', expected: 1000 },
    { name: 'same-boot-clock-rolled-back', state: st, wallMs: 5000, monoMs: 600, bootId: 'a', expected: 10500 },
    { name: 'same-boot-clock-forward-ignored', state: st, wallMs: 99999, monoMs: 600, bootId: 'a', expected: 10500 },
    { name: 'rebooted-wall-behind', state: st, wallMs: 5000, monoMs: 10, bootId: 'b', expected: 10000 },
    { name: 'rebooted-wall-ahead', state: st, wallMs: 20000, monoMs: 10, bootId: 'b', expected: 20000 },
    { name: 'mono-went-backwards', state: st, wallMs: 4000, monoMs: 50, bootId: 'a', expected: 10000 },
    { name: 'unknown-boot-id', state: { serverMs: 10000, monoMs: 100, bootId: '' }, wallMs: 5000, monoMs: 600, bootId: '', expected: 10000 },
  ],
  updates: [
    { name: 'newer-server-time-replaces', state: st, update: { serverMs: 20000, monoMs: 700, bootId: 'a' }, expectedState: { serverMs: 20000, monoMs: 700, bootId: 'a' } },
    { name: 'older-server-time-ignored', state: st, update: { serverMs: 9000, monoMs: 700, bootId: 'a' }, expectedState: st },
  ],
});

// ---------- access policy (CONTRACT §7.4) ----------
const D = 86400000, T = 1759570000000;
const lic = (o) => ({ purchased: false, src: null, trialStart: T / 1000, trialEnd: (T + 7 * D) / 1000, acct: null, ...o });
const ap = (name, input, expected) => ({ name, input: { platformStore: 'google', store: 'none', token: null, localTrialStartMs: null, trialDays: 7, ...input }, expected });
write('access-policy.json', {
  _note: 'CONTRACT §7.4. token = lic claims object (already validated) or null. Times: token seconds, others ms.',
  cases: [
    ap('fresh-install', { nowMs: T }, { state: 'TRIAL_NOT_STARTED', trialEndMs: null, canPlay: false, pendingPurchase: false }),
    ap('trial-active', { token: lic({}), nowMs: T + D }, { state: 'TRIAL_ACTIVE', trialEndMs: T + 7 * D, canPlay: true, pendingPurchase: false }),
    ap('trial-ends-exactly', { token: lic({}), nowMs: T + 7 * D }, { state: 'TRIAL_EXPIRED', trialEndMs: T + 7 * D, canPlay: false, pendingPurchase: false }),
    ap('store-purchased', { store: 'purchased', nowMs: T }, { state: 'PURCHASED', trialEndMs: null, canPlay: true, pendingPurchase: false }),
    ap('license-purchased-other-platform', { token: lic({ purchased: true, src: 'account' }), nowMs: T + 30 * D }, { state: 'PURCHASED', trialEndMs: T + 7 * D, canPlay: true, pendingPurchase: false }),
    ap('pending-during-trial', { store: 'pending', token: lic({}), nowMs: T + D }, { state: 'TRIAL_ACTIVE', trialEndMs: T + 7 * D, canPlay: true, pendingPurchase: true }),
    ap('pending-after-trial', { store: 'pending', token: lic({}), nowMs: T + 8 * D }, { state: 'TRIAL_EXPIRED', trialEndMs: T + 7 * D, canPlay: false, pendingPurchase: true }),
    ap('refunded-expired', { store: 'revoked', token: lic({}), nowMs: T + 8 * D }, { state: 'TRIAL_EXPIRED', trialEndMs: T + 7 * D, canPlay: false, pendingPurchase: false }),
    ap('refunded-stale-license-same-store', { store: 'revoked', token: lic({ purchased: true, src: 'google' }), nowMs: T + 8 * D }, { state: 'TRIAL_EXPIRED', trialEndMs: T + 7 * D, canPlay: false, pendingPurchase: false }),
    ap('refunded-here-but-account-license', { store: 'revoked', token: lic({ purchased: true, src: 'account' }), nowMs: T + 8 * D }, { state: 'PURCHASED', trialEndMs: T + 7 * D, canPlay: true, pendingPurchase: false }),
    ap('apple-local-trial', { platformStore: 'apple', localTrialStartMs: T, nowMs: T + 3 * D }, { state: 'TRIAL_ACTIVE', trialEndMs: T + 7 * D, canPlay: true, pendingPurchase: false }),
    ap('apple-local-trial-14-days', { platformStore: 'apple', localTrialStartMs: T, trialDays: 14, nowMs: T + 10 * D }, { state: 'TRIAL_ACTIVE', trialEndMs: T + 14 * D, canPlay: true, pendingPurchase: false }),
    ap('token-trial-wins-over-local', { platformStore: 'apple', localTrialStartMs: T, trialDays: 14, token: lic({}), nowMs: T + 10 * D }, { state: 'TRIAL_EXPIRED', trialEndMs: T + 7 * D, canPlay: false, pendingPurchase: false }),
    ap('token-without-trial', { token: lic({ trialStart: null, trialEnd: null }), nowMs: T }, { state: 'TRIAL_NOT_STARTED', trialEndMs: null, canPlay: false, pendingPurchase: false }),
  ],
});

// ---------- redaction (CONTRACT §10) ----------
write('redaction.json', {
  _note: 'CONTRACT §10. secrets = registered secret values for the case.',
  cases: [
    { input: 'GET http://iptv.example.com:8080/player_api.php?username=user1&password=secret123&action=get_live_streams', secrets: [], expected: 'GET http://iptv.example.com:8080/player_api.php?username=***&password=***&action=get_live_streams' },
    { input: 'Playing http://iptv.example.com:8080/live/user1/secret123/1001.ts', secrets: [], expected: 'Playing http://iptv.example.com:8080/live/***/***/1001.ts' },
    { input: 'http://admin:hunter2@cam.example.com/stream?token=a1', secrets: [], expected: 'http://***@cam.example.com/stream?token=***' },
    { input: 'Authorization: Bearer abc.def-ghi_jkl', secrets: [], expected: 'Authorization: Bearer ***' },
    { input: 'url=https://cdn.example.com/x.m3u8?token=XYZ&expires=123', secrets: [], expected: 'url=https://cdn.example.com/x.m3u8?token=***&expires=123' },
    { input: 'login failed for s3cr3tP4ss on host', secrets: ['s3cr3tP4ss'], expected: 'login failed for *** on host' },
    { input: '/timeshift/user1/secret123/90/2025-10-04:18-30/1001.ts', secrets: [], expected: '/timeshift/***/***/90/2025-10-04:18-30/1001.ts' },
    { input: 'api_key=AAA&apikey=BBB&sig=CCC&monkey=ok', secrets: [], expected: 'api_key=***&apikey=***&sig=***&monkey=ok' },
    { input: 'Pass=abc PWD=x', secrets: [], expected: 'Pass=*** PWD=***' },
    { input: 'nothing secret here: channel 5 OK', secrets: ['ab'], expected: 'nothing secret here: channel 5 OK' },
    { input: 'm3u http://lists.example.com/get.php?username=ali&password=veli123&type=m3u_plus', secrets: ['veli123', 'ali'], expected: 'm3u http://lists.example.com/get.php?username=***&password=***&type=m3u_plus' },
  ],
});
console.log('vectors written to', out);
