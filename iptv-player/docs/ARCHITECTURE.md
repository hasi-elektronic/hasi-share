# Mimari

> Uygulama adı **NovaPlayer** bir yer tutucudur; yalnızca yapılandırma dosyalarında geçer
> (bkz. `spec/CONTRACT.md §0`). Kod paketleri ad-bağımsızdır (`io.iptvplayer.*`, `IPTVCore`).

## 1. Genel bakış

```
 ┌──────────────── Android ailesi (Kotlin) ───────────────┐   ┌──────────────── Apple ailesi (Swift) ────────────────┐
 │  app  ── MobileActivity (Compose M3, alt menü)          │   │  Apps/iOS  (SwiftUI TabView)                          │
 │       └─ TvActivity     (Compose for TV, sol menü)      │   │  Apps/tvOS (SwiftUI, odak motoru)                     │
 │  shared ─ ViewModel'ler · Room · Keystore · DataStore   │   │  Shared (ortak SwiftUI bileşenleri + xcstrings)       │
 │          Media3 PlayerController · Play Billing 8       │   │  IPTVKit ─ ViewModel'ler · SQLite(FTS5) · Keychain     │
 │          LicenseManager · Sync · Pairing · WorkManager  │   │   PlayerController (AVPlayer + VLCKit) · StoreKit 2   │
 │  core (saf Kotlin/JVM, test edilir)                     │   │  IPTVCore (saf Swift, Linux'ta test edilir)           │
 │   M3U · XMLTV · Xtream · format tespiti · lisans/saat   │   │   M3U · XMLTV · Xtream · format tespiti · lisans/saat │
 │   erişim politikası · eşleştirme şifreleme · redaksiyon │   │   erişim politikası · eşleştirme şifreleme · redaksiyon│
 └───────────────▲────────────────────────▲────────────────┘   └───────────────▲──────────────────▲───────────────────┘
                 │ M3U / Xtream / XMLTV   │ lisans, hesap, senkron,          │                  │
                 │ (doğrudan, cihazdan)   │ eşleştirme (HTTPS, JSON)         │                  │
        ┌────────┴───────┐       ┌────────┴──────────────────────────────────┴──┐       ┌───────┴────────┐
        │ IPTV sağlayıcı │       │  Backend: Cloudflare Worker + D1 (minimal)    │◄──────┤ Google Play    │
        │ (kullanıcının) │       │  config · license/sync · auth · sync · pair   │  API  │ Developer API, │
        └────────────────┘       │  webhooks (RTDN, ASSN v2) · admin · cron      │◄──────┤ App Store      │
                                 └───────────────────────────────────────────────┘       │ Server API     │
                                                                                          └────────────────┘
```

**Temel ilke:** IPTV içeriği ve kimlik bilgileri cihazda kalır. Uygulama yayınları doğrudan
kullanıcının kaynağından oynatır; backend yalnızca deneme/lisans, isteğe bağlı hesap,
senkronizasyon ve TV eşleştirmesi için vardır. Eşleştirmede bile backend yalnızca uçtan uca
şifreli veri görür.

**Platformlar arası tutarlılık:** Davranış kuralları `spec/CONTRACT.md` içinde tek yerde
tanımlıdır; Kotlin, Swift ve TypeScript kodları aynı test vektörlerini (`spec/test-vectors/`)
çalıştırır. Arayüz metinleri tek kaynaktan (`spec/strings.json`) iki platforma üretilir.

## 2. Platform kararları

