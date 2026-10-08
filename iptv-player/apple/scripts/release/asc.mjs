// Minimal App Store Connect API client. Reads APPLE_ISSUER_ID / APPLE_KEY_ID / APPLE_KEY_PATH from ~/.hermes/.env.
import { readFileSync } from 'node:fs';
import { createSign } from 'node:crypto';
import os from 'node:os';
const env = Object.fromEntries(readFileSync(os.homedir() + '/.hermes/.env', 'utf8').split('\n')
  .map(l => l.match(/^([A-Z0-9_]+)=(.*)$/)).filter(Boolean).map(m => [m[1], m[2].replace(/^["']|["']$/g, '')]));
const keyPath = env.APPLE_KEY_PATH.replace(/^~/, os.homedir());
const b64u = b => Buffer.from(b).toString('base64url');
function jwt() {
  const h = b64u(JSON.stringify({ alg: 'ES256', kid: env.APPLE_KEY_ID, typ: 'JWT' }));
  const now = Math.floor(Date.now() / 1000);
  const p = b64u(JSON.stringify({ iss: env.APPLE_ISSUER_ID, iat: now, exp: now + 1100, aud: 'appstoreconnect-v1' }));
  const s = createSign('SHA256'); s.update(`${h}.${p}`);
  return `${h}.${p}.${s.sign({ key: readFileSync(keyPath), dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}
export async function api(method, path, body) {
  const r = await fetch('https://api.appstoreconnect.apple.com' + path, { method,
    headers: { authorization: 'Bearer ' + jwt(), 'content-type': 'application/json' }, body: body && JSON.stringify(body) });
  const t = await r.text(); let j; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, json: j };
}
if (process.argv[1]?.endsWith('asc.mjs') && process.argv[2]) { const [m, p, b] = process.argv.slice(2); const r = await api(m, p, b && JSON.parse(b)); console.log(r.status, JSON.stringify(r.json, null, 1).slice(0, 3000)); }
