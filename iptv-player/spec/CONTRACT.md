# Cross-Platform Contract (normative)

This file is the **single source of truth** shared by the Android family (Kotlin),
the Apple family (Swift) and the backend (TypeScript). Every rule here has
test vectors in `spec/test-vectors/`; all three code bases must pass them.

Language: technical contract in English (identifiers), user docs in Turkish.

---

## 0. Placeholders & identifiers

| Item | Placeholder value | Where it is defined (only place) |
|---|---|---|
| Display name | `NovaPlayer` | Android `android/gradle.properties` → `APP_NAME`; Apple `apple/Config/Shared.xcconfig` → `APP_DISPLAY_NAME`; backend `wrangler.toml` → `APP_NAME` |
| Android applicationId | `de.hasielektronik.novaplayer` | `android/gradle.properties` → `APP_ID` |
| Apple bundle id (iOS **and** tvOS, same id → Universal Purchase) | `de.hasielektronik.novaplayer` | `apple/Config/Shared.xcconfig` → `APP_BUNDLE_ID` |
| Google one-time product (non-consumed INAPP) | `lifetime_access` | `gradle.properties` → `PRODUCT_LIFETIME` + backend `GOOGLE_PRODUCT_ID` |
| Apple non-consumable (full unlock) | `de.hasielektronik.novaplayer.lifetime` | xcconfig `PRODUCT_LIFETIME` + backend `APPLE_PRODUCT_ID` |
| Apple non-consumable, price tier 0 (trial marker, name "7-day Trial") | `de.hasielektronik.novaplayer.trial` | xcconfig `PRODUCT_TRIAL` + backend `APPLE_TRIAL_PRODUCT_ID` |

Code packages/modules are **name-neutral** (`io.iptvplayer.*`, `IPTVCore`, `IPTVKit`),
so renaming the product never touches source code.

Protocol constants (never change once shipped):

```
DEVICE_KEY_PREFIX   = "iptvp-device-v1"
PAIR_HKDF_INFO      = "iptvp-pair-v1"
LICENSE_ISSUER      = "iptvp-license"
```

---

## 1. Domain model

All timestamps in code are UTC instants. Wire format: epoch **milliseconds** for
sync/progress, epoch **seconds** for JWT claims (JWT convention).

```
SourceType      = M3U | XTREAM
ContentKind     = live | movie | series | episode

Source {
  id: UUID string
  name: string
  type: SourceType
  displayHost: string            // host only, for UI ("example.com") – never secrets
  epgUrlOverride: bool
  epgShiftMinutes: int = 0       // user correction for wrong EPG offsets
  autoRefreshHours: int = 24
  createdAt, lastRefreshAt?: instant
  lastRefreshResult?: SourceStatus
  xtreamAccount?: { status, expiresAt?, maxConnections?, activeConnections?,
                    allowedOutputFormats: [string], serverTimezone: string }
}

SourceSecrets   (ONLY in Keychain / Android-Keystore-encrypted storage, keyed by Source.id)
  M3U:    { url, epgUrl? , userAgent? }
  XTREAM: { serverUrl, username, password, epgUrl? }

Category  { sourceId, id, kind(live|movie|series), name, sort }
Channel   { sourceId, id, name, number?, logoUrl?, categoryId?, epgId?,
            catchup: {type: none|xtream|default|append|shift|flussonic, days, source?},
            url? (M3U only), userAgent?, referrer?, drm: bool, sort }
Movie     { sourceId, id, name, posterUrl?, categoryId?, rating?, year?, plot?,
            containerExt?, url? (M3U only), addedAt? }
Series    { sourceId, id, name, posterUrl?, categoryId?, plot?, rating?, year? }
Episode   { sourceId, id, seriesId, season, number, title, containerExt?, durationSec?,
            plot?, posterUrl?, url? (M3U only) }
EpgProgram{ sourceId, channelEpgId, start, end, title, description?, category? }
```

Xtream stream URLs are **never persisted** (they contain credentials); they are
built at play time from `SourceSecrets` (§4.5). M3U URLs are content and are
persisted in the app-private database (excluded from cloud/device backups).

### 1.1 Source fingerprint & content key

