import { api } from './asc.mjs';
const APP = '6819018092';
const r = await api('GET', `/v1/builds?filter[app]=${APP}&sort=-uploadedDate&limit=4&include=buildBetaDetail,preReleaseVersion`);
const det = Object.fromEntries((r.json.included ?? []).filter(i => i.type === 'buildBetaDetails').map(i => [i.id, i.attributes]));
const pre = Object.fromEntries((r.json.included ?? []).filter(i => i.type === 'preReleaseVersions').map(i => [i.id, i.attributes.platform]));
for (const b of r.json.data) {
  const d = det[b.relationships.buildBetaDetail.data?.id] ?? {};
  console.log(pre[b.relationships.preReleaseVersion.data?.id], 'build', b.attributes.version, b.attributes.processingState, 'internal:', d.internalBuildState, 'expired:', b.attributes.expired);
}
