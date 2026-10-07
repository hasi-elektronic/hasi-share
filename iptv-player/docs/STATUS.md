# Durum Raporu

Branch: `claude/iptv-player` · PR: hasi-elektronic/hasi-share#3 · Tarih: 2026-10-07

Bu dosya HANDOFF.md'deki A–F işlerinin kapanış raporudur: ne tamamlandı, ne nasıl test edildi
(komut + sonuç), ne bu ortamda doğrulanamadı ve hangi adımlar harici hesap gerektirir.

## 1. Tamamlanan

| Aşama | İçerik | Commit |
|---|---|---|
| A – Backend | Tüm `spec/BACKEND_API.md` endpoint'leri için testler, `scripts/keygen.mjs` (+ testler), `.dev.vars.example`, Türkçe README, e-posta redaksiyonu düzeltmesi, tsc temiz | `e1e70cb` |
| B – Android core | Xtream (gevşek JSON, hesap sınıflandırma, istemci), lisans (ES256 doğrulama, `TrustedClock`, `AccessPolicy`), eşleştirme, senkron LWW, EPG şimdi/sonraki, `BackendClient`, MockWebServer ağ hataları, 200k M3U performans testi | `0aeedad` |
| C – Apple IPTVCore | Tüm ortak vektör testleri, `BackendClient`, `ReconnectPolicy`, 200k M3U performans testi | `9137fc1` |
| D – Android shared + app | Room + FTS4 + Paging, Keystore `SecureStore`, Play Billing 8, `LicenseManager`, senkron, eşleştirme, Media3 oynatıcı; telefon (Compose M3) + Android TV (tv-material, D-pad) | `f06a482` |
| E – Apple IPTVKit + uygulamalar | SQLite/FTS5, Keychain, StoreKit 2, lisans, senkron, eşleştirme, AVPlayer; iOS + tvOS (XcodeGen, aynı bundle id) | `09c5bec` |
| Apple ek işler | Bundle id `com.hasielektronic.novaplayer`, tvOS marka varlıkları, TestFlight'ta tam erişim (sandbox), VLCKit ikinci motor (MKV/AVI/TS…), IPTVX tarzı yeniden tasarım, Almanca üçüncü dil | `70b23da` … `529e094` |
| Performans/UX programı (Apple) | Spec: `docs/superpowers/specs/2026-10-06-performance-ux-design.md`, plan: `docs/superpowers/plans/2026-10-06-performance-ux-apple.md`. PerfTrace + performans katmanı, canlı başlangıç ayarı, komşu kanal ön ısıtma, hızlı başlat, duraklat/sürdür/sarma, izlemeye devam et, EPG indeksi, tek dokunuş favori + geri al, tür başına arama, dizi çoklu kategori, ses gecikmesi (kanal + cihaz), oynatıcı içi kanal paneli, TV rakam tuşları, Canlı TV liste görünümü, şema göçleri v2–v5 | `143fac6` … `54bfc0d` |
| Son inceleme düzeltmeleri | Tüm dal incelemesi: Xtream biçimli adreslerde ön ısıtma bağlantı açmaz (M3U olarak eklenen paneller dahil), Hızlı başlat `AppTransaction` beklemez, yeni kanal açılırken eski motorun olayları yok sayılır | `301639f` |
| Backend kimlikleri | Apple kimlikleri `com.hasielektronic.novaplayer(.lifetime/.trial)`; `APP_IDS` Android + Apple kimliğini birlikte kabul eder | `26680be` |
| F – Kapanış | Bu dosya, `docs/TEST_PLAN.md` (gerçek test adları + ölçümler), README'ler | bu commit |

TestFlight: Build 1–8 yüklendi; **Build 8** (iOS + tvOS) güncel sürümdür, dahili test grubunda.

## 2. Test edilen (komut + sonuç)

Son çalıştırma 2026-10-07, macOS + Xcode, Build 8 kaynağı.