| Konu | Android / Android TV | iOS / tvOS |
|---|---|---|
| Dil / UI | Kotlin 2.2, Jetpack Compose (mobil: Material 3, TV: `androidx.tv:tv-material`) | Swift 5.10+/6, SwiftUI (iOS 17+, tvOS 17+) |
| Oynatıcı | Media3 ExoPlayer 1.8 (HLS, DASH, RTSP, progresif TS/MP4/MKV/FLV/AVI) | İki motor: AVPlayer (HLS, MP4/MOV) + VLCKit 3.7 (MKV/WebM, AVI, FLV, progresif TS, DASH, RTSP, RTMP) – CONTRACT §6.1 |
| Paket yapısı | **Tek APK / tek applicationId**, iki launcher aktivitesi (LAUNCHER + LEANBACK_LAUNCHER) → telefon ve TV aynı satın alımı görür | **Aynı bundle id** ile iOS + tvOS hedefleri → Universal Purchase |
| Paylaşılan kod | `core` (JVM) + `shared` (Android library: veri, oynatıcı, lisans, ViewModel) | `IPTVCore` (cross-platform) + `IPTVKit` (Apple-only: veri, oynatıcı, StoreKit, ViewModel) |
| Veritabanı | Room + FTS4 + Paging 3 | SQLite (sistem `SQLite3`) + FTS5, sayfalı sorgular |
| Güvenli depolama | Android Keystore AES-GCM anahtarı ile şifreli kayıtlar | Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) |
| Ayarlar | DataStore Preferences | UserDefaults |
| Görsel önbellek | Coil 3 (bellek + disk) | URLCache (disk 200 MB) + NSCache |
| Arka plan yenileme | WorkManager (periyodik, ağ koşullu) | Uygulama açılışında/ön plana gelişte (tvOS/iOS arka plan kısıtları) |
| Satın alma | Play Billing 8, INAPP `lifetime_access` (tüketilmez) | StoreKit 2, non-consumable `…lifetime` + ücretsiz `…trial` |
| QR | ZXing core | CoreImage `CIQRCodeGenerator` |
| Bağımlılık enjeksiyonu | Manuel `AppGraph` (Hilt/kapt yok → daha basit derleme) | Manuel `AppEnvironment` |

### Neden native iki aile (KMP değil)?
Gereksinim açıkça Kotlin/Compose/Media3 ve Swift/SwiftUI/AVPlayer istiyor. Kotlin Multiplatform
ile çekirdeği paylaşmak mümkündü; ancak iOS tarafında Swift-native API, StoreKit 2 / async-await
uyumu ve Linux'ta Swift çekirdeğinin bağımsız test edilebilmesi için iki ayrı çekirdek + **ortak
sözleşme ve ortak test vektörleri** seçildi. Davranış farkı riski vektörlerle kapatılır.

## 3. Veri akışı

### 3.1 Kaynak ekleme / yenileme
1. Kullanıcı M3U URL'si veya Xtream bilgilerini girer (TV'de QR eşleştirmesi ile telefondan).
2. Gizli bilgiler (URL, kullanıcı adı, şifre, EPG URL) **yalnızca** güvenli depoya yazılır;
   veritabanında yalnızca `Source` meta verisi (ad, host, durum) durur.
3. Xtream: `player_api.php` → hesap sınıflandırması (CONTRACT §4.4) → kategoriler → canlı /
   film / dizi listeleri (paralel, iptal edilebilir) → veritabanına toplu yazım (1000'lik
   işlemler) → XMLTV (`xmltv.php`) arka planda.
4. M3U: akış halinde satır satır ayrıştırma (dosya belleğe alınmaz) → 1000'lik partiler →
   veritabanı. Başlıktaki `url-tvg` EPG adresi otomatik önerilir.
5. EPG: gzip otomatik tespit, akış halinde ayrıştırma, yalnızca kaynaktaki kanallar ve
   saklama penceresi `[şimdi − max(catchup günü, 1 gün), şimdi + 7 gün]` yazılır.
6. Yenileme atomiktir: yeni veri geçici tabloya/işleme yazılır, başarıyla bitince eskisinin
   yerine geçer (yarım liste görünmez). Favoriler/ilerleme `contentKey` ile bağlı olduğu için
   yenilemeden etkilenmez.

