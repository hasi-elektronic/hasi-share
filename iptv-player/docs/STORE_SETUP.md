# Mağaza Yapılandırması ve Kurulum

> ⚠️ İşaretli (🔑) adımlar **harici hesap / mağaza erişimi** gerektirir ve bu depodan
> otomatik yapılamaz. Değerler yer tutucudur (`NovaPlayer`, `de.hasielektronik.novaplayer`).

## 0. Yer tutucuları değiştirme (ad ve kimlikler)

| Ne | Dosya | Anahtar |
|---|---|---|
| Android uygulama adı, applicationId, ürün id, backend URL | `android/gradle.properties` | `APP_NAME`, `APP_ID`, `PRODUCT_LIFETIME`, `BACKEND_BASE_URL` |
| Apple uygulama adı, bundle id, ürün id'leri, backend URL | `apple/Config/Shared.xcconfig` | `APP_DISPLAY_NAME`, `APP_BUNDLE_ID`, `PRODUCT_LIFETIME`, `PRODUCT_TRIAL`, `BACKEND_BASE_URL` |
| Backend | `backend/wrangler.toml` `[vars]` | `APP_NAME`, `APP_IDS`, `GOOGLE_PACKAGE_NAME`, `APPLE_BUNDLE_ID`, ürün id'leri |
| Arayüz metinleri (ad geçenler) | `node spec/tools/gen-strings.mjs` | yukarıdaki config'lerden okur |
| Lisans açık anahtarı | `backend/scripts/keygen.mjs --write-clients` | `android/app/src/main/assets/license-keys.json`, `apple/Config/license-keys.json` |

## 1. Backend (Cloudflare) 🔑
Ayrıntılı adımlar: `backend/README.md`. Özet:
1. `npm i` → `npx wrangler login` 🔑
2. `npx wrangler d1 create iptv-backend` → çıkan `database_id`'yi `wrangler.toml`'a yaz.
3. `npx wrangler d1 migrations apply iptv-backend --remote`
4. `node scripts/keygen.mjs --write-clients` → `npx wrangler secret put LICENSE_SIGNING_KEY < .keys/license-private.pem`
5. Diğer gizli değerler: `ADMIN_TOKEN`, `GOOGLE_SERVICE_ACCOUNT_JSON`, `GOOGLE_PUBSUB_TOKEN`,
   `APPLE_PRIVATE_KEY`, (opsiyonel) `RESEND_API_KEY` → `wrangler secret put …`
6. `npx wrangler deploy` → çıkan URL'yi iki uygulamanın `BACKEND_BASE_URL` değerine yaz.
7. Admin sayfası: `https://<worker>/admin` → demo süresi (varsayılan 7 gün).

