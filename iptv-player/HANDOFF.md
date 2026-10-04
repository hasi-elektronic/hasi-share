# Devir Notu (bulut oturumu → Mac)

Bulut oturumu Linux konteynerde çalıştı: Xcode yoktu ve Google Maven (`dl.google.com`)
engelliydi. Bu yüzden iş, burada **test edilebilen** parçalarla sınırlı kaldı. Çalışma Mac'te
tam araç zinciriyle devam edecek. Branch: `claude/iptv-player`, PR: hasi-elektronic/hasi-share#3.

## Kurallar (değişmez)
* Normatif kaynaklar: `spec/CONTRACT.md`, `spec/BACKEND_API.md`, `docs/SCREENS.md`,
  `docs/ARCHITECTURE.md`. Davranış değişikliği önce `spec/`te ve vektörlerde yapılır.
* `spec/test-vectors/` Kotlin, Swift ve TypeScript testlerinin **ortak** girdisidir. Üç taraf
  da aynı vektörleri geçmelidir. Vektörleri elle değiştirme; hesaplananlar
  `node spec/tools/gen-vectors.mjs` ile üretilir (taze anahtarlarla — üç tarafı da yeniden çalıştır).
* Arayüz metinleri: yalnızca `spec/strings.json` (+ `spec/strings.android.json` /
  `spec/strings.apple.json` ek anahtarlar). Üretim: `node spec/tools/gen-strings.mjs`. Üretilen
  `strings.xml` / `Localizable.xcstrings` dosyalarını elle düzenleme.
* Depo kökündeki hasi-share dosyalarına dokunma. Tüm iş `iptv-player/` altında.
* Uygulama adı yer tutucudur (`NovaPlayer`), yalnızca config dosyalarında geçer. Kod paketleri
  ad-bağımsızdır (`io.iptvplayer.*`, `IPTVCore`, `IPTVKit`).

## Durum (bulut oturumu sonunda ölçüldü)