```
xtreamFingerprint = hex(sha256("xtream|" + lowercase(host) + "|" + username))[0..16]
m3uFingerprint    = hex(sha256("m3u|"    + normalizeUrl(url)))[0..16]

normalizeUrl(u): trim; lowercase scheme and host; drop default port (:80 for http,
                 :443 for https); keep path, query and fragment byte-exact.
host for Xtream = host part of the normalized server URL (§4.1), port excluded.

itemId:
  XTREAM: decimal id as given by server (stream_id / series_id / episode id)
  M3U:    "u" + hex(sha256(entry.url))[0..16]

contentKey = fingerprint + ":" + kind + ":" + itemId
```

Vectors: `test-vectors/content-keys.json`.

---

## 2. Error taxonomy (identical on all platforms)

```
SourceError =
  Network(reason: timeout | dns | refused | tls | offline | other)
  InvalidCredentials          // Xtream auth=0, HTTP 401/403 on player_api, empty user_info
  AccountExpired(expiresAt?)  // status "Expired" or exp_date < now
  AccountDisabled             // status "Banned" | "Disabled"
  NotFound                    // HTTP 404 on list/EPG URL
  ServerError(httpStatus)     // 5xx and other non-2xx
  InvalidFormat               // not an M3U / not XMLTV
  InvalidResponse             // Xtream: body is not the expected JSON (e.g. HTML)
  Empty                       // parsed fine, zero playable items
  Cancelled

PlaybackError =
  Network | AccessDenied(401/403) | StreamOffline(404/410) | ServerError(code)
  UnsupportedFormat(container) | UnsupportedCodec(codec?) | Drm | Unknown(message)
```

Each maps to a localized, actionable message (TR + EN) – see `docs/SCREENS.md` §Errors.
Retry for source GETs: at most 2 retries (2 s, 4 s) on `Network`/`ServerError(5xx)`;
never on 4xx. All requests: connect timeout 10 s, read timeout 30 s, whole-call
timeout 120 s for playlists/EPG, 20 s for Xtream JSON calls; all cancellable.

---

## 3. M3U parsing (`test-vectors/m3u/*`)

1. Strip UTF-8 BOM. Split on `\n`, strip trailing `\r`, trim whitespace. Skip empty lines.
2. `#EXTM3U` header is optional. Header attributes `url-tvg` and `x-tvg-url`
   (value may be comma-separated) → `epgUrls` (deduplicated, order kept).
3. `#EXTINF:<duration>[ <attrs>],<title>`
   * Split the text after `#EXTINF:` at the **first comma that is not inside quotes**
     (a quote char `"`/`'` opens only at the start of an attribute value) into
     `head` and `title`. If quotes are unbalanced and no such comma exists, split at
     the **last** comma. No comma at all → title empty.
   * `head` = `<duration>` followed by attributes `key=value`; value in `"double"`,
     `'single'` quotes or unquoted (until whitespace). An unterminated quoted value
     extends to the end of `head`. Keys are lowercased.
   * title trimmed. Empty title → `tvg-name` → last URL path segment.
   * duration: integer/float; unparsable → -1.
4. `#EXTGRP:<name>` → group if `group-title` absent.
5. `#EXTVLCOPT:http-user-agent=<v>`, `#EXTVLCOPT:http-referrer=<v>` (also `http-referer`).
6. `#KODIPROP:inputstream.adaptive.license_type=…` or `…license_key=…` → `drm=true`.
7. Other `#` lines are ignored. The next non-`#` line is the URL; it finalizes the entry.
   * A URL without preceding `#EXTINF` is still accepted (name = last path segment).
   * URL scheme must be one of `http https rtmp rtmps rtsp udp rtp`; otherwise the
     entry is dropped and `skipped += 1`. `#EXTINF` followed by another `#EXTINF`
     (no URL) → first one dropped, `skipped += 1`.
8. Attributes used: `tvg-id`, `tvg-name`, `tvg-logo`, `group-title`, `tvg-chno`
   (int), `catchup`/`catchup-type`, `catchup-days`/`timeshift` (int days),
   `catchup-source`, `tvg-shift` (float hours). Empty attribute values → null.
9. Kind classification (first match):
   1. path contains `/movie/` → `movie`
   2. path contains `/series/` → `episode`
   3. path extension ∈ {mp4, mkv, avi, mov, m4v, wmv, flv, webm, mpg, mpeg} → `movie`
      (or `episode` if the title matches the series regex below)
   4. otherwise → `live`
