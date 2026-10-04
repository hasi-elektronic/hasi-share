# Backend (Cloudflare Workers + D1)

Uygulamanın küçük sunucu tarafı: deneme süresi ve lisans (imzalı token), Google Play /
App Store satın alma doğrulaması ve iade bildirimleri, isteğe bağlı hesap (e-posta kodu,
TV için cihaz-kodu girişi), favori/ilerleme senkronu, TV eşleştirme rölesi (uçtan uca
şifreli) ve basit bir yönetim sayfası.

Normatif kaynaklar: `../spec/BACKEND_API.md` (endpoint'ler), `../spec/CONTRACT.md`
(token, deneme, senkron, eşleştirme kuralları), `../docs/ARCHITECTURE.md §5`.
Backend **hiçbir zaman** IPTV kullanıcı adı/şifresi, liste veya yayın URL'si almaz
(eşleştirmede yalnızca çözemediği şifreli metni ≤ 10 dk tutar).

## İçindekiler
1. [Gereksinimler](#1-gereksinimler)
2. [Yerel geliştirme](#2-yerel-geliştirme)
3. [D1 veritabanı](#3-d1-veritabanı)
4. [Lisans anahtarı (keygen)](#4-lisans-anahtarı-keygen)
5. [Gizli değerler](#5-gizli-değerler)
6. [Google Play: API erişimi + RTDN (Pub/Sub)](#6-google-play-api-erişimi--rtdn-pubsub)
7. [App Store: Server API + Server Notifications V2](#7-app-store-server-api--server-notifications-v2)
8. [Deploy](#8-deploy)
9. [Testler](#9-testler)
10. [İşletim notları](#10-işletim-notları)

---

## 1. Gereksinimler
* Node.js 22+ (testler ve `scripts/keygen.mjs` için), npm
* Cloudflare hesabı (Workers + D1; ücretsiz katman yeterli) 🔑
* Android satışı için Google Play Console + Google Cloud projesi 🔑
* Apple satışı için App Store Connect (Paid Apps Agreement) 🔑
* Hesap özelliği (e-posta ile giriş) için isteğe bağlı [Resend](https://resend.com) hesabı 🔑

🔑 = harici hesap gerekir, bu depodan otomatik yapılamaz.

```bash
cd backend
npm ci
```

## 2. Yerel geliştirme
```bash
cp .dev.vars.example .dev.vars        # yer tutucuları doldurun (dosya git'e girmez)
node scripts/keygen.mjs               # .keys/license-private.pem üretir (aşağıya bakın)
# .keys/license-private.pem içeriğini .dev.vars → LICENSE_SIGNING_KEY değerine yapıştırın
npm run db:migrate:local              # yerel D1 şeması (.wrangler/ altında)
npm run dev                           # http://localhost:8787
```
* `.dev.vars` içinde `DEV_MODE="true"`: `/v1/auth/email/start` yanıtında `devCode` döner
  (e-posta gerekmez) ve tüm istek sınırları ×100 gevşetilir. **Üretimde asla `true`
  yapmayın** (`wrangler.toml` varsayılanı `"false"`).
* Hızlı kontrol: `curl http://localhost:8787/v1/config`
* Sayfalar: `/pair` (telefondan TV'ye kaynak gönderme), `/link` (TV girişini onaylama),
  `/admin` (yönetim). Dil `Accept-Language`'a göre TR/EN, `?lang=tr|en` ile zorlanabilir.

## 3. D1 veritabanı
```bash
npx wrangler login                               # 🔑
npx wrangler d1 create iptv-backend              # çıktıdaki database_id'yi kopyalayın
#   wrangler.toml → [[d1_databases]] database_id = "<buraya>"
npm run db:migrate:remote                        # = wrangler d1 migrations apply DB --remote
```
* Şema: `migrations/0001_init.sql`. Yeni değişiklik = yeni dosya
  (`migrations/0002_….sql`); eski migration'ları değiştirmeyin.
* Zaman sütunları: `*_at` epoch **milisaniye**, `trial_*` epoch **saniye** (token
  claim'leriyle birebir).
* Kişisel veri: yalnızca hesap e-postası (hesap açılırsa). Cihazlar `deviceKey`
  (SHA-256 türevi) ile tutulur; e-posta kodları, oturum token'ları, eşleştirme sırları ve
  rate-limit anahtarları yalnızca hash olarak saklanır.

## 4. Lisans anahtarı (keygen)
Lisans token'ı ES256 ile imzalanır (CONTRACT §7.2); uygulamalar açık anahtarı derleme
anında gömer.

```bash
node scripts/keygen.mjs --kid lk-1 --write-clients
```
Ne yapar:
* `.keys/license-private.pem` – PKCS#8 PEM özel anahtar (izin 600, git dışı). Ekrana
  **yazdırılmaz**.
* `.keys/license-public.json` – `{"lk-1": {"kty":"EC","crv":"P-256","x":"…","y":"…"}}`
* `--write-clients` ile aynı JWK set'i şu dosyalara yazar (yoksa klasörü oluşturur):
  `../android/app/src/main/assets/license-keys.json` ve `../apple/Config/license-keys.json`.

Seçenekler:

| Seçenek | Açıklama |
|---|---|
| `--kid <id>` | Anahtar kimliği. Varsayılan: `wrangler.toml` içindeki `LICENSE_KID` (yoksa `lk-1`). `wrangler.toml` → `LICENSE_KID` ile **aynı** olmalı. |
| `--write-clients` | Android + Apple anahtar dosyalarını yaz. |
| `--replace` | İstemci dosyalarında yalnızca yeni anahtar kalsın (varsayılan: birleştir). |
| `--force` | Var olan özel anahtarın / aynı kid'in üzerine yaz. |
| `--keys-dir <dir>` | Özel/açık anahtar klasörü (varsayılan `backend/.keys`). |
| `--out-root <dir>` | İstemci dosyalarının kökü (varsayılan `iptv-player/`; testlerde geçici klasör). |

Ardından:
```bash
npx wrangler secret put LICENSE_SIGNING_KEY < .keys/license-private.pem
```
**Anahtar değişimi (rotation):** yeni bir kid ile (`--kid lk-2 --write-clients`) üretin →
istemci dosyalarında eski ve yeni kid birlikte kalır → uygulamaları yayınlayın →
`LICENSE_KID = "lk-2"` + yeni secret + deploy. Eski kid'i, ona ihtiyaç duyan uygulama
sürümü kalmayınca `--replace` ile kaldırın. Token'lar 14 gün sonra "bayat" sayılır ama deneme
zamanları mutlak olduğu için geçerliliğini korur; uygulamalar her açılışta yeniler.

## 5. Gizli değerler
Hepsi `npx wrangler secret put <AD>` ile girilir (yerelde `.dev.vars`; örnek:
`.dev.vars.example`). Diğer ayarlar `wrangler.toml` → `[vars]` içindedir.

| Secret | Zorunlu | Açıklama |
|---|---|---|
| `LICENSE_SIGNING_KEY` | ✓ | ES256 özel anahtar, PKCS#8 PEM (`scripts/keygen.mjs`) |
| `ADMIN_TOKEN` | ✓ | ≥ 32 karakter (`openssl rand -base64 48`). Kısa/eksikse admin API kapalıdır. |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | Android satışı | Play Developer API servis hesabı JSON'u (tek satır) |
| `GOOGLE_PUBSUB_TOKEN` | RTDN | Push URL'sindeki paylaşılan sır (`openssl rand -hex 24`) |
| `APPLE_PRIVATE_KEY` | Apple satışı | In-App Purchase anahtarı (.p8 içeriği) |
| `RESEND_API_KEY` | Hesap özelliği | Giriş kodu e-postaları. Yoksa (ve `DEV_MODE` kapalıysa) `email/start` → 503 |

```bash
npx wrangler secret put ADMIN_TOKEN
npx wrangler secret put GOOGLE_SERVICE_ACCOUNT_JSON < service-account.json
npx wrangler secret put GOOGLE_PUBSUB_TOKEN
npx wrangler secret put APPLE_PRIVATE_KEY < SubscriptionKey_XXXXXXXXXX.p8
npx wrangler secret put RESEND_API_KEY
```
`[vars]` içinde düzenlenecekler: `PUBLIC_BASE_URL` (Worker'ın mutlak adresi – QR kodları ve
`/link` bağlantıları bununla üretilir), `APP_NAME`, `APP_IDS`, `LICENSE_KID`,
`GOOGLE_PACKAGE_NAME`, `GOOGLE_PRODUCT_ID`, `APPLE_ISSUER_ID`, `APPLE_KEY_ID`,
`APPLE_BUNDLE_ID`, `APPLE_PRODUCT_ID`, `APPLE_TRIAL_PRODUCT_ID`, `APPLE_ENVIRONMENT`,
`MAIL_FROM` (Resend'de doğrulanmış alan adı), `DEFAULT_TRIAL_DAYS`, `MIN_VERSION_*`,
`CORS_ORIGINS`, `DEV_MODE`. Kimlikler `spec/CONTRACT.md §0` ile aynı olmalıdır.

## 6. Google Play: API erişimi + RTDN (Pub/Sub)
1. 🔑 Google Cloud Console → proje → **Google Play Android Developer API**'yi etkinleştirin.
2. 🔑 Servis hesabı oluşturun → JSON anahtar indirin → `GOOGLE_SERVICE_ACCOUNT_JSON`.
3. 🔑 Play Console → *Users and permissions* → servis hesabının e-postasını davet edin,
   uygulama için **View financial data** ve **Manage orders and subscriptions** izinleri.
   (Voided Purchases API "financial data" izni ister.) İzinlerin etkinleşmesi saatler sürebilir.
4. 🔑 Pub/Sub: konu (topic) oluşturun, ör. `projects/<proje>/topics/play-rtdn`.
   Konuya `google-play-developer-notifications@system.gserviceaccount.com` için
   **Pub/Sub Publisher** rolü verin.
5. 🔑 Aynı konuya **Push** aboneliği:
   `https://<worker>/v1/webhooks/google?token=<GOOGLE_PUBSUB_TOKEN>`
   (Token yanlışsa 401; diğer her durumda 204 → Pub/Sub tekrar denemez.)
6. 🔑 Play Console → *Monetize with Play → Monetization setup → Real-time developer
   notifications*: konu adı + **tüm bildirim türleri** (tek seferlik ürünler ve
   iptal edilen/iade edilen satın alımlar dahil). **Send test notification** → Worker
   loglarında `rtdn.test` görünmeli.

Davranış: `oneTimeProductNotification` (1 PURCHASED → kaydet + sunucudan acknowledge,
2 CANCELED → yeniden sorgu) ve `voidedPurchaseNotification` (→ iptal). Durum **yalnızca
Google'a yeniden sorgulandıktan sonra** değişir; sahte bildirim zarar vermez. Ayrıca günlük
cron (`17 3 * * *` UTC) son 30 günün Voided Purchases listesini tarar.

## 7. App Store: Server API + Server Notifications V2
1. 🔑 App Store Connect → *Users and Access → Integrations → In-App Purchase* → anahtar
   oluşturun → `.p8` → `APPLE_PRIVATE_KEY`; *Key ID* → `APPLE_KEY_ID`; *Issuer ID* →
   `APPLE_ISSUER_ID` (`wrangler.toml`).
2. `APPLE_BUNDLE_ID`, `APPLE_PRODUCT_ID` (non-consumable, kalıcı erişim) ve
   `APPLE_TRIAL_PRODUCT_ID` (ücretsiz, "7-day Trial" adında non-consumable) App Store
   Connect'teki ürünlerle aynı olmalı.
3. 🔑 App Store Connect → uygulama → *App Information → App Store Server Notifications*:
   **Version 2**, Production URL ve Sandbox URL: `https://<worker>/v1/webhooks/apple`.
   "Request a Test Notification" (App Store Server API) → loglarda `assn.received` / `TEST`.
4. `APPLE_ENVIRONMENT`: `Production` (önerilen). Sunucu işlemi bulamazsa (404) diğer ortamı
   dener; bildirimlerde `data.environment` önce denenir.

Davranış: bildirimdeki imzalı veri yalnızca **çözülür**; ilgili işlem App Store Server API'den
(`GET /inApps/v1/transactions/{id}`) **yeniden çekilir** ve onun durumu uygulanır (x5c zinciri
doğrulanmaz; güven Apple'a TLS ile yapılan sorgudan gelir). `REFUND`/`REVOKE` → iptal,
`REFUND_REVERSED` → geri açma (yönetici iptalleri kalıcıdır), `CONSUMPTION_REQUEST` ve
diğerleri → 200. Apple'a ulaşılamazsa 503 (Apple tekrar dener).

## 8. Deploy
```bash
npx tsc --noEmit && npm test       # önce yeşil olmalı
npm run build:dry                  # dist/ altına paketler, yüklemez (dist git dışı)
npm run db:migrate:remote          # yeni migration varsa
npm run deploy                     # = wrangler deploy
```
* Çıkan `https://iptv-backend.<hesap>.workers.dev` (veya özel alan adı) adresini
  `wrangler.toml` → `PUBLIC_BASE_URL` ve iki uygulamanın `BACKEND_BASE_URL` değerine yazın.
* Admin: `https://<worker>/admin` → token'ı sayfaya girin (yalnızca bu sekmenin
  `sessionStorage`'ında tutulur) → demo süresi (1–90 gün, yalnızca **yeni** denemeleri etkiler),
  özellik anahtarları, deneme uzatma/kısaltma, lisans arama/iptal/geri açma/hediye.
* Loglar: Cloudflare dashboard → Workers → Logs (`[observability] enabled = true`). Tüm log
  satırları `redact()`'tan geçer (CONTRACT §10); e-postalar maskelenir (`a***@e***.com`),
  sorgu dizeleri (ör. Pub/Sub token'ı) loglanmaz.

## 9. Testler
```bash
npm test            # vitest (workerd içinde, yerel D1) + node --test scripts/keygen.test.mjs
npx tsc --noEmit    # tip kontrolü
npm run build:dry   # paketleme kontrolü
```
Testler `@cloudflare/vitest-pool-workers` ile gerçek Workers çalışma ortamında koşar;
Google, Apple ve Resend `test/helpers.ts` içindeki sahte `fetch` ile taklit edilir
(OAuth JWT ve App Store API JWT imzaları da doğrulanır). Saat enjekte edilebilir
(`Harness.advance`).

| Dosya | Kapsam |
|---|---|
| `test/license-token.test.ts` | `spec/test-vectors/license-token.json`, imzalama, deviceKey biçimi |
| `test/license-sync.test.ts` | `/v1/license/sync`: doğrulama, Android deneme + anlık görüntü, Google/Apple doğrulama, 422/503, hesap üzerinden platformlar arası, rate limit |
| `test/webhooks.test.ts` | Google RTDN (Pub/Sub) ve Apple ASSN V2: iade, iptal, iade geri alma, sahte bildirim |
| `test/cron.test.ts` | Voided Purchases taraması (sayfalama dahil), temizlik |
| `test/auth.test.ts` | E-posta kodu (DEV_MODE, Resend, deneme sınırı, süre, tek kullanım), oturum (180 gün kayan) |
| `test/device-account.test.ts` | Cihaz-kodu akışı, `/v1/account` GET/DELETE |
| `test/sync.test.ts` | LWW, eşitlikte saklanan kazanır, silme işaretleri, sayfalama, limitler |
| `test/pair.test.ts` | `pair-crypto.json` vektörleri, eşleştirme API'si (tek teslim, 409/410/404, boyut) |
| `test/admin.test.ts` | Admin kimlik doğrulama, config, deneme uzatma, lisans arama/iptal/hediye, `/admin` sayfası |
| `test/http-pages.test.ts` | `/v1/config`, yönlendirme/hata biçimi, CORS, dil seçimi, `/pair` ve `/link` sayfaları |
| `test/redaction.test.ts` | `spec/test-vectors/redaction.json`, logger maskeleme |
| `scripts/keygen.test.mjs` | Anahtar üretimi, istemci dosya biçimi, rotation, üzerine yazma koruması (geçici klasörde) |

Ortak vektörler elle değiştirilmez; `node ../spec/tools/gen-vectors.mjs` taze anahtarlarla
**tümünü** yeniden üretir (Kotlin ve Swift testlerini de yeniden çalıştırın).

## 10. İşletim notları
* **İstek sınırları** (D1 tabanlı sabit pencere): lisans senkronu 30/dk/cihaz, e-posta kodu
  5/saat/e-posta ve 20/saat/IP, eşleştirme oturumu 10/dk/IP, cihaz-kodu başlatma 10/dk/IP.
* **Temizlik (cron):** süresi dolmuş kodlar/oturumlar/eşleştirmeler, eski rate-limit
  satırları, 180 günden eski senkron silme işaretleri.
* **Hesap silme** (`DELETE /v1/account`): hesap, oturumlar, senkron verisi ve hesap denemesi
  silinir; lisanslar mağaza iadeleri için kişisel veri olmadan kalır (hesaptan ayrılır).
* **Yerelde doğrulanamayanlar:** gerçek Google Play / App Store yanıtları, Pub/Sub ve ASSN
  teslimatı, Resend e-posta teslimi – bunlar yalnızca mağaza hesaplarıyla (lisans test
  kullanıcıları, Sandbox) uçtan uca denenebilir.
