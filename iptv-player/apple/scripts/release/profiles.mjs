// (Re)create App Store provisioning profiles after capability changes and install them locally.
// Usage: node profiles.mjs <bundleIdentifier>=<IOS_APP_STORE|TVOS_APP_STORE>:<profile name> ...
// Existing profiles with the same name are deleted first (names are what release.sh / export plists reference).
import { api } from './asc.mjs';
import { writeFileSync, mkdirSync } from 'node:fs';
import os from 'node:os';
const certs = (await api('GET', '/v1/certificates?limit=50&fields%5Bcertificates%5D=name,certificateType,serialNumber,expirationDate')).json.data;
const dist = certs.filter(c => ['DISTRIBUTION', 'IOS_DISTRIBUTION'].includes(c.attributes.certificateType));
const dirs = [os.homedir() + '/Library/MobileDevice/Provisioning Profiles', os.homedir() + '/Library/Developer/Xcode/UserData/Provisioning Profiles'];
const existing = (await api('GET', '/v1/profiles?limit=200&fields%5Bprofiles%5D=name,profileType,profileState')).json.data ?? [];
for (const spec of process.argv.slice(2)) {
  const [ident, rest] = spec.split('='); const [type, ...nameParts] = rest.split(':'); const name = nameParts.join(':');
  const bundle = (await api('GET', `/v1/bundleIds?filter%5Bidentifier%5D=${ident}`)).json.data?.find(b => b.attributes.identifier === ident);
  if (!bundle) { console.log('missing bundle id', ident); continue; }
  for (const p of existing.filter(p => p.attributes.name === name)) console.log('delete old', name, (await api('DELETE', `/v1/profiles/${p.id}`)).status);
  const r = await api('POST', '/v1/profiles', { data: { type: 'profiles', attributes: { name, profileType: type },
    relationships: { bundleId: { data: { type: 'bundleIds', id: bundle.id } }, certificates: { data: dist.map(c => ({ type: 'certificates', id: c.id })) } } } });
  if (r.status !== 201) { console.log(name, r.status, JSON.stringify(r.json.errors?.[0]?.detail)); continue; }
  const a = r.json.data.attributes;
  for (const d of dirs) { mkdirSync(d, { recursive: true }); writeFileSync(`${d}/${a.uuid}.mobileprovision`, Buffer.from(a.profileContent, 'base64')); }
  console.log('created', name, a.uuid);
}