10. Series regex on title (case-insensitive):
    `^(.*?)[\s._-]*S(\d{1,2})[\s._-]*E(\d{1,3})\b` → `series: {name: trimmed $1, season, episode}`.
11. Result:
    * zero entries **and** no `#EXTM3U` header **and** no `#EXTINF` line →
      `InvalidFormat` (HTML error page, empty file, random text);
    * zero entries otherwise → `Empty`.
    * Group null/empty → UI shows localized "Other/Diğer".
12. Parsing is streaming (line by line from the network stream) and emits in batches
    of ≤ 1000 entries; it must never hold the raw file in memory as one string.

Expected-output schema: see `test-vectors/m3u/README.md`.

---

## 4. Xtream Codes (`test-vectors/xtream/*`)

### 4.1 Server URL normalization
* trim; if no scheme → `http://`; lowercase scheme+host; drop default port;
  strip trailing `/`; strip a trailing `player_api.php`, `get.php`, `xmltv.php`
  (with any query) the user may have pasted; keep a non-empty base path (e.g. `/c`).
* `base = scheme://host[:port][/path]`.

### 4.2 Endpoints (GET, query-encoded)
```
{base}/player_api.php?username=U&password=P                       → account
{base}/player_api.php?username=U&password=P&action=get_live_categories
                                                  …&action=get_vod_categories
                                                  …&action=get_series_categories
                                                  …&action=get_live_streams
                                                  …&action=get_vod_streams
                                                  …&action=get_series
                                                  …&action=get_vod_info&vod_id=ID
                                                  …&action=get_series_info&series_id=ID
                                                  …&action=get_short_epg&stream_id=ID&limit=N
                                                  …&action=get_simple_data_table&stream_id=ID
{base}/xmltv.php?username=U&password=P                             → full XMLTV
```

### 4.3 Lenient decoding (servers are inconsistent)
* Numbers may arrive as JSON number, numeric string, `""` or `null` → int?/double?.
* Booleans: `1`, `"1"`, `true` → true; anything else false.
* Objects that are empty may arrive as `[]` (e.g. `info: []`, `user_info: []`).
* `get_series_info.episodes` is either an object `{"1":[…],"2":[…]}` or an array of
  arrays `[[…],[…]]` (season = episode.season field, fallback index+1).
* Strings may contain HTML entities – leave as-is (UI layer may decode).
* Short EPG `title`/`description` are **base64** (UTF-8). Prefer
  `start_timestamp`/`stop_timestamp` (epoch seconds, UTC) over `start`/`end` strings.
* Unknown fields are ignored; a single malformed item is skipped, not fatal.

### 4.4 Account classification (from `player_api.php` without action)
| Condition (first match) | Result |
|---|---|
| network failure | `Network(reason)` |
| HTTP 401 / 403 | `InvalidCredentials` |
| HTTP 404 | `NotFound` |
| other non-2xx | `ServerError(code)` |
| body not JSON object | `InvalidResponse` |
| `user_info` missing, `[]`, or `auth` ≠ 1 | `InvalidCredentials` |
| `status` = `Expired` | `AccountExpired(exp_date)` |
| `status` ∈ {`Banned`, `Disabled`} | `AccountDisabled` |
| `exp_date` present and < now | `AccountExpired(exp_date)` |
| otherwise | OK |

After a successful refresh: no live + no vod + no series items → `Empty`.

### 4.5 Playback URLs
```
live:     {base}/live/{U}/{P}/{stream_id}.{ext}       ext = ts | m3u8
movie:    {base}/movie/{U}/{P}/{stream_id}.{container_extension}
episode:  {base}/series/{U}/{P}/{episode_id}.{container_extension}
catch-up: {base}/timeshift/{U}/{P}/{durationMinutes}/{start}/{stream_id}.{ext}
          start = programme start formatted "yyyy-MM-dd:HH-mm" in the SERVER timezone
          (server_info.timezone, fallback UTC); durationMinutes = ceil((end-start)/60s)
```
U and P are percent-encoded: **every UTF-8 byte except the RFC 3986 unreserved set
`A–Z a–z 0–9 - . _ ~` is encoded as `%XX` (uppercase hex)** – for path segments and
query values alike (space → `%20`, never `+`). Same rule for all query strings built
by the apps.
Live `ext`: Android → `ts` if allowed else `m3u8`; Apple → `m3u8` (AVPlayer cannot
play progressive MPEG-TS). `allowed_output_formats` missing/empty ⇒ both allowed.
Apple + only `ts` allowed ⇒ `PlaybackError.UnsupportedFormat("mpegts")`
with the "ask your provider for HLS" message.

