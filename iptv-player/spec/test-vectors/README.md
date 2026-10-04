# Shared test vectors

Every platform (Kotlin `android/core`, Swift `apple/IPTVCore`, TypeScript `backend`)
loads these files in its unit tests. A change in behaviour = change the vector first.

| File | Contract § | Consumers |
|---|---|---|
| `m3u/*.m3u` + `*.expected.json` | §3 | Kotlin, Swift |
| `xmltv/epg_basic.xml` + `.expected.json` | §5 | Kotlin, Swift |
| `xmltv/time-parsing.json` | §5 | Kotlin, Swift |
| `xmltv/name-normalization.json` | §5 | Kotlin, Swift |
| `xtream/*.json` + `*.expected.json`, `url-vectors.json` | §4 | Kotlin, Swift |
| `content-keys.json` | §1.1, §7.1 | Kotlin, Swift, backend (deviceKey format) |
| `license-token.json` | §7.2 | Kotlin, Swift (verify), backend (sign + verify) |
| `pair-crypto.json` | §9 | Kotlin, Swift (decrypt + encrypt with fixed iv), backend page JS (encrypt) |
| `trusted-clock.json` | §7.3 | Kotlin, Swift |
| `access-policy.json` | §7.4 | Kotlin, Swift |
| `redaction.json` | §10 | Kotlin, Swift, backend |
| `media/*` + `media/expected.json` | §6 | Kotlin, Swift |
| `stream-samples.json` | §6 | Diagnostics screen on devices (manual) |

Regenerate computed vectors: `node spec/tools/gen-vectors.mjs` (fresh keys each run).

## Expected-JSON conventions

* Missing optional value → `null`. Empty strings from servers are mapped to `null`.
* Times in `*.expected.json` are **epoch seconds** unless the key ends in `Ms`.
* Compare lists in the given order (parsers keep source order; XMLTV programmes are
  sorted by `(channel, start)`).

### M3U entry (`m3u/*.expected.json`)
```
name, url, kind (live|movie|episode), tvgId, tvgName, logo, group, chno (int),
duration (number, -1 if absent), catchup {type, days, source} | null,
tvgShiftHours (number) | null, userAgent, referrer, drm (bool),
series {name, season, episode} | null
```
`catchup` is non-null when any of `catchup`, `catchup-type`, `catchup-days`,
`timeshift`, `catchup-source` is present; missing `days` → 0, missing type → `"default"`.
Error files: `{"error": "InvalidFormat" | "Empty"}`.

### Xtream mapping details (beyond CONTRACT §4.3)
* Items without an id (`stream_id`, `series_id`, `category_id`, episode `id`) are skipped.
* Channel: `number` ← `num`; `logoUrl` ← `stream_icon`; `epgId` ← `epg_channel_id`;
  `catchup` ← `tv_archive` (bool) + `tv_archive_duration` (days):
  archive → `{type:"xtream", days}`, else `{type:"none", days:0}`.
* Movie: `posterUrl` ← `stream_icon`; `rating` ← `rating` (number or numeric string; `""` → null);
  `year` ← `year` field only; `addedAt` ← `added` (epoch seconds string).
* Series: `posterUrl` ← `cover`; `year` ← `year`, else first 4 digits of `releaseDate`
  or `release_date`.
* Episode: `number` ← `episode_num`; `season` ← `season` (fallback: object key, or
  array index + 1); `durationSec` ← `info.duration_secs`; `plot` ← `info.plot`;
  `posterUrl` ← `info.movie_image`.
* Account: `serverTimezone` ← `server_info.timezone`, default `"UTC"`.
* Short EPG: base64-decode `title`/`description` (if decoding fails, use the raw string);
  empty → null; entries with unparsable timestamps are skipped; `hasArchive` ← `has_archive`.

### Media sniffing (`media/expected.json`)
Content-type comparison is case-insensitive and ignores parameters (`; charset=…`).