| Bileşen | Yazılan | Doğrulanan | Eksik |
|---|---|---|---|
| Spec / vektörler / dokümanlar | Tamam | Vektör JSON'ları üretildi, string XML'leri ayrıştırıldı | `docs/STATUS.md` (en sonda) |
| `backend/` | Tüm `src/` modülleri (router, config, license sync/trial/token, Google & Apple store istemcileri, webhooks, cron, auth email/session/device, account, sync, pair, admin, ratelimit, HTML sayfaları) | `npx vitest run`: **2 dosya, 26 test geçti** (license-token vektörleri, redaksiyon) | `npx tsc --noEmit`: test yardımcılarında 3 hata (`Env.DB` tipi, `test/helpers.ts`, `test/setup.ts`). Testler: license sync, deneme anlık görüntüsü, Google/Apple doğrulama (mock), iade webhook'ları, cron, auth/OTP, cihaz kodu, sync LWW, pairing (+ `pair-crypto.json` yeniden üretimi), admin. Ayrıca `scripts/keygen.mjs` (klasör boş), `README.md`, `.dev.vars.example`, `npm run build:dry` |
| `android/core` (saf Kotlin) | util, model, error, m3u, xmltv, media, retry, net/Http, `XtreamUrlBuilder` | `gradle -p core test`: **27 test, 0 hata** (m3u, xmltv, media, util vektörleri) | xtream (lenient JSON eşleme, hesap sınıflandırma, `XtreamClient`), license (`LicenseTokenVerifier`, `TrustedClock`, `AccessPolicy`, DTO'lar), pairing (`PairCrypto`), sync, `BackendClient`, EPG now/next, ilgili tüm vektör testleri, MockWebServer ağ hata testleri, 200k M3U performans testi, `android/README.md` |
| `apple/IPTVCore` (Swift Package) | Neredeyse tüm kaynaklar: models, errors, util, M3U, XMLTV (+ gzip için `CZlib` shim), Xtream (client, mapping, URL), media, licensing, pairing, sync, networking | **Test yok** (yalnızca placeholder). Derleme doğrulanmadı | Tüm vektör testleri, `BackendClient`, reconnect policy (varsa doğrula), performans testi, `apple/README.md`. CZlib shim'i Mac'te gerekmeyebilir (`Compression`/`zlib` mevcut) |
| `android/shared`, `android/app` | Yalnızca üretilmiş `strings.xml` | – | Hepsi (aşağıda D) |
| `apple/IPTVKit`, `apple/Apps/*`, `project.yml` | Yalnızca üretilmiş `Localizable.xcstrings` | – | Hepsi (aşağıda E) |

## Kalan iş (sırayla)

**A. Backend tamamla:** tsc hatalarını düzelt, eksik testleri yaz (yukarıdaki liste,
`spec/BACKEND_API.md`'nin her endpoint'i). `scripts/keygen.mjs` (`--write-clients`
`android/app/src/main/assets/license-keys.json` ve `apple/Config/license-keys.json` yazar),
Türkçe `README.md`, `.dev.vars.example` ekle. `npm test`, `npx tsc --noEmit`,
`npm run build:dry` yeşil olmalı.

**B. Android core tamamla:** eksik paketler + tüm vektör testleri.
`cd android && ./gradlew -p core test` (veya `gradle -p core test`).

**C. Apple IPTVCore tamamla:** tüm vektör testleri (XCTest; vektör yolu `#filePath` ile
`../../../../spec/test-vectors`). `cd apple/IPTVCore && swift test`.

**D. Android `shared` + `app`:** yapı `docs/ARCHITECTURE.md §2` ve ana dizin `README.md`
tablosuna göre:
* `shared`: Room (+FTS4, Paging), Keystore AES-GCM `SecureStore`, DataStore ayarları, repository'ler
  (atomik yenileme, toplu yazım), WorkManager yenileme, Play Billing 8 `BillingManager`,
  `LicenseManager` (backend sync + `AccessPolicy` + `TrustedClock` + `BOOT_COUNT`), hesap +
  `SyncManager`, `PairingManager`, Media3 `PlayerController` (reconnect, ses/altyazı, görüntü
  oranı, kanal değiştirme debounce'u, hata eşleme, `ON_STOP`'ta release), ortak ViewModel'ler,
  `AppGraph` (manuel DI), `SafeLog`.
* `app`: tek applicationId, `MobileActivity` (LAUNCHER, Compose M3, alt menü) +
  `TvActivity` (LEANBACK_LAUNCHER, `androidx.tv:tv-material`, sol menü). Manifest:
  `android.software.leanback` ve touchscreen `required=false`, banner, cleartext izinli
  network config, yedekten hariç tutma kuralları. R8 log temizliği. 9 ana ekran +
  QR eşleştirme, cihaz kodu girişi, paywall, format testi ekranı (`spec/test-vectors/stream-samples.json`).
* Sürümler `android/gradle/libs.versions.toml` içinde. Gradle sync sırasında güncel stabil
  sürümleri doğrula; Play Billing **8+** zorunlu.
* Doğrulama: `./gradlew :app:assembleDebug lint`. Telefon emülatöründe ve **Android TV
  emülatöründe** (D-pad) çalıştır.

**E. Apple `IPTVKit` + uygulamalar:**
* `IPTVKit` (Apple-only Swift Package): SQLite (`SQLite3` + FTS5), `KeychainStore`, repository'ler,
  StoreKit 2 `StoreManager` (lifetime + ücretsiz trial non-consumable, pending/Ask to Buy,
  `Transaction.updates`, `AppStore.sync`, `revocationDate`), `LicenseManager`
  (`kern.bootsessionuuid`, `CLOCK_MONOTONIC`), hesap + sync, pairing, AVPlayer
  `PlayerController` (format ön kontrolü, reconnect, `AVMediaSelectionGroup`, `videoGravity`,
  `scenePhase`'te release), `@Observable` ViewModel'ler, görsel önbelleği, `SafeLog`.
* `Apps/iOS` (TabView, NavigationStack, dikey + yatay, tam ekran oynatıcı), `Apps/tvOS`
  (odak motoru, `onExitCommand` geri kuralları, büyük tipografi), `Shared/` ortak görünümler.
* `project.yml` (XcodeGen): iOS ve tvOS hedefleri **aynı bundle id** (Universal Purchase),
  `Config/Shared.xcconfig` (`APP_DISPLAY_NAME`, `APP_BUNDLE_ID`, `PRODUCT_LIFETIME`,
  `PRODUCT_TRIAL`, `BACKEND_BASE_URL`), `Config/Products.storekit`, `PrivacyInfo.xcprivacy`,
  ATS `NSAllowsArbitraryLoads`.
* Doğrulama: `xcodegen generate` → iOS Simulator ve tvOS Simulator için `xcodebuild build`
  (+ varsa testler). Simülatörde çalıştır; StoreKit config ile satın alma, bekleyen işlem ve iade.

**F. Kapanış:**
* `docs/STATUS.md`: tamamlanan / test edilen (komut + sonuç) / doğrulanamayan (cihaz, mağaza,
  harici hesap gerektiren).
* `docs/TEST_PLAN.md`'deki otomatik test eşlemesini gerçek test adlarıyla güncelle.
* README ve PR açıklamasını güncelle.

## Mac ön koşulları
Xcode 16+ (iOS + tvOS simulator runtime), `brew install xcodegen node`, Android Studio
(SDK Platform 36, Build-Tools, Android TV system image), JDK 17+. Docker gerekmez.