---

## 5. XMLTV EPG (`test-vectors/xmltv/*`)

* Streaming pull parser. Input may be gzip (magic `1f 8b`) regardless of extension.
* `<channel id>` → `display-name` (all), `icon@src`.
* `<programme start stop channel>`; children `title` (pick `lang` matching UI language,
  else first), `desc` (same rule), `category` (first).
* Time: `YYYYMMDDhhmm[ss][ ±hhmm]`. Missing offset ⇒ **UTC**. Then add the source's
  `epgShiftMinutes`.
* Missing/invalid `stop` ⇒ next programme start on the same channel, else start + 30 min.
* Programmes with end ≤ start are dropped.
* Retention window in storage: `[now − max(catchupDays, 1 day), now + 7 days]`.
* Channel matching: `programme.channel` == `Channel.epgId` (case-insensitive) first;
  fallback by normalized name: lowercase → remove diacritics → remove tokens
  `hd fhd uhd 4k sd hevc h265 tr de en` (whole words) and anything in `[]`/`()` →
  remove all non-alphanumerics. Vectors: `xmltv/name-normalization.json`.
* Display: always convert to the **device time zone** (user may override in
  Settings → "EPG time zone"); never format in the server's zone except for §4.5.

---

## 6. Stream format detection (`test-vectors/media/*`, `stream-samples.json`)

`detectContainer(url, contentType?, firstBytes?)` → `hls | dash | mpegts | mp4 |
mkv | webm | flv | avi | rtmp | rtsp | udp | unknown`, order:
1. scheme `rtmp*` → rtmp, `rtsp` → rtsp, `udp`/`rtp` → udp
2. bytes sniff (if ≥ 4 bytes): `#EXTM3U` → hls; `<?xml…<MPD` or `<MPD` → dash;
   `0x47` at offsets 0 and 188 (and 376 if available) → mpegts; bytes 4..8 = `ftyp`
   → mp4; `1A 45 DF A3` → mkv (doctype `webm` → webm); `FLV` → flv;
   `RIFF....AVI ` → avi
3. content-type: `application/vnd.apple.mpegurl`, `application/x-mpegurl`,
   `audio/mpegurl` → hls; `application/dash+xml` → dash; `video/mp2t` → mpegts;
   `video/mp4` → mp4; `video/x-matroska` → mkv; `video/webm` → webm; `video/x-flv` → flv
4. URL path extension: m3u8→hls, mpd→dash, ts→mpegts, mp4/m4v/mov→mp4, mkv→mkv,
   webm→webm, flv→flv, avi→avi
5. unknown

Support matrix (enforced before playback; unknown → try and map player error):

| Container | Media3 | AVPlayer |
|---|---|---|
| hls | ✅ | ✅ |
| dash | ✅ | ❌ |
| mpegts (progressive) | ✅ | ❌ |
| mp4 / mov / m4v | ✅ | ✅ |
| mkv / webm | ✅ | ❌ |
| flv | ✅ | ❌ |
| avi | ✅ | ❌ |
| rtmp | ❌ (extension not bundled) | ❌ |
| rtsp | ✅ | ❌ |
| udp/rtp multicast | ❌ | ❌ |

---

## 7. Licensing

### 7.1 Device key
```
Android: deviceKey = hex(sha256(DEVICE_KEY_PREFIX + "|" + applicationId + "|" + ANDROID_ID))
Apple:   deviceKey = hex(sha256(DEVICE_KEY_PREFIX + "|" + bundleId + "|" + identifierForVendor))
```
Raw device identifiers never leave the device.

### 7.2 License token (server → client), JWS compact, ES256
Header: `{"alg":"ES256","kid":"<kid>","typ":"JWT"}`. Signature = raw `r‖s` (64 bytes), base64url.
Payload:
```json
{
  "iss": "iptvp-license",
  "aud": "<applicationId | bundleId>",
  "sub": "<deviceKey>",
  "iat": 1759570000,
  "exp": 1760779600,
  "lic": {
    "purchased": false,
    "src": null,
    "trialStart": 1759570000,
    "trialEnd": 1760174800,
    "acct": null
  }
}
```
`src` ∈ `google | apple | account | admin | null`. Clients embed the public JWK set
(`kid → {crv:P-256,x,y}`) at build time.