### Ortam değişkenleri (backend)
| Değişken | Tür | Zorunlu | Açıklama |
|---|---|---|---|
| `PUBLIC_BASE_URL` | var | ✓ | Eşleştirme/giriş linkleri için mutlak URL |
| `APP_NAME` | var | ✓ | Web sayfaları ve e-postalarda |
| `APP_IDS` | var | ✓ | İzin verilen applicationId/bundleId listesi |
| `LICENSE_KID` | var | ✓ | Token anahtar kimliği |
| `LICENSE_SIGNING_KEY` | secret | ✓ | ES256 özel anahtar (PKCS#8 PEM) |
| `ADMIN_TOKEN` | secret | ✓ | ≥32 karakter |
| `GOOGLE_PACKAGE_NAME`, `GOOGLE_PRODUCT_ID` | var | Android satış için | |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | secret | Android satış için | Play Developer API |
| `GOOGLE_PUBSUB_TOKEN` | secret | RTDN için | Push URL'deki paylaşılan sır |
| `APPLE_BUNDLE_ID`, `APPLE_PRODUCT_ID`, `APPLE_TRIAL_PRODUCT_ID`, `APPLE_ISSUER_ID`, `APPLE_KEY_ID`, `APPLE_ENVIRONMENT` | var | Apple satış için | |
| `APPLE_PRIVATE_KEY` | secret | Apple satış için | In-App Purchase anahtarı (.p8) |
| `RESEND_API_KEY`, `MAIL_FROM` | secret / var | Hesap özelliği için | Giriş kodu e-postası |
| `DEV_MODE` | var | – | Yalnızca yerelde `true` |

## 2. Google Play (Android + Android TV) 🔑
1. **Uygulama oluştur:** paket `de.hasielektronik.novaplayer`. Play App Signing açık; upload key
   ile imzalı AAB (`./gradlew :app:bundleRelease`).
2. **Android TV form faktörü:** *Test and release → Advanced settings → Form factors → Android TV*
   ekle. Gerekenler: 320×180 TV banner (manifestte `android:banner`), TV ekran görüntüleri,
   TV kalite incelemesi (D-pad ile tam gezinme, `LEANBACK_LAUNCHER`, dokunmatik zorunlu değil).
   Tek APK/AAB hem telefon hem TV içindir → aynı satın alım iki cihazda geçerli.
3. **Tek seferlik ürün:** *Monetize with Play → Products → One-time products* →
   `lifetime_access`, satın alma seçeneği "Buy" (kiralama değil), fiyat, **Active**.
   Uygulama ürünü asla `consume` etmez (kalıcı erişim).
4. **Lisans testi:** *Settings → License testing* → test Gmail hesapları. Test kartları:
   "always approves", "always declines", **"slow test card, approves after a few minutes"**
   (bekleyen işlem testi), "slow… declines". Test kullanıcıları dahili test kanalından yükler.
5. **API erişimi:** Google Cloud projesinde servis hesabı + JSON anahtar → Play Console
   *Users and permissions* → servis hesabını davet et: *View financial data*, *Manage orders and
   subscriptions*. JSON → `GOOGLE_SERVICE_ACCOUNT_JSON`.
6. **RTDN:** Cloud Pub/Sub konusu (topic) oluştur, `google-play-developer-notifications@system.gserviceaccount.com`
   hesabına *Pub/Sub Publisher* yetkisi ver; Play Console *Monetization setup → Real-time developer
   notifications* → konu adı + "one-time products ve voided purchases dahil tüm bildirimler".
   Push aboneliği: `https://<worker>/v1/webhooks/google?token=<GOOGLE_PUBSUB_TOKEN>`.
   "Send test notification" ile doğrula.
7. **İçerik beyanları:** Data safety (§5), reklam yok, hedef kitle 18+ önerilir, uygulama erişimi
   için inceleme ekibine **yasal bir demo kaynak** (ör. kendi test M3U'nuz) inceleme notunda
   verilir — uygulamaya gömülmez.

## 3. App Store (iOS + tvOS) 🔑
1. **Anlaşmalar:** *Agreements, Tax, and Banking* → Paid Apps Agreement (IAP için şart).
2. **Bundle ID:** `de.hasielektronik.novaplayer` (In-App Purchase yeteneği). iOS ve tvOS
   hedefleri **aynı bundle id** → App Store Connect'te tek uygulama kaydına iOS + tvOS platformu
   eklenir → **Universal Purchase** (iPhone'da alınan Apple TV'de de geçerli).
3. **Uygulama içi ürünler:**
   * Non-Consumable `de.hasielektronik.novaplayer.lifetime` – fiyat, yerelleştirilmiş ad
     ("Premium – kalıcı erişim").
   * Non-Consumable `de.hasielektronik.novaplayer.trial` – **fiyat: Ücretsiz (Tier 0)**,
     ad: **"7-day Trial" / "7 Günlük Deneme"** (Guideline 3.1.1 adlandırma kuralı). Demo süresi
     admin panelinden değiştirilirse bu adı da güncelleyin.
   * Her ürün için inceleme ekran görüntüsü; ürünleri ilk sürümle birlikte incelemeye gönderin.
4. **App Store Server API anahtarı:** *Users and Access → Integrations → In-App Purchase* → .p8
   indir → `APPLE_PRIVATE_KEY`, Key ID → `APPLE_KEY_ID`, Issuer ID → `APPLE_ISSUER_ID`.
5. **App Store Server Notifications V2:** Production ve Sandbox URL'si
   `https://<worker>/v1/webhooks/apple`.
6. **Sandbox test hesapları:** *Users and Access → Sandbox*. Xcode içinde yerel test için
   `apple/Config/Products.storekit` (şemada seçili): Ask to Buy (bekleyen işlem), iade
   (*Debug → StoreKit → Manage Transactions → Refund*), satın alma hataları simüle edilebilir.
7. **ATS:** `NSAllowsArbitraryLoads = YES` (kullanıcının eklediği HTTP IPTV sunucuları). İnceleme
   notunda gerekçelendirin.
8. **Gizlilik:** `PrivacyInfo.xcprivacy` (UserDefaults CA92.1, sistem açılış zamanı 35F9.1),
   App Privacy formu (§5).
9. **tvOS varlıkları:** katmanlı uygulama ikonu (LSR), Top Shelf görseli.
9a. **Build 17 – Top Shelf uzantısı, arka plan sesi, PiP (portal):**
   * Yeni explicit App ID `com.hasielektronic.novaplayer.topshelf` (tvOS uzantısı; ek yetenek **yok**).
   * Profiller: `NovaPlayer TopShelf AppStore` (App Store, tvOS, bu App ID) + geliştirme profili; uygulamanın
     `NovaPlayer iOS AppStore` / `NovaPlayer tvOS AppStore` profilleri yeniden üretilmeli (yeni entitlement
     `keychain-access-groups`: `TEAM.com.hasielektronic.novaplayer` + `TEAM.com.hasielektronic.novaplayer.shared`;
     varsayılan profillerde `TEAM.*` olarak izinli – yine de yeniden indirip doğrulayın).
   * `UIBackgroundModes = audio` (iOS) ve PiP için portal yeteneği gerekmez; App Review notunda arka plan sesinin
     amacı (canlı radyo/haber, PiP) belirtilir.
   * `scripts/release/release.sh` profil adlarını hedef başına verir (`NOVA_APP_PROFILE`, `NOVA_TOPSHELF_PROFILE`),
     `export-tvOS.plist` uzantıyı da eşler.
10. **İnceleme notu:** "Uygulama içerik sağlamaz; kullanıcı kendi M3U/Xtream kaynağını ekler.
    Test için: <yasal demo M3U URL'si>." Ayrıca deneme ve satın alma akışının nasıl
    test edileceği.

## 4. Derleme
### Android
```
cd android
./gradlew :core:test            # (composite build) veya: gradle -p core test
./gradlew :app:assembleDebug    # Android Studio Ladybug+ / JDK 17+, Google Maven erişimi gerekir
./gradlew :app:bundleRelease    # imzalama: keystore.properties (git dışı)
```
### Apple
```
brew install xcodegen
cd apple && xcodegen generate     # NovaPlayer.xcodeproj (önce scripts/fetch-vlckit.sh: VLCKit ~260+120 MB indirir, ilk seferde)
open NovaPlayer.xcodeproj         # Xcode 16+, şema: NovaPlayer-iOS / NovaPlayer-tvOS
# Çekirdek testleri (macOS'ta): cd IPTVCore && swift test
```

## 5. Gizlilik beyan tablosu (Data safety / App Privacy)
| Veri | Toplanır mı | Amaç | Kimliğe bağlı mı |
|---|---|---|---|
| E-posta | Yalnızca hesap açılırsa | Hesap, giriş | Evet |
| Cihaz kimliği (hash) | Evet | Deneme süresi / lisans (dolandırıcılık önleme) | Hayır (hesapsız) |
| Satın alma geçmişi | Evet | Lisans doğrulama | Hesap varsa evet |
| Uygulama etkinliği (favoriler, izleme ilerlemesi, içerik başlıkları) | Yalnızca hesap + senkron | Cihazlar arası senkron | Evet |
| IPTV kimlik bilgileri, listeler | **Hayır** (cihazda kalır) | – | – |
| Konum, kişiler, reklam kimliği, analitik | Hayır | – | – |
Şifreleme: aktarımda HTTPS (backend). Kullanıcı verilerini silme talebi: uygulama içi "Hesabı sil".