### 3.2 Oynatma
`PlayerController` (her iki platformda aynı sorumluluklar):
* URL'yi oynatma anında oluşturur (Xtream URL'leri kimlik bilgisi içerdiği için saklanmaz).
* Oynatmadan önce `StreamFormatDetector` + platform destek matrisi → desteklenmeyen biçimde
  anlaşılır hata (ör. Apple'da UDP multicast).
* **Apple'da iki motor** (`PlaybackEngine` protokolü, CONTRACT §6.1): HLS, MP4/MOV ve bilinmeyen
  biçimler **AVPlayer** ile (yerel HLS, enerji verimi); MKV/WebM, AVI, FLV, progresif MPEG-TS,
  DASH, RTSP, RTMP **VLCKit** (libVLC 3.7, LGPL-2.1, dinamik framework) ile. Seçim
  `ApplePlayback.engine(for:)`; AVPlayer biçim/kodek hatası verirse aynı yayın **bir kez** VLCKit
  ile yeniden açılır (VOD kaldığı yerden). Her motorun tek örneği kanal değişimlerinde yeniden
  kullanılır; yeniden bağlanma, debounce, ilerleme ve yaşam döngüsü `PlayerController`'da
  motordan bağımsızdır. VLCKit hata nedeni vermediği için hata 1 KiB'lık bir HTTP yoklamasıyla
  sınıflandırılır (403 → AccessDenied, 404 → StreamOffline, erişilemiyor → Network, erişilebilir
  ama hiç oynamadı → UnsupportedCodec). Xtream canlıda `m3u8` tercih edilir; hesap yalnızca `ts`
  izin veriyorsa `ts` + VLCKit.
* **Canlı başlangıç ayarı** (`LiveStartTuning`, her `load`'a verilir; "Büyük tampon" ayarı `largeBuffer`):
  | | AVPlayer | VLCKit `network-caching` |
  |---|---|---|
  | Canlı (varsayılan) | `preferredForwardBufferDuration` 1 sn; `automaticallyWaitsToMinimizeStalling` `load()`'dan ilk kareden 3 sn sonrasına kadar kapalı (bu sürede takılma olursa hemen açılır ve oynatma yeniden başlatılır; zamanlayıcılar yalnızca gerçek `playing` + `readyToPlay` durumunda başlar); ilk varyant `preferredPeakBitRate` 2,5 Mbps ile sınırlı → ilk kareden 4 sn sonra sınır kalkar | 1000 ms |
  | Canlı + büyük tampon | 6 sn, bekleme açık, sınır yok | 3000 ms |
  | VOD | 0 (sistem varsayılanı), sınır yok | 2000 ms (büyük tampon: 4000 ms) |

  Zamanlayıcılar (sınırı kaldırma / bekleme açma) yeni `load`'da ve `stop()`'ta iptal edilir.
* Yeniden bağlanma: `ReconnectPolicy` (1-2-4-8-15 sn, 5 deneme, 30 sn stabil oynatmada sıfırlanır).
* Kanal değiştirme: aynı oynatıcı örneği yeniden kullanılır, 400 ms debounce, bilgi kartı anında.
* Ses/altyazı: Media3 `TrackSelectionParameters` / AVFoundation `AVMediaSelectionGroup` /
  VLCKit `audioTrackIndexes` + `videoSubTitlesIndexes` (dil `tracksInformation`'dan).
* Görüntü oranı: Media3 `resizeMode` (+ 16:9 / 4:3 için `AspectRatioFrameLayout` oranı) /
  AVPlayerLayer `videoGravity` (+ sabit oranlı çerçeve) / VLCKit `videoAspectRatio` +
  `videoCropGeometry` (görünüm oranına göre; 16:9 / 4:3 aynı sabit çerçevede).
* İlerleme: VOD'da 10 sn'de bir + duraklat/çıkışta kaydedilir; `≥ %95` → izlendi.
* Yaşam döngüsü: ekran kapanınca / arka plana geçince oynatıcı **release** edilir
  (Android `ON_STOP`, iOS `scenePhase != .active`), pozisyon kaydedilir.

## 4. Lisans, deneme ve satın alma

### 4.1 Durum makinesi (her iki platformda aynı saf fonksiyon – CONTRACT §7.4)
```
             startTrial               süre doldu (güvenilir saat)
TRIAL_NOT_STARTED ──────► TRIAL_ACTIVE ────────────────► TRIAL_EXPIRED
        │                     │                               │
        └──── satın alma (mağaza doğruladı / lisans token'ı) ─┴──► PURCHASED
                                                                   │ iade / iptal
                                                                   ▼
                                                     (deneme durumuna geri düşer)
canPlay = PURCHASED ∨ TRIAL_ACTIVE      (pending ödeme: yalnızca bilgi bandı)
```
Kilitliyken: oynatıcı açılmaz → Paywall. Kaynak yönetimi, ayarlar, satın alma, geri yükleme
ve içerik listelerine göz atma **açık kalır**.

### 4.2 Deneme süresi neden cihaz saatine dayanmaz?
* **Başlangıç** her zaman güvenilir bir kaynaktan gelir: Android'de backend sunucu saati
  (`trial_start = server now`), Apple'da Apple imzalı işlem tarihi (`purchaseDate` – ücretsiz
  deneme ürünü) + backend kaydı.
* **Bitiş** imzalı lisans token'ındaki mutlak zamandır (`trialEnd`), istemci değiştiremez
  (ES256 imza, gömülü açık anahtar).
* **Şimdiki zaman** `TrustedClock` ile hesaplanır: son sunucu zamanı + monoton saat farkı
  (aynı açılış oturumunda). Cihaz saatini geri almak denemeyi uzatmaz; yeniden başlatmada
  cihaz saati son sunucu zamanının gerisine düşemez.
* IPTV zaten internet gerektirdiği için her açılışta lisans token'ı yenilenir; backend
  kısa süre erişilemezse son bilinen durum kullanılır.

### 4.3 Demo süresinin yönetilmesi
`config.trial_days` (varsayılan 7) admin API'si / admin sayfası ile değiştirilir.
**Karar:** değişiklik yalnızca **yeni** denemeleri etkiler (başlangıçta "anlık görüntü" alınır),
çünkü kullanıcıya başlangıçta söylenen süre sonradan değişmemelidir (Apple 3.1.1 şeffaflık
şartı). Tek tek cihaz/hesap uzatma: `POST /v1/admin/trials/extend`.
Apple'da ücretsiz deneme ürününün adı süreyle eşleşmelidir ("7-day Trial"); süre
değiştirilirse App Store Connect'te ürün adı da güncellenmelidir (STORE_SETUP.md).

### 4.4 Satın alma
* **Google Play:** `lifetime_access` (INAPP, asla consume edilmez). PURCHASED → backend
  doğrular (`purchases.products.get`) ve **acknowledge** eder; backend'e ulaşılamazsa istemci
  kendisi acknowledge eder (3 günlük otomatik iadeyi önlemek için). PENDING → "ödeme
  bekleniyor" bandı. Aynı Google hesabıyla telefon + TV → `queryPurchasesAsync` her ikisinde de
  satın alımı döndürür.
* **Apple:** StoreKit 2 non-consumable. `.pending` (Ask to Buy / SCA) desteklenir,
  `Transaction.updates` dinlenir, geri yükleme `AppStore.sync()`. iPhone + Apple TV aynı Apple
  ID → Universal Purchase.
* **İade / iptal:** Google RTDN `voidedPurchaseNotification` + günlük Voided Purchases taraması;
  Apple ASSN v2 `REFUND`/`REVOKE` (`REFUND_REVERSED` geri açar). İstemci tarafında da mağaza
  kütüphanesi iade edilen ürünü artık döndürmez → bir sonraki açılışta erişim düşer.

### 4.5 Apple ↔ Google arası erişim (isteğe bağlı hesap)
Mağazalar birbirinin satın alımını göremez. Bu yüzden **uygulama hesabı** (e-posta + 6 haneli
kod; TV'de cihaz-kodu akışı ile telefondan giriş) tasarlandı:
1. Kullanıcı hesabına girişliyken satın alır → backend mağaza satın alımını doğrular ve
   lisansı hesaba bağlar.
2. Diğer platformda aynı hesaba giriş → `/v1/license/sync` → `purchased: true, src: "account"`.
3. İade → lisans `revoked` → tüm platformlarda düşer.
Hesap tamamen isteğe bağlıdır; mağaza satın alımları hesapsız çalışır. Hesap silme uygulama
içinden yapılabilir (Apple 5.1.1(v)).

## 5. Minimum backend (Cloudflare Workers + D1)

Neden: (1) Android'de deneme başlangıcı için güvenilir saat ve tekil cihaz kaydı,
(2) satın alma doğrulama/acknowledge/iade bildirimleri, (3) admin tarafından değiştirilebilen
demo süresi, (4) platformlar arası lisans, (5) senkronizasyon, (6) TV eşleştirme röle.
Cloudflare seçimi: sunucu yönetimi yok, ücretsiz katman bu yük için yeterli, D1 SQLite,
cron tetikleyicileri, mevcut Cloudflare hesabı.

| Endpoint grubu | Kimlik | Veri |
|---|---|---|
| `/v1/config` | yok | deneme günü, ürün kimlikleri |
| `/v1/license/sync` | deviceKey (+ opsiyonel oturum) | cihaz kaydı, mağaza kanıtları → imzalı lisans |
| `/v1/auth/*`, `/v1/account` | e-posta kodu, oturum | hesap |
| `/v1/sync` | oturum | favoriler + izleme ilerlemesi (LWW) |
| `/v1/pair/*`, `/pair`, `/link` | kod + gizli anahtar | uçtan uca şifreli kaynak aktarımı, TV girişi |
| `/v1/webhooks/*` | paylaşılan sır / Apple'a yeniden sorgu | iade/iptal |
| `/v1/admin/*`, `/admin` | `ADMIN_TOKEN` | demo süresi, lisans yönetimi |

Gönderilmeyenler: IPTV kullanıcı adı/şifresi, liste/yayın URL'leri, ham cihaz kimlikleri
(yalnızca SHA-256 türevi `deviceKey`), içerik listeleri. Senkronizasyonda yalnızca
`contentKey` (hash tabanlı), başlık ve poster URL'si gider.

## 6. Senkronizasyon
Hesap varsa favoriler ve izleme ilerlemesi `SyncItem` olarak eşitlenir (CONTRACT §8):
uygulama açılışında + ön plana gelişte çekme, değişiklikte 5 sn gecikmeli toplu gönderme,
çakışmada `updatedAt` büyük olan kazanır. Aynı kaynak iki cihazda farklı eklenmiş olsa bile
`contentKey` (kaynak parmak izi + içerik id) aynı olduğu için eşleşir.

## 7. Performans
* Listeler akış halinde ayrıştırılır, UI iş parçacığı hiç bloklanmaz (Dispatchers.IO /
  Swift `Task.detached` + aktör).
* Veritabanına toplu yazım, sayfalı okuma (Paging 3 / LIMIT-OFFSET + keyset), FTS arama,
  250 ms debounce.
* EPG: yalnızca pencere içi ve kaynaktaki kanallar; `(sourceId, channelEpgId, start)` indeksi;
  "şimdi/sıradaki" sorguları indeksli.
* Görseller: boyutlandırılmış çözümleme, bellek + disk önbelleği; TV'de odak dışı satırlarda
  ön yükleme sınırlı.
* Ağ: tüm çağrılar iptal edilebilir, bağlantı 10 sn / okuma 30 sn / toplam 20–120 sn zaman
  aşımı (CONTRACT §2); ekran kapanınca coroutine/Task iptal edilir.
* Oynatıcı: kanal değiştirmede örnek yeniden kullanımı, canlıda düşük başlangıç tamponu
  (AVPlayer 1 sn ileri tampon + 2,5 Mbps ilk varyant sınırı, VLCKit 1000 ms; ayrıntı §3.2).
* Komşu kanal ön ısıtma (`ZapPrefetcher`, yalnızca Apple): canlı kanalın ilk karesinden sonra
  önceki/sonraki kanalın akış URL'si çözülür (**en çok 2 eşzamanlı**, **hücresel / Düşük Veri
  Modu'nda kapalı** – `NWPath.isExpensive/isConstrained`, yol bilinmeyene kadar kapalı). Çözümlenmiş
  akış bir kez tüketilir ve **90 sn** sonra düşer (tokenlı URL'ler eskir); komşuya geçişte
  `StreamResolver` tekrar çağrılmaz. **Bayt ön okuması** (en çok **256 KB**, Range GET) ek bağlantı
  açar ve `max_connections = 1` olan Xtream hesaplarında oynayan yayını düşürebilir; bu yüzden
  yalnızca **HLS** (`.m3u8`) için ve yalnızca kaynak Xtream değilse ya da kayıtlı
  `xtreamAccount.maxConnections > 1` ise yapılır (Xtream + bilgi yok/1 ya da komşu farklı kaynaktan → yalnızca URL çözümü;
  bedel: tek bağlantılı hesaplarda daha az ısınma). Başka bir kanal açılınca (önbellekte yoksa),
  ekran/oynatıcı kapanınca ve uygulama `.active` dışına çıkınca (`release()`) iptal edilir;
  URL'ler loglanmaz.

## 8. Güvenlik özeti
Ayrıntı: `docs/SECURITY.md`. Kısaca: gizli bilgiler Keystore/Keychain'de; veritabanı ve
gizli bilgiler yedeklemeden hariç; tüm loglar `Redactor`'dan geçer (şifre, token, URL
kullanıcı bilgisi, Xtream yol kimlik bilgileri); release'te yalnızca WARN+; lisans token'ı
imzalı; deneme süresi cihaz saatine dayanmaz; eşleştirme uçtan uca şifreli.

## 9. Varsayımlar (belirsiz konularda verilen kararlar)

| # | Varsayım / karar | Gerekçe |
|---|---|---|
| V1 | Uygulama adı `NovaPlayer`, kimlikler `de.hasielektronik.novaplayer` (yer tutucu) | Tek yerden değiştirilebilir |
| V2 | Deneme **kullanıcı "Denemeyi başlat"a bastığında** başlar (ilk açılışta karşılama ekranında) | Apple 3.1.1 şeffaflık; kullanıcı ne olacağını bilir |
| V3 | Demo süresi değişikliği yalnızca yeni denemeleri etkiler; tekil uzatma admin API ile | Başlangıçta verilen söz değişmez |
| V4 | Android denemesi cihaz başına (ANDROID_ID türevi). Fabrika ayarlarına dönüşte yeni deneme mümkündür | Hesap zorunlu olmadan en makul tekillik; Play Integrity ileride eklenebilir |
| V5 | Apple denemesi Apple ID başına (ücretsiz IAP) ve iPhone + Apple TV ortak | Apple'ın önerdiği model |
| V6 | Satın alma tek ürün, tek fiyat; ülke fiyatları mağazada | "Tek seferlik satın alma" |
| V7 | Hesap isteğe bağlı; yalnızca Apple↔Google erişimi ve senkron için | Sürtünmesiz başlangıç |
| V8 | Kilitliyken içerik listelerine göz atılabilir, yalnızca oynatma kilitli | Kullanıcı neyi açacağını görür; gereksinim "oynatma kilitlenecek" |
| V9 | Backend erişilemezse son geçerli token kullanılır; hiç token yoksa Android'de deneme başlatılamaz (Apple'da StoreKit yerel denemesi çalışır) | IPTV zaten internet ister; kötüye kullanım riski düşük tutulur |
| V10 | Arka planda ses / PiP ilk sürümde yok | Kapsam; oynatıcı kaynakları ekran kapanınca serbest bırakılır |
| V11 | Apple'da AVPlayer (HLS, MP4/MOV) + VLCKit (MKV/WebM, AVI, FLV, progresif TS, DASH, RTSP, RTMP); yalnızca UDP/RTP multicast desteklenmez. Xtream canlıda `m3u8` tercih, yalnızca `ts` varsa VLCKit. DASH VLCKit ile (libVLC 3 `adaptive` modülü, DRM'siz) | Sağlayıcıların VOD'ları çoğunlukla `.mkv`; VLCKit LGPL-2.1 (dinamik bağlama + lisans bildirimi, `SECURITY.md §7`), uygulamaya ~35 MB (arm64) ekler |
| V12 | DRM (Widevine/FairPlay) desteklenmez; KODIPROP içeren kanallar "korumalı yayın" hatası verir | Lisans sunucusu entegrasyonu kapsam dışı |
| V13 | Catch-up: Xtream `timeshift` + M3U `catchup` öznitelikleri; Apple'da m3u8 timeshift tercih edilir (ts timeshift VLCKit ile oynatılabilir) | Sağlayıcı desteğine bağlı |
| V14 | EPG saatleri cihaz saat diliminde gösterilir (ayardan değişir); XMLTV'de ofset yoksa UTC; kaynak başına manuel kaydırma | XMLTV DTD + hatalı sağlayıcılar |
| V15 | M3U'da film/dizi ayrımı sezgiseldir (URL yolu, uzantı, `SxxEyy`) | M3U standardı türü taşımaz |
| V16 | Görüntü oranı tercihi global (kanal başına değil) | Basitlik |
| V17 | HTTP (şifresiz) IPTV kaynaklarına izin verilir (Android cleartext, iOS ATS istisnası) | IPTV sunucularının çoğu HTTP; mağaza incelemesinde gerekçelendirilir |
| V18 | Minimum: Android 6.0 (API 23), iOS/tvOS 17 | Eski TV kutuları; SwiftUI `@Observable` |
| V19 | Uygulama içerik sağlamaz, örnek liste içermez | Mağaza politikaları (IPTV uygulamaları) |
| V20 | Senkron edilen başlık/poster gizlilik politikasında belirtilir; hesap silinince silinir | GDPR |