Client validation: `alg == ES256`; `kid` known; signature valid; `iss` and `aud` match.
`exp` passed ⇒ token is **stale** (still usable – all trial times are absolute – but
the client tries to refresh). Vectors: `test-vectors/license-token.json`.

### 7.3 Trusted clock (never rely on the device clock alone)
```
state = { serverMs, monoMs, bootId }      // persisted, updated from every token `iat`
        (only if the new serverMs > stored serverMs)
now(deviceWallMs, monoNowMs, bootIdNow):
  if state == null:                       return deviceWallMs
  if bootIdNow != "" and bootIdNow == state.bootId and monoNowMs >= state.monoMs:
                                          return state.serverMs + (monoNowMs - state.monoMs)
  else:                                   return max(deviceWallMs, state.serverMs)
```
mono: Android `SystemClock.elapsedRealtime()`, Apple `clock_gettime_nsec_np(CLOCK_MONOTONIC)`
(includes sleep on Darwin). bootId: Android `Settings.Global.BOOT_COUNT` (API 24+,
else "" ⇒ always the fallback branch); Apple sysctl `kern.bootsessionuuid`.
Vectors: `test-vectors/trusted-clock.json`.

### 7.4 Access policy (pure function, identical everywhere)
Inputs:
* `store`: `none | pending | purchased | revoked` (local Play Billing / StoreKit 2 state
  for the lifetime product, signature-verified by the store library)
* `token`: validated claims or null
* `localTrialStartMs`: Apple only – `purchaseDate` of the verified trial transaction
  (null on Android)
* `trialDays`: last known server config (default 7)
* `nowMs`: trusted clock
* `platformStore`: `google` (Android family) | `apple` (Apple family)

```
purchasedByStore   = store == purchased
purchasedByLicense = token?.lic.purchased == true
                     and not (store == revoked and token.lic.src == platformStore)
trialEndMs = token?.lic.trialEnd*1000
             ?? (localTrialStartMs != null ? localTrialStartMs + trialDays*86_400_000 : null)

state =
  purchasedByStore or purchasedByLicense      → PURCHASED
  trialEndMs != null and nowMs <  trialEndMs  → TRIAL_ACTIVE(trialEndMs)
  trialEndMs != null and nowMs >= trialEndMs  → TRIAL_EXPIRED
  else                                        → TRIAL_NOT_STARTED
pendingPurchase = (store == pending)          // shown as banner, does not grant
canPlay = state ∈ {PURCHASED, TRIAL_ACTIVE}
```
When `canPlay == false` the **player is locked**; source management, settings,
purchase and restore stay accessible; browsing lists stays possible (user can see
what they would unlock). Vectors: `test-vectors/access-policy.json`.

### 7.5 Trial start
* Trial never starts silently: the welcome/paywall screen states duration, what gets
  locked and the one-time price, then the user taps **Start free trial**.
* Android: `POST /v1/license/sync` with `startTrial: true`. The server stores
  `trial_start = server now`, `trial_end = start + trial_days` (**snapshot** – an admin
  change of `trial_days` affects new trials only; individual extensions via admin API).
  One trial per deviceKey (ANDROID_ID survives reinstalls; resets on factory reset).
* Apple: the user "buys" the price-tier-0 non-consumable `…trial` (Apple guideline
  3.1.1). `trialStart = transaction.purchaseDate` (Apple-signed, tied to the Apple ID,
  shared by iPhone/iPad/Apple TV). The app then calls `/v1/license/sync` with the
  transaction id; the server verifies via App Store Server API and snapshots
  `trial_days`. Offline fallback: `localTrialStartMs + cached trialDays`.

### 7.6 Purchase & restore
* Android (Play Billing ≥ 7): INAPP `lifetime_access`, **never consumed**.
  PURCHASED → send token to `/v1/license/sync`; server verifies with
  `purchases.products.get`, acknowledges, links license. If the backend is unreachable
  the client acknowledges itself (avoid the 3-day auto-refund) and retries the sync
  later. PENDING → banner "payment pending", no access. Restore = `queryPurchasesAsync`
  (runs on every start + "Restore" button). Same Google account on phone + TV ⇒ same
  purchase (single applicationId).
