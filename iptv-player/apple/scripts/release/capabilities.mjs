// List / enable bundle id capabilities. Usage: node capabilities.mjs <bundleIdentifier> [CAPABILITY_TYPE [settingsJSON]]
import { api } from './asc.mjs';
const [ident, cap, settings] = process.argv.slice(2);
const b = (await api('GET', `/v1/bundleIds?filter%5Bidentifier%5D=${ident}&include=bundleIdCapabilities`)).json;
const bundle = b.data?.find(x => x.attributes.identifier === ident);
if (!bundle) { console.log('bundle id not found:', ident); process.exit(1); }
const caps = (b.included ?? []).filter(i => i.type === 'bundleIdCapabilities').map(i => i.attributes.capabilityType);
console.log(ident, bundle.id, 'capabilities:', caps.join(', ') || '(none)');
if (cap && !caps.includes(cap)) {
  const r = await api('POST', '/v1/bundleIdCapabilities', { data: { type: 'bundleIdCapabilities',
    attributes: { capabilityType: cap, ...(settings ? { settings: JSON.parse(settings) } : {}) },
    relationships: { bundleId: { data: { type: 'bundleIds', id: bundle.id } } } } });
  console.log('enable', cap, r.status, r.json.errors?.map(e => e.detail).join('; ') ?? 'ok');
}
