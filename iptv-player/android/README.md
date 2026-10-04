# Android ailesi (telefon + Android TV)

Tek Gradle projesi, tek `applicationId` (telefon ve TV aynı satın alımı görür). Normatif
kurallar: [`../spec/CONTRACT.md`](../spec/CONTRACT.md), [`../spec/BACKEND_API.md`](../spec/BACKEND_API.md),
mimari: [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

## Modüller

| Modül | Tür | Durum | İçerik |
|---|---|---|---|
| `core` | Saf Kotlin/JVM (included build, Android bağımlılığı yok) | **Tamam, test ediliyor** | M3U, XMLTV, Xtream, format tespiti, lisans, eşleştirme şifrelemesi, senkron modeli, backend istemcisi |
| `shared` | Android library | **Tamam, test ediliyor** (17 JVM/Robolectric testi) | Room + FTS4 + Paging 3, Keystore `SecureStore`, DataStore, repository'ler, WorkManager, Play Billing 8, `LicenseManager`, `AccountManager`, `SyncManager`, `PairingManager`, Media3 `PlayerController`, ViewModel'ler, `AppGraph`, `SafeLog` |
| `app` | Android application | **Tamam**, telefon + Android TV emülatöründe çalıştırıldı | `MobileActivity` (Compose M3, alt menü) + `TvActivity` (tv-material, sol menü), manifest, R8 |

## `shared` paket yapısı (`io.iptvplayer.shared.*`)

| Paket | İçerik |
|---|---|
| `config` | `AppConfig` – BuildConfig'ten gelen değerler (appId, ad, backend URL, ürün id, gömülü JWK seti) |
| `log` | `SafeLog`: tüm loglar `Redactor.default`'tan geçer; release'te yalnızca WARN+ (R8 `v/d/i` çağrılarını da siler) |
| `secure` | `KeystoreSecretStore`: Android Keystore AES-256-GCM anahtarı (dışa aktarılamaz), şifreli metin `secure_store` SharedPreferences'ta; kaynak gizli bilgileri + oturum token'ı |
| `settings` | DataStore Preferences: ayarlar, lisans token'ı + `TrustedClock` durumu, senkron imleci |
| `db` | Room: `sources`, `categories`, `channels`/`movies`/`series` (+ FTS4 tabloları), `episodes`, `epg`, `library` (favori/ilerleme = `SyncItem`) |
| `repo` | `SourceRepository` (ekle/yenile/sil, EPG içe aktarma, eşleştirme), `CatalogRepository` (sayfalı listeler, FTS arama, oynatma URL'si), `LibraryRepository` (favori, ilerleme, LWW) |
| `work` | `RefreshWorker`: 6 saatlik periyodik yenileme (`autoRefreshHours`), kaynak eklenince EPG içe aktarma |
| `billing` | `BillingManager` (Play Billing 8.3: INAPP `lifetime_access`, bekleyen ödeme, geri yükleme, acknowledge yedeği) |
| `license` | `LicenseManager`: `/v1/license/sync`, token doğrulama (ES256 + `sub == deviceKey`), `TrustedClock` (`elapsedRealtime` + `BOOT_COUNT`), `AccessPolicy`, son geçerli token yedeği |
| `account`, `sync`, `pairing` | E-posta kodu / TV cihaz kodu girişi; 5 sn debounce'lu, 500'lük parçalı senkron; QR eşleştirme (uçtan uca şifreli) |
| `player` | `PlayerController` (Media3), `PlaybackErrorMapper`, `ChannelSwitcher` (400 ms), `FormatProber` (format testi) |
| `vm`, `di` | Ortak ViewModel'ler + `ViewModelFactory`; manuel DI `AppGraph` |

**Atomik yenileme:** içerik tablolarında `gen` sütunu vardır. Yenileme yeni nesli 1000'lik (testte
2'lik) işlemlerle yazar, sonunda tek işlemde `sources.activeGen`'i değiştirip eski nesli siler.
Okuma sorguları yalnızca aktif nesli görür → yarım liste görünmez; hata olursa eski katalog kalır.
EPG aynı şekilde `epgGen` ile değiştirilir; kanal ↔ XMLTV eşleşmesi `channels.epgKey`'e yazılır.

**Not (M3U):** içerik kimliği CONTRACT §1.1 gereği `sha256(url)`'dir; aynı URL'yi taşıyan iki
girdi tek kanal olur (özet sayıları veritabanındaki gerçek satırlardır).

## `app` yapısı (`io.iptvplayer.app`)

* `IptvApplication` → `AppGraph` (+ Coil 3 görsel önbelleği: bellek %20, disk 200 MB).
* `MobileActivity` (LAUNCHER): `ui/mobile/*` – karşılama + deneme kartı, M3U/Xtream formları,
  Ana Sayfa, Canlı TV (+ EPG ızgarası), Filmler, Diziler (+ detay/bölümler), Favoriler, Arama,
  Paywall, Ayarlar/kaynak yönetimi, Hesap, Format testi.
* `TvActivity` (LEANBACK_LAUNCHER): `ui/tv/*` – sol menü (odaklanınca genişler), Ana Sayfa
  rafları, Canlı TV 3 sütun (kategoriler | kanallar ★ | önizleme), EPG ızgarası (catch-up),
  film/dizi ızgaraları, detay, favoriler, arama, ayarlar, QR eşleştirme (geri sayımlı), paywall,
  hesap (cihaz kodu + QR). Geri tuşu kuralları SCREENS §2'deki gibi; oynatıcıdan dönünce odak
  açılan kanala döner.
* `ui/common/PlayerScreen.kt`: iki platformun ortak oynatıcı ekranı (katman, ses/altyazı/görüntü
  oranı panelleri, kanal değiştirme bilgi kartı, rakam girişi, yeniden bağlanma, hata kartı,
  `ON_STOP`'ta release).
* Manifest: `leanback` ve `touchscreen` `required=false`, TV banner, cleartext izinli
  `network_security_config`, `data_extraction_rules` + `backup_rules` (DB, SharedPreferences,
  DataStore yedek/aktarım dışı), `localeConfig` (TR/EN).
* `stream-samples.json` derleme sırasında `spec/test-vectors/`'ten asset olarak kopyalanır
  (`copyStreamSamples` görevi).
* Lisans açık anahtarları: `app/src/main/assets/license-keys.json`. **Depodaki dosya yalnızca
  test anahtarını (`test-1`, özel anahtarı `spec/test-vectors/license-token.json` içinde açık!)
  içerir.** Üretim derlemesinden önce mutlaka:
  `cd backend && node scripts/keygen.mjs --kid <kid> --write-clients --replace` (ardından
  `LICENSE_SIGNING_KEY` secret'ını ayarla) – aksi halde herkes geçerli token üretebilir.

## Yapılandırma (`gradle.properties`)

| Özellik | Varsayılan | Açıklama |
|---|---|---|
| `APP_NAME`, `APP_ID` | `NovaPlayer`, `de.hasielektronik.novaplayer` | Yer tutucular (CONTRACT §0) |
| `PRODUCT_LIFETIME` | `lifetime_access` | Play ürün kimliği → `BuildConfig.PRODUCT_LIFETIME` |
| `BACKEND_BASE_URL` | `https://iptv-backend.example.workers.dev` | `example.` içeren URL = backend yok → Android'de deneme başlatılamaz (V9), anlaşılır mesaj |
| `DEBUG_BACKEND_BASE_URL` | boş | Yalnızca debug derlemesi: örn. `-PDEBUG_BACKEND_BASE_URL=http://10.0.2.2:8798` |
| `VERSION_NAME`, `VERSION_CODE` | `1.0.0`, `1` | |
| `keystore.properties` (git dışı) | – | `storeFile`, `storePassword`, `keyAlias`, `keyPassword` → release imzası |

## Derleme ve doğrulama

Gereken: JDK 17, Android SDK (platform 36), `local.properties` içinde `sdk.dir`.

```sh
cd iptv-player/android
./gradlew :app:assembleDebug lint test   # APK + lint (hata = build kırılır) + tüm birim testleri
./gradlew -p core test                   # core (88 test)
./gradlew :app:bundleRelease             # Play için AAB (R8 + kaynak küçültme)
```

`shared` testleri: `LicenseManagerTest` (V9, deneme başlatma, son bilinen token, saat geri alma,
mağaza satın alımı + acknowledge yedeği, yabancı/yanlış imzalı token, bekleyen ödeme),
`SyncManagerTest` (sayfalı çekme, 500'lük parçalı gönderim, 5 sn debounce), `PlayerLogicTest`
(Media3 hata eşleme, 400 ms kanal debounce'u, format testi kararı, form doğrulama),
`RepositoryTest` (Robolectric + in-memory Room: ekleme, atomik yenileme, FTS, EPG eşleme, LWW).

## Emülatörde çalıştırma (telefon + Android TV)

```sh
# 1) Yerel backend (deneme/eşleştirme için; DEV_MODE, test imza anahtarı scratch'te):
cd iptv-player/backend
node -e 'const c=require("crypto"),v=require("../spec/test-vectors/license-token.json");
  process.stdout.write(c.createPrivateKey({key:v.privateKeyForBackendTests.jwk,format:"jwk"}).export({type:"pkcs8",format:"pem"}))' > /tmp/test-1.pem
#    dev.env: LICENSE_SIGNING_KEY="<PEM, satır sonları \n>", LICENSE_KID="test-1", DEV_MODE="true",
#             PUBLIC_BASE_URL="http://10.0.2.2:8798", ADMIN_TOKEN="…"
npx wrangler d1 migrations apply DB --local --persist-to /tmp/wstate
npx wrangler dev --local --port 8798 --persist-to /tmp/wstate --env-file /tmp/dev.env

# 2) Test listesi: kendi M3U'nuzu (ör. Apple bipbop HLS URL'leri) bir klasöre koyup
python3 -m http.server 8766          # emülatörden http://10.0.2.2:8766/test.m3u

# 3) APK
cd ../android && ./gradlew :app:assembleDebug -PDEBUG_BACKEND_BASE_URL=http://10.0.2.2:8798
~/Library/Android/sdk/emulator/emulator -avd iptv_phone -no-snapshot -no-audio &   # veya iptv_tv
adb wait-for-device && adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n de.hasielektronik.novaplayer/io.iptvplayer.app.MobileActivity   # TV: .TvActivity
adb shell input keyevent 21|20|23|4    # TV D-pad: sol | aşağı | OK | geri
```

TV eşleştirmesi tarayıcı yerine komut satırından da test edilebilir: TV'deki kodu alıp
`GET /v1/pair/sessions/{code}/key` → WebCrypto ile şifrele → `POST …/payload` (CONTRACT §9).

**Emülatörde doğrulanamayanlar:** Play Billing satın alma (Play Console + lisans test hesabı +
dahili test kanalı gerekir; `google_apis` imajında Play Store yok → "Mağaza kullanılamıyor"),
gerçek IPTV sağlayıcıları/Xtream panelleri, HDMI/AC-3 passthrough, gerçek TV kumandası CH±.

## `core` paket yapısı (`io.iptvplayer.core.*`)

| Paket | Sorumluluk | Sözleşme |
|---|---|---|
| `model` | Domain modeli (`Source`, `Channel`, `Movie`, `Series`, `Episode`, `EpgProgram`, `SourceSecrets`) | §1 |
| `error` | `SourceError` / `PlaybackError`, ağ hatası sınıflandırma, hata ekranı eşlemesi | §2 |
| `net` | OkHttp tabanlı ortak GET hattı (`SourceHttp`): zaman aşımları, yeniden deneme, iptal, redakte log | §2 |
| `retry` | Kaynak yeniden deneme (2 s, 4 s) ve oynatıcı yeniden bağlanma politikası | §2 |
| `m3u` | Akış halinde M3U ayrıştırıcı (≤ 1000'lik partiler), `M3uClient`, `M3uMapper` | §3 |
| `xtream` | Esnek JSON eşleme (`XtreamJson`, `XtreamMapper`), hesap sınıflandırma (`XtreamAccountClassifier`), `XtreamClient` (büyük listeler akış halinde), `XtreamUrlBuilder` | §4 |
| `xmltv` | Akış halinde XMLTV ayrıştırıcı (gzip otomatik), kanal eşleştirme, saklama penceresi, `EpgSchedule` (şimdi/sıradaki) | §5 |
| `media` | Konteyner tespiti + destek matrisi | §6 |
| `crypto` | P-256 JWK ↔ JCA anahtar, ES256 (ham `r‖s` ↔ DER) – yalnızca `java.security` / `javax.crypto` | §7.2, §9 |
| `license` | `LicenseTokenVerifier` (ES256 JWS), `TrustedClock`, `AccessPolicy` | §7 |
| `pairing` | `PairCrypto` (ECDH P-256 + HKDF-SHA256 + AES-256-GCM), `PairPayload`, `PairCode` | §9 |
| `sync` | `SyncItem`, LWW birleştirme (`SyncMerge`), "izlemeye devam et" / "son izlenenler" | §8 |
| `backend` | `BackendClient` (config, lisans senkronu, hesap, cihaz kodu, senkron, eşleştirme) + DTO'lar, `BackendError` | BACKEND_API |
| `util` | URL normalizasyonu, yüzde kodlama, içerik anahtarları, cihaz anahtarı, redaksiyon, base64/hex, gzip | §1.1, §7.1, §10 |

Kurallar: `explicitApi()` açık; Android'e özgü sınıf kullanılmaz (XmlPullParser yalnızca
`compileOnly`, testlerde kxml2). Kripto yalnızca JCA ile yapılır, Android API 23'te de çalışır
(`AlgorithmParameters("EC")` veya `SHA256withECDSAinP1363Format` kullanılmaz).

## Derleme ve test

Gereken: JDK 17+. Sistem Gradle'ı gerekmez (wrapper: Gradle 8.14.3).

```sh
cd iptv-player/android
./gradlew -p core test            # tüm core testleri
./gradlew -p core test --tests '*XtreamVectorsTest'   # tek sınıf
```

Raporlar: `core/build/reports/tests/test/index.html`.

* Testler ortak vektörleri `../../spec/test-vectors` klasöründen okur (`vectors.dir` sistem
  özelliği, `core/build.gradle.kts`). Vektörler elle değiştirilmez; davranış değişikliği önce
  `spec/` içinde yapılır.
* Ağ testleri OkHttp `MockWebServer` ile gerçek soket üzerinden çalışır (zaman aşımı, 4xx/5xx,
  JSON yerine HTML, yönlendirme, gzip, bağlantı reddi, DNS, çevrimdışı, iptal). İnternet gerekmez.
* `M3uPerformanceTest` (`@Tag("performance")`) 200 000 girdilik (~45 MB) bir listeyi bellekte
  üretip akış halinde ayrıştırır; varsayılan olarak çalışır (birkaç yüz ms), test JVM'i 512 MB
  heap ile sınırlıdır. Hariç tutmak için Gradle'da `useJUnitPlatform { excludeTags("performance") }`.

| Test sınıfı | Kapsam |
|---|---|
| `M3uVectorsTest` | `m3u/*` |
| `XmltvVectorsTest` | `xmltv/*` |
| `MediaVectorsTest` | `media/*` |
| `UtilVectorsTest` | `content-keys.json`, `redaction.json`, `xmltv/name-normalization.json`, `xtream/url-vectors.json` (normalize) |
| `XtreamVectorsTest` | `xtream/*` (listeler, dizi bilgisi iki şekil, kısa EPG, 14 hesap durumu, URL'ler, canlı uzantı) |
| `XtreamClientTest` | `XtreamClient` uçtan uca (MockWebServer + vektörler) |
| `LicenseVectorsTest` | `license-token.json`, `trusted-clock.json`, `access-policy.json` |
| `PairCryptoVectorsTest` | `pair-crypto.json` (çözme + sabit iv ile şifreleme), RFC 5869 HKDF |
| `SyncTest` | LWW, anahtar biçimi, kablo formatı, izleme geçmişi |
| `EpgScheduleTest` | şimdi/sıradaki, ilerleme, catch-up uygunluğu |
| `BackendClientTest` | BACKEND_API uçları ve hata eşlemesi |
| `NetworkErrorsTest` | CONTRACT §2 hata eşlemesi ve yeniden deneme politikası |
| `M3uPerformanceTest` | 200k girdi, süre ve bellek sınırı |

## Sürümler

Tüm sürümler tek yerde: [`gradle/libs.versions.toml`](gradle/libs.versions.toml) (core ve
Android modülleri aynı katalogu kullanır). 2026-10-04'te çözümlenip derlendi: AGP 8.13.2,
Kotlin 2.2.21 (KSP 2.2.21-2.0.5), Compose BOM 2025.12.01, tv-material 1.0.1, Media3 1.8.0,
Room 2.8.4, Paging 3.3.6, WorkManager 2.11.0, DataStore 1.1.7, Play Billing 8.3.0, Coil 3.3.0,
ZXing 3.5.3, Robolectric 4.16. Daha yeni ana sürümler (AGP 9, Kotlin 2.3+, Billing 9, compileSdk
37 isteyen androidx sürümleri) bilinçli olarak kullanılmadı: compileSdk/targetSdk 36, minSdk 23.