* Apple (StoreKit 2): non-consumable; `.success(.verified)` → finish → sync; `.pending`
  (Ask to Buy / SCA) → banner; `Transaction.updates` listener for approvals & refunds;
  restore = `AppStore.sync()` + `Transaction.currentEntitlements`. Same Apple ID ⇒
  iPhone + Apple TV (Universal Purchase, same bundle id).
* Refund / revocation: Google → voided purchase (RTDN `voidedPurchaseNotification` +
  Voided Purchases API poll); Apple → ASSN v2 `REFUND`/`REVOKE`, `revocationDate`.
  Server marks license `revoked`; clients lose `purchased` on next store query/sync.
  `REFUND_REVERSED` restores it.
* Cross-store (Apple ↔ Google): only via the optional app account. A verified store
  purchase made while signed in is linked to the account; on the other platform,
  signing in to the same account makes `/v1/license/sync` return `purchased: true,
  src: "account"`.

---

## 8. Sync (favorites & progress, account only)

```
SyncItem {
  key:       "fav:" + contentKey | "prog:" + contentKey
  kind:      "favorite" | "progress"
  data:      favorite → { title, contentKind, posterUrl? }
             progress → { title, contentKind, positionMs, durationMs, posterUrl?,
                          seriesKey? }        // live channels: positionMs = 0
  updatedAt: epoch ms (client)
  deleted:   bool
}
```
Server rule: upsert when `incoming.updatedAt > stored.updatedAt` (ties keep stored).
Cursor = server sequence number; `GET /v1/sync?since=cursor` returns items with
`seq > cursor` (max 500/page, `hasMore`). Client merges with the same LWW rule.
"Continue watching": progress items with `5% < position/duration < 95%`.
"Recently watched": most recent progress items (any kind), max 50.
A progress item counts as completed at ≥ 95 %.

---

## 9. TV pairing (add a source from the phone)

1. TV generates an ephemeral P-256 key pair, `POST /v1/pair/sessions {publicKey: JWK}`
   → `{code, secret, expiresAt, pairUrl}` (code: 6 chars from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`,
   shown as `ABC-123`; TTL 10 min). TV shows a QR code of `pairUrl` (= `{BASE}/pair?c=CODE`)
   and the code itself.
2. Phone opens the page (or types the code at `{BASE}/pair`), page fetches the TV's
   public key `GET /v1/pair/sessions/{code}/key`, user fills M3U or Xtream form.
3. Browser encrypts: ephemeral P-256 key pair `e`; `Z = ECDH(e.priv, tv.pub)` (32-byte x);
   `K = HKDF-SHA256(ikm=Z, salt=empty, info=PAIR_HKDF_INFO, L=32)`;
   `ct = AES-256-GCM(K, iv=12 random bytes, plaintext=UTF-8 JSON)` with the 16-byte tag
   **appended** to ct. `POST /v1/pair/sessions/{code}/payload {epk: JWK, iv: b64url, ct: b64url}`.
4. TV polls `GET /v1/pair/sessions/{code}?secret=…` every 2 s → `202` pending,
   `200 {epk, iv, ct}` once (then deleted server-side), `410` expired.
5. Plaintext JSON:
   `{"v":1,"type":"m3u","name":"…","url":"…","epgUrl":"…"}` or
   `{"v":1,"type":"xtream","name":"…","server":"…","username":"…","password":"…"}`.

The backend only ever sees ciphertext. Vectors: `test-vectors/pair-crypto.json`.

---

## 10. Logging & redaction (`test-vectors/redaction.json`)

Every log line passes `redact()`, rules applied **in this order**:
1. every registered secret value (current source passwords/usernames/URLs, length ≥ 3),
   longest first, literal replace → `***`
2. `(?i)\b([a-z][a-z0-9+.-]*://)[^/\s@:]+:[^/\s@]*@` → `$1***@`
3. `(?i)/(live|movie|series|timeshift)/[^/\s?#]+/[^/\s?#]+/` → `/$1/***/***/`
4. `(?i)\b(username|password|pass|pwd|token|auth|key|apikey|api_key|secret|signature|sig|access_token)=([^&\s#"']*)` → `$1=***`
5. `(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+` → `$1***`

Release builds log nothing below WARN.
