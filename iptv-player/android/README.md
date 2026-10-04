# Android ailesi (telefon + Android TV)

Tek Gradle projesi, tek `applicationId` (telefon ve TV aynı satın alımı görür). Normatif
kurallar: [`../spec/CONTRACT.md`](../spec/CONTRACT.md), [`../spec/BACKEND_API.md`](../spec/BACKEND_API.md),
mimari: [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

## Modüller

| Modül | Tür | Durum | İçerik |
|---|---|---|---|
| `core` | Saf Kotlin/JVM (included build, Android bağımlılığı yok) | **Tamam, test ediliyor** | M3U, XMLTV, Xtream, format tespiti, lisans, eşleştirme şifrelemesi, senkron modeli, backend istemcisi |
| `shared` | Android library | Sırada (yalnızca üretilmiş `strings.xml` var) | Room + FTS4, Keystore `SecureStore`, DataStore, repository'ler, WorkManager, Play Billing 8, `LicenseManager`, `SyncManager`, `PairingManager`, Media3 `PlayerController`, ViewModel'ler |
| `app` | Android application | Sırada | `MobileActivity` (Compose M3) + `TvActivity` (tv-material), manifest, R8 |

`shared` ve `app` henüz derlenmez; kök build (`./gradlew :app:assembleDebug`) bu yüzden şimdilik
çalışmaz. `core` bağımsız derlenir ve test edilir.

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
Android modülleri aynı katalogu kullanır). Android/Google kütüphanelerinin güncel stabil
sürümleri `shared`/`app` kurulurken doğrulanacak; Play Billing **8+** zorunlu.
