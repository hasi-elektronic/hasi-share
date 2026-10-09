// Latest TestFlight builds of the app with processing state (used to wait until VALID).
import { api } from './asc.mjs';
const r = await api('GET', '/v1/builds?filter%5Bapp%5D=6819018092&sort=-uploadedDate&include=preReleaseVersion&limit=10');
const data = r.json.data ?? [];
if (!data.length) console.log('no builds visible yet');
for (const b of data) {
  const pid = b.relationships?.preReleaseVersion?.data?.id;
  const pv = (r.json.included ?? []).find(i => i.type === 'preReleaseVersions' && i.id === pid);
  console.log(pv?.attributes?.platform, pv?.attributes?.version, 'build', b.attributes.version, b.attributes.processingState);
}