| Komut | Sonuç |
|---|---|
| `cd backend && npm test` | vitest **204/204**, node keygen **5/5** |
| `cd backend && npx tsc --noEmit` | hata yok |
| `cd android && ./gradlew :app:assembleDebug lint test` | BUILD SUCCESSFUL, lint 0 hata; core **90/90**, shared **34/34** (debug + release çalıştırmaları) |
| `cd apple/IPTVCore && swift test` | **91/91** |
| `cd apple/IPTVKit && swift test` | **236/236** (50 000 kanallık bütçeler: panel 3 ms, şimdi/sonraki 2 ms, EPG ızgarası 0,9 ms, arama 24–30 ms) |
| `xcodebuild … -scheme NovaPlayer-iOS -destination 'generic/platform=iOS Simulator' build` | BUILD SUCCEEDED |
| `xcodebuild … -scheme NovaPlayer-tvOS -destination 'generic/platform=tvOS Simulator' build` | BUILD SUCCEEDED |
| iOS UI testleri (`iPhone 17 Pro`, medya sunucuları 8765 + 8766) | **37 geçti**, 0 hata; 4 StoreKit akış testi CLI'da bilerek atlanır |
| tvOS UI testleri (`Apple TV 4K (3rd generation)`) | **20/21**; `testPairingQRCode` çalışan bir geliştirme backend'i ister (aşağıya bakın) |
| Ortak vektörler | Kotlin, Swift ve TypeScript aynı `spec/test-vectors` dosyalarını geçer |
| Android emülatörleri | Telefon + Android TV emülatöründe çalıştırıldı (aşama D) |
| Simülatör ölçümleri (`docs/TEST_PLAN.md` D1–D3) | Zap p50 388 ms / p90 1183 ms; soğuk açılış p50 687 ms / p90 1609 ms (15 örnekten 13'ü ≤ 1,5 s) — Debug derleme, internet üzerinden HLS |

## 3. Doğrulanamayan / açık kalan

**Bu ortamda doğrulanamadı:**
* **Gerçek cihaz performansı** – hitch oranı simülatörde ölçülemiyor (`xctrace`: platform desteklenmiyor); zap ve soğuk açılış gerçek cihaz değerleri kullanıcıdan TestFlight ile gelir (`TEST_PLAN.md` B10).
* **Apple TV hoparlör/TV gecikmesi** – sabit ses kaymasının cihaz gecikmesiyle düzeltilmesi yalnızca gerçek TV'de doğrulanabilir.
* **Gerçek sağlayıcılar** – testler yerel demo listeleriyle yapıldı; gerçek Xtream/M3U hesaplarıyla (bağlantı sınırı, büyük listeler) kullanıcı testi gerekir.
* **StoreKit akışları** – satın alma, bekleyen işlem, iade testleri `xcodebuild` CLI'da atlanır; Xcode'dan StoreKit yapılandırmasıyla çalıştırılmalı.
* **`testPairingQRCode` (tvOS)** – yerel geliştirme backend'i (`wrangler dev`) olmadan çalışmaz.
* **Android performans/UX programı** – Apple fazı tamamlandı; aynı özelliklerin Android'e aktarımı sonraki fazdır (Room DAO'larının çoklu kategori üyeliğine geçişi dahil, CONTRACT §1).

**Harici hesap / mağaza adımları (🔑, bkz. `docs/STORE_SETUP.md`):**
1. **Cloudflare:** D1 veritabanı oluştur, `wrangler.toml` içindeki `REPLACE_WITH_D1_ID` değerini gir, migration'ları uygula, gizli anahtarları (`LICENSE_SIGNING_KEY` — `node scripts/keygen.mjs --write-clients` ile üret, `ADMIN_TOKEN`, `APPLE_PRIVATE_KEY`, `GOOGLE_SERVICE_ACCOUNT_JSON`, `GOOGLE_PUBSUB_TOKEN`, `RESEND_API_KEY`) `wrangler secret put` ile kaydet, `PUBLIC_BASE_URL` ve `MAIL_FROM` değerlerini gerçek alan adına çevir, deploy et.
2. **Resend:** gönderici alan adını doğrula (OTP e-postaları).
3. **App Store Connect:** IAP ürünleri `com.hasielektronic.novaplayer.lifetime` ve `.trial` (fiyat kademesi 0) oluştur, App Store Server Notifications v2 URL'sini backend'e yönlendir, `APPLE_ISSUER_ID` / `APPLE_KEY_ID` / özel anahtarı backend'e gir, sandbox test kullanıcısıyla satın almayı dene, mağaza meta verileri + gizlilik etiketleri + inceleme.
4. **Google Play Console:** uygulama oluştur (applicationId `de.hasielektronik.novaplayer` veya `android/gradle.properties` içinde değiştir), `lifetime_access` ürünü, RTDN Pub/Sub → backend, servis hesabı anahtarı, dahili test kanalı, Android TV form faktörü incelemesi.
5. **Yayın öncesi:** `TESTFLIGHT_FULL_ACCESS = YES` sandbox ortamında (TestFlight **ve App Review**) tam erişim verir; App Store'dan indirilen sürümde etkisizdir. İnceleyicinin deneme/satın alma akışını görmesi için mağaza sürümünden önce `Shared.xcconfig` içinde `NO` yapılmalı.

**Bilinen küçük iyileştirmeler (engelleyici değil):**
* Başlık sekmelerinde seçili etiket kalın ölçüldüğü için seçimde ~1 pt kayma.
* Kategorisinin ilk 200 kanalı dışındaki bir numaraya zap → komşu penceresi yüklenir; çok büyük kategorilerde pencere ±100 kanal.
* Sayısal yol bölümlü bazı CDN adreslerinde (`/…/720.m3u8`) ön ısıtma atlanır (yalnızca hız, bağlantı güvenliği için bilinçli).
* Sıraya girmiş eski bir AVPlayer bildirimi yeni yüklemeden sonra nadiren işlenebilir (öğe nesil etiketi ayrı iş).
* Güncellemeden sonraki ilk açılışta EPG indeksi eşzamanlı kurulur (50k/480k satırda 145–302 ms ölçüldü).
