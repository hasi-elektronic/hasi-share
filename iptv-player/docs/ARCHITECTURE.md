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
7. **Katalog biçim sürümü (`CatalogFormat.current`, Apple: `SourceRefresher.swift`; şu an 2):** her
   başarılı katalog yüklemesi kaynağın kataloğunun hangi biçimle kurulduğunu `kv` tablosuna yazar
   (`catalog.format.<kaynakId>`). Açılışta (`env.start()` → `refreshDueSources`, QuickStart'tan sonra, arka
   planda) kayıtlı sürümü küçük olan **ya da hiç olmayan** (Build 9 öncesi kataloglar) her kaynak, otomatik
   yenileme ayarından bağımsız olarak normal yenileme hattından **bir kez** yenilenir; başarı güncel sürümü
   yazar, hata yazmaz → sonraki açılışta tekrar denenir. Neden: Build 6'nın kaydettiği kataloglarda
   `category_ids` üyelikleri yoktu ve kullanıcı elle yenileyene kadar kategoriler eksik kaldı.
   **Artırma kuralı:** eşleme (ayrıştırıcı → model) ya da saklama (tablo/sütun, üyelik, arama dizini)
   değişikliği mevcut kataloğun **yeniden içe aktarılmasını** gerektiriyorsa `CatalogFormat.current` bir
   artırılır (salt şema göçüyle — `AppDatabase` v1…v5 gibi — veriden türetilebilen değişiklikler için
   artırılmaz). Yalnızca okuma/arayüz değişikliği artırmaz.
   **Sürüm geçmişi:** 1 = Build 6'ya kadar (yazılmazdı) · 2 = Xtream `category_ids` üyelikleri (Build 9) ·
   3 = arama dizini v6, `people` sütunu (oyuncu + yönetmen, Build 10). Build 11'in arama dizini v7'si (açıklama,
   sözlük, EPG dizini) artırmaz – veriden türetilir (bkz. 8).
8. **Arama dizini (Apple, `AppDatabase` v7 + Build 12 kaynak başına tablolar):** FTS5 sütunları
   `(title, people, plot, source_id, kind, item_id)`, `unicode61 remove_diacritics 2`, `rank` = `bm25(10, 4, 1)`
   (başlık ≫ kişi > açıklama). **Build 12:** her kaynağın kendi dizini var – `search_fts_<rastgele>` (adı `kv`
   `search.fts.<kaynakId>`, `prefix = '1 2'`). Yenileme yeni tabloyu staging satırlarıyla birlikte doldurur; commit
   yalnızca `kv` işaretçisini değiştirir, eski tablo takastan **sonra** ayrı işlemde DROP edilir (Build 11'de commit
   her dizin satırını `UPDATE … SET source_id` ile yeniden belirteçliyordu: sahip boyutunda 1–3 sn kilit). Build 11'den
   kalan ortak `search_index` yalnızca henüz yenilenmemiş kaynaklar için okunur; hiçbir kaynak ona ihtiyaç
   duymayınca açılış bakımında (`SearchIndex.maintain`) boşaltılır, ölü kalan tablolar silinir. `people` = Xtream
   `cast` + `director` (", " ile); `plot` = içerik satırının açıklaması (en fazla 1200 karakter dizinlenir).
   Listede olmayan kişiler / açıklamalar detaydan (`get_vod_info` / `get_series_info`) öğrenilir, `item_people` /
   `item_plot` tablolarında tutulur, hemen dizine (satır başlık sözcükleriyle FTS üzerinden bulunur, rowid ile
   güncellenir) ve sonraki yenilemelerde de içeriğe/dizine yazılır; listenin kendi açıklaması değiştirilmez,
   yenileme sürerken öğrenilenler commit'te eklenir. Türkçe noktasız "ı" / noktalı "İ" FTS'de aksan
   sayılmadığından bu harfleri içeren metinlere görünmez bir ayraçtan (U+2063) sonra "ı → i" varyantı eklenir;
   sorgu tarafında "ı"/"İ" her zaman "i"ye çevrilir (görüntülenen metin temiz kalır).
   * **Sorgu:** belirteç başına önek (`"a"* "b"*`); birden çok kelimede tam ifade (`"a b"*`) eşleşen satırlar önce
     (`rowid IN (ifade eşleşmesi)` sıralama anahtarı), sonra `rank`. Genel bakış: `{title}` (tür başına 30, pencere
     fonksiyonu) → `{people} NOT {title}` (Kişiler) → `(tümü) NOT {title} NOT {people}` (Açıklamada; alıntı
     Swift'te `SearchText.snippet`: katlanmış sözcük önekleri, ifade başına göre pencere, "…"). Tam listeler
     (`SearchScope`: titles / people / descriptions / kind) aynı sorgularla `LIMIT 60 OFFSET n`.
   * **v7 göçü (bloklamaz):** v6 tablosu `search_index_v6` adıyla saklanır (anlık), yeni tablo boş kurulur;
     `SearchBackfill` arka planda 2000'lik işlemlerle önce v6 satırlarını (göç anındaki en büyük rowid'e kadar)
     açıklama + `item_*` önceliğiyle kopyalar, sonra (Build 9'dan doğrudan güncellemede) v6 içerik dolgusunu yeni
     tabloya yapar; `kv` imleçleri, uygulama kapansa da kaldığı yerden, hiçbir satır iki kez. Kopya sürerken
     yenilenen / silinen kaynak `search.backfill.copy.skip` listesine girer (eski satırları geri gelmez). Bitene
     kadar arama LIKE yoluyla (yalnız başlık). **CatalogFormat artırılmadı (3 kalır):** kişiler v6 dizininden
     kopyalanır, açıklamalar zaten içerik tablolarında (`movies.plot`, `series.plot`) – yeniden içe aktarma
     gerekmez.
   * **"Bunu mu demek istediniz":** `search_terms(source_id, term, gram, display, freq)` – başlık ve kişi
     adlarının katlanmış ≥ 3 harfli sözcükleri – ve dış içerikli FTS5 `search_terms_tri` (`trigram`, tetikleyicilerle
     güncel; iOS/tvOS 17 sistem SQLite'ı 3.39, trigram 3.34'ten beri, çalışma anında yoklanır). Yenileme, takastan sonra ayrı bir işlemde,
     sözlüğü yalnız değişen sözcüklerle günceller (fark), dolgu ve detaylar sayıları ekler. Sorgunun ön eki
     sözlükte olmayan her kelimesi için trigram OR sorgusuyla 300 aday, Swift'te OSA mesafesi (≤ 4 harf: 1, sonra 2;
     eşitlikte sık kelime). Yalnızca ana sonuç < 5 iken çalışır.
   * **Kısa sorgular:** 1–2 harfte yalnızca başlıklar (+ 2 harften kategoriler); kişi, açıklama, TV programı ve
     düzeltme ≥ 3 harf. Eski sorgu iptal edilince çalışan SQLite ifadesi `sqlite3_progress_handler` ile kesilir
     (`SQLiteDatabase.interruptsOnCancel`, görev yerel).
   * **Öneriler:** `{title}` ve `{people}` önek eşleşmeleri, en fazla 5 (en fazla 2 kişi), 120 ms birleştirme, eski
     sorgu iptal. **Son aramalar:** `RecentSearchStore` – katalog veritabanının `kv` tablosunda (yedeklenmez), kaynak başına
     10, kaynak silinince silinir; yalnızca "Ara" tuşu / öneri / bir sonucu açmada kaydedilir. Build 11'in
     UserDefaults kayıtları bir kez buraya taşınıp silinir.
   * **TV programı araması:** kaynak başına FTS5 `epg_fts_<rastgele>` (`title`, `detail=none`, rowid = `epg.rowid`,
     adı `kv` `epg.fts.<kaynakId>`). EPG yenilemesi staging satırlarıyla birlikte yeni tabloyu doldurur, commit
     aynı işlemde kaydeder ve eskisini **tümden DROP** eder (500k satırlık FTS silmesi yok); iptalde yeni tablo
     silinir, sahipsiz tablolar açılışta temizlenir. Build 11 öncesi saklanan EPG için arka planda 5000'lik
     işlemlerle kurulur (`EpgRepository.maintainSearchIndex`, sürdürülebilir; araya giren yenileme kazanır).
     Sorgu: eşleşme ⋈ `epg` (rowid), pencere şimdi − 2 sa … + 48 sa, sıra yayında → yaklaşan → biten; kanal
     eşleme `lower(epg_id)`, gizli kanal/kategori hariç; biten program yalnızca catch-up kanalında, arşiv
     gününde ve Xtream'de (timeshift URL'si).
   * **Ekran modeli:** `SearchViewModel` (+ `SearchEngine`, `Sendable`) tüm SQL'i ana aktör dışında çalıştırır,
     sonuçları toplu sorgularla kanal/film/diziye çevirir; yeni sorgu eski görevi iptal eder.
   * **Okuma bağlantısı (Build 12):** `SQLiteDatabase` diskteki veritabanında iki bağlantı açar – yazıcı (tüm
     yazmalar ve bir işlemin içinden, aynı iş parçacığındaki okumalar) ve salt okunur okuyucu (diğer tüm
     okumalar). WAL'da okuyucu son commit'i görür ve yazıcıyı **hiç beklemez**: açılıştaki otomatik yenileme veya
     arka plan dolgusu sürerken ana iş parçacığı okumaları (ana sayfa, listeler, oynatıcı, EPG) donmaz (okuyucu:
     `busy_timeout` 1,5 sn, yazıcıyla aynı önbellek).
   * **Ana iş parçacığı yazımları hiç beklemez (Build 13):** oynatıcının ilerleme / "izlendi" kaydı, favori ve son
     aramalar yazıcı boşsa hemen, değilse tek sıralı arka plan kuyruğuna (`DeferredWrites`) gider; kuyrukta
     bekleyen kitaplık öğesi tüm okumalarda üstte görünür (okuduğunu-gör, `LibraryOverlay`). `updatedAt` kullanıcının
     **eylem zamanı** kalır (cihazlar arası LWW); aynı anahtarın daha yeni bir yerel değişikliği kuyruktaysa ya da
     kayıtlı satır o eylemden yeniyse (senkron birleştirme) yazılmaz. Geç yazılan öğe `library_push` işareti alır
     (v8), gönderim imleci zamanını geçmiş olsa da senkronla gönderilir. Uygulama arka plana geçerken kuyruk boşaltılır (iOS/tvOS
     `beginBackgroundTask`, en fazla 20 sn).
   * **Eski dizinler (Build 13/14):** değiştirilen, iptal edilen, silinen kaynağın veya emekli edilen ortak tablo
     `kv` `index.garbage` listesine girer (kapanmaya karşı) ve takastan sonra arka planda **tek DROP** ile, kendi
     işleminde silinir (50k satırda ~40 ms; parça parça FTS silmesi 1,6 sn yazıcı süresi tutuyordu). Açılış bakımı (sahipsiz tabloları bulma, ortak
     tabloyu emekli etme) **tek bir yazıcı işleminde** karar verir: Build 12'de bakım eski eşlemeyi okuyucudan
     okuyup hemen commit edilen yeni dizini silebiliyordu ("no such table" → aramada sonuç yok). Yeni tablo
     commit işlemi bitene kadar "yapımda" sayılır; arama tabloyu sorgu arasında değişmiş bulursa yeni adla bir
     kez yeniden dener (EPG dahil). Ortak tablo boşalınca `search.shared.empty` işaretlenir (her açılışta
     tarama yok). Trigram dizini sonradan kurulursa var olan sözcükler 2000'lik adımlarla eklenir (silme tetikleyicisi dolum
     bitince eklenir); sözlük
     farkı 1500 değişiklikli işlemlerle yazılır.
   * **Tüm kaynaklarda arama** (`sourceId == nil`): her tablodan ilk `offset + limit` satır, `(ifade, rank)` ile
     birleştirilip sayfa kesilir (atlama/tekrar yok). Ölçüm (`CommitLockTests`, sahip boyutu 4k canlı + 35k
     film + 9k dizi açıklamalı, disk, release, Mac): commit takası ~0,27–0,34 sn (içerik tabloları; dizin payı
     ~0 ms), sözlük farkı ~8 ms, commit sürerken okumalar en fazla ~28 ms (beklemez); v7 kopya parçası ~9 ms.
   * **Bütçeler** (`CatalogPerformanceTests`, macOS debug ölçümleri parantezde): 50k film + 10k dizi ile arama
     ≤ 100 ms (açıklama ifadesi ~6 ms, tüm açıklamalarda geçen kelime ~47 ms), düzeltme + düzeltilmiş arama
     ≤ 150 ms (~14 ms, ~30k sözcük), öneriler ~1 ms; 500k EPG satırında program araması ≤ 100 ms (~18 ms).

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
  ama hiç oynamadı → UnsupportedCodec). AVPlayer'da 401/403/404 hata kodundan doğrudan eşlenir
  (`NSURLErrorUserAuthenticationRequired`/`NoPermissionsToReadFile`/`FileDoesNotExist`); ilk
  hazır olmadan gelen nedensiz hata (`Network(other)`, `Unknown`; ör. 410/5xx'te
  `NSURLErrorResourceUnavailable`) ve **8 sn** hâlâ hazır olmayan öğe aynı yoklamayla
  sınıflandırılır (401/403 → AccessDenied, 404/410 → StreamOffline, 5xx → ServerError; 2xx/3xx
  → beklemeye devam). Xtream canlıda `m3u8` tercih edilir; hesap yalnızca `ts`
  izin veriyorsa `ts` + VLCKit.
* **Canlı başlangıç ayarı** (`LiveStartTuning`, her `load`'a verilir; "Büyük tampon" ayarı `largeBuffer`):
  | | AVPlayer | VLCKit `network-caching` |
  |---|---|---|
  | Canlı (varsayılan) | `preferredForwardBufferDuration` 1 sn; `automaticallyWaitsToMinimizeStalling` `load()`'dan ilk kareden 3 sn sonrasına kadar kapalı (bu sürede takılma olursa hemen açılır ve oynatma yeniden başlatılır; zamanlayıcılar yalnızca gerçek `playing` + `readyToPlay` durumunda başlar); ilk varyant `preferredPeakBitRate` 2,5 Mbps ile sınırlı → ilk kareden 4 sn sonra sınır kalkar | 1000 ms |
  | Canlı + büyük tampon | 6 sn, bekleme açık, sınır yok | 3000 ms |
  | VOD | 0 (sistem varsayılanı), sınır yok | 2000 ms (büyük tampon: 4000 ms) |

  Zamanlayıcılar (sınırı kaldırma / bekleme açma) yeni `load`'da ve `stop()`'ta iptal edilir.
  Bekleme kapalıyken `play()` öğe hazır olmadan çağrılırsa AVPlayer hız 1'de saati hiç
  başlatmayabilir (ilk karede donar; 3 sn sonra bekleme açılınca `paused`'a düşer) → öğe
  `readyToPlay` olunca `play()` yeniden çağrılır.
* **Kendiliğinden duraklama yok:** AVPlayer'ın nedeni bilinmeyen bir `paused`'ı (kullanıcı `pause()`/`stop()`
  çağırmadı, öğe bitmedi/başarısız değil, sistem nedeni yok) takılma sayılır: `.buffering` + `.stalled`, bekleme
  açılır; ilk otomatik `play()` 300 ms gecikmeli çalışır (oturum bildirimleri önce gelsin), sonrakiler en
  fazla saniyede bir. Sınır: `PlayerController`'ın 12 sn takılma zamanlayıcısı (ilk takılmadan itibaren; tekrar
  eden takılma süreyi uzatmaz) → `Network(timeout)` → yeniden bağlanma politikası. **Sistem duraklamaları
  takılma değildir ve motor tarafından devam ettirilmez:** `rateDidChangeReason`
  `audioSessionInterrupted` (`.pausedBySystem`) / `appBackgrounded`, AirPlay (`isExternalPlaybackActive`),
  kulaklık/Bluetooth çıkışının kaybolması (`oldDeviceUnavailable`) ve ses kesintisi başlangıcı. Gerçek duraklatma
  (kullanıcı, motorun `.paused`'ı) zamanlayıcıyı iptal eder.
* **Ses oturumu:** uygulama açılışında `AVAudioSession` kategorisi `.playback` / modu `.moviePlayback`
  (iPhone sessiz anahtarı videonun sesini kesmez); oturum her oynatma başlangıcında/devamında
  etkinleştirilir, oynatıcı release/kapatılınca `.notifyOthersOnDeactivation` ile kapatılır (müzik uygulamaları
  devam eder). Arka planda ses yok (V10; `UIBackgroundModes` eklenmez). Kesinti ve çıkış rotası
  değişiklikleri **tek yerde** işlenir: `AudioSessionObserver` → `PlayerController.handleAudioInterruption`
  (kesinti başladı / `oldDeviceUnavailable` → kullanıcı-duraklatması yolu: `engine.pause()`, ilerleme kaydı;
  yükleme/yeniden bağlanma sırasında da `.paused`; kesinti `shouldResume` ile biterse yalnızca kesintinin
  duraklattığı oynatma devam eder, kulaklık çıkarılınca otomatik devam yok; `appWasSuspended` kesintisi yok
  sayılır). **Yapışkan duraklama:** kesintinin sonunda yalnızca oynatma sırasında (veya motorun kesinti
  duraklamasını bildirdiği anda) kesintinin kendisinin duraklattığı oynatma devam eder; kullanıcı, kulaklık,
  AirPlay ya da `shouldResume`'suz biten kesinti duraklamaları yalnızca kullanıcıyla devam eder. Oynatma
  tuşu oturumu yeniden etkinleştirir. Duraklatılamayan girdi (libVLC, kesintisiz canlı TS: `canPause` false)
  duraklatmada durdurulur, oynatma yayını yeniden açar. Sahne döngüsü (Denetim Merkezi, çağrı) duraklamayı
  geri almaz: `release()` duraklamayı hatırlar, `resumeAfterRelease()` duraklamış hâlde kalır (konum korunur,
  oynat yeniden açar). VLCKit kendi ses çıkışında kategoriyi `.playback`/`.moviePlayback` olarak bırakır
  (simülatörde doğrulandı); `activate()` kategoriyi yine de yeniden uygular.
* **Ses senkronu (A/V gecikmesi):** `AudioDelayStore` (cihaza yerel `KeyValueStore`) içerik anahtarı
  başına bir gecikme + bir cihaz/soundbar gecikmesi tutar (−2000…+2000 ms, 50 ms adım; pozitif = ses
  daha geç). Etkin gecikme = clamp(içerik + cihaz). Etkin gecikme ≠ 0 ⇒ **VLCKit** (CONTRACT §6.1;
  AVPlayer'da ses gecikmesi yok, `setAudioDelay` AVPlayer'da işlemsiz). AVPlayer oynarken gecikme
  değişirse aynı yayın VLCKit'te yeniden açılır (VOD aynı konumdan, canlı canlı uçtan) ve o açılışta
  VLCKit'te kalır. VLCKit: libVLC işaretiyle (`currentAudioPlaybackDelay`, µs, + = ses geç); libVLC
  gecikmeyi girdi (input) üzerinde tutar, her yeni medyada sıfırlar ve girdi oluşmadan yok sayar →
  her öğe `:audio-desync=<ms>` ile başlar, `play()` sonrası, `playing`'de, rota değişiminde ve ses
  izi değişiminde yeniden yazılır (iz değişiminde libVLC korur; savunma amaçlı). İşaret libVLC
  kaynağından doğrulandı: `DecoderFixTs` ses zaman damgalarına gecikmeyi **ekler**.
  **Otomatik çıkış gecikmesi:** libVLC 3'ün iOS/tvOS ses çıkışı (`audiounit_ios.m`)
  `AVAudioSession.outputLatency`'yi çıkış başlarken ve her rota değişiminde zaten okuyup senkron
  hesabına katar (`ca_SetDeviceLatency`, en fazla 1 sn). Bu yüzden uygulama gecikmeyi ikinci kez
  eklemez; yalnızca 1 sn'nin üstündeki kısmı (AirPlay ≈ 2 sn) negatif gecikme olarak ekler
  (`VLCLatencyCompensation`). "Senkronu düzelt" (`resync()`): canlıyı canlı uçtan, VOD'u mevcut
  konumdan yeniden açar; yeni istek henüz çözümlenirken (`resolving`) senkron eylemleri hiçbir şey
  yapmaz; kanal değişiminin 400 ms debounce'u beklerken de öyle (önceki kanal yeniden açılmaz). Yeniden bağlanma zaten yayını yeniden açar (canlı: canlı uç) ve
  yeni öğe gecikmeyle başlar; ayrıca ikinci bir yükleme yapılmaz. Yalnızca gecikme yüzünden VLCKit'e
  giden (AVPlayer'ın oynatabildiği) yayın VLCKit'te biçim/kodek hatası verirse bir kez gecikmesiz
  AVPlayer ile açılır ve "Senkron bu yayında uygulanamadı" notu görünür (kayıtlı gecikme korunur).
  Performans katmanı motoru, `outputLatency`'yi (ms) ve libVLC'den geri okunan uygulanan
  gecikmeyi gösterir.
* **M3U canlı TS → HLS tercihi:** M3U'daki Xtream biçimli canlı `.ts` URL'si için önce aynı URL'nin
  `.m3u8` hâli 1,5 sn'lik GET ile yoklanır (200 + `#EXTM3U` → HLS/AVPlayer; aksi hâlde `.ts`/VLCKit;
  CONTRACT §4.5).
* Yeniden bağlanma: `ReconnectPolicy` (1-2-4-8-15 sn, 5 deneme, 30 sn stabil oynatmada sıfırlanır).
* Kanal değiştirme: aynı oynatıcı örneği yeniden kullanılır, 400 ms debounce, bilgi kartı anında.
  Yeni istek çözümlenirken (`resolving`) motor hâlâ önceki öğeyi bildirir: bu olaylar (oynatma, hata,
  bitiş, zaman) yok sayılır – faz, ilk kare ölçümü (`PerfTrace`), `LastSession` ve yeniden bağlanma
  yalnızca yeni yüklenen akışa aittir.
* Ses/altyazı: Media3 `TrackSelectionParameters` / AVFoundation `AVMediaSelectionGroup` /
  VLCKit `audioTrackIndexes` + `videoSubTitlesIndexes` (dil `tracksInformation`'dan).
* Görüntü oranı: Media3 `resizeMode` (+ 16:9 / 4:3 için `AspectRatioFrameLayout` oranı) /
  AVPlayerLayer `videoGravity` (+ sabit oranlı çerçeve) / VLCKit `videoAspectRatio` +
  `videoCropGeometry` (görünüm oranına göre; 16:9 / 4:3 aynı sabit çerçevede).
* İlerleme: VOD'da 10 sn'de bir + duraklat/çıkışta kaydedilir; `≥ %95` → izlendi.
* Yaşam döngüsü: ekran kapanınca / arka plana geçince oynatıcı **release** edilir
  (Android `ON_STOP`, iOS `scenePhase != .active`), pozisyon kaydedilir.

### 3.3 Kalıcı depolama: tvOS silinebilir alan ve dayanıklı ayna (Build 14)
tvOS uygulamalarının yalnızca ~500 KB'lık **kalıcı** yerel alanı vardır (NSUserDefaults); Application Support ve
Caches dahil konteynerin geri kalanı sistem yer gerektiğinde **silinebilir**. Sahibin kataloğu büyük (≈4k canlı,
35k film, 9k dizi, ~500k EPG satırı + FTS dizinleri), bu yüzden `catalog.sqlite` TestFlight güncellemelerinden sonra
silinebiliyordu – kaynak listesi yalnızca veritabanında olduğu için "Apple TV Xtream kodunu siliyor" görünüyordu.
Gizli bilgiler Keychain'de (`ThisDeviceOnly`) ve silinmez.

* **`DurableStateMirror` (IPTVKit)**: kalıcı anahtar/değer deposunda (uygulamada `UserDefaults`, testlerde bellek
  içi) küçük bir kopya.
  * `durable.sources.v1`: kaynak tanımları (**gizli bilgi yok** – `Source` yalnızca ad/tür/host/ayarlar/son durum
    içerir) + seçili kaynak kimliği, sürümlü JSON. Her ekleme / düzenleme / sıralama / silmede
    (`SourceRepository.save/reorder/delete`) hemen yazılır; ilk açılışta veritabanından tohumlanır.
  * `durable.userState.v1`: tüm favoriler (en çok 2000), en yeni 300 ilerleme kaydı, kaynak başına son 10 arama
    (en çok 20 kaynak), senkron imleçleri (`sync.cursor`, `sync.lastPushMs`) – konumsal dizilerle sıkı JSON,
    zlib ile sıkıştırılmış. Değişiklikte en çok **3 sn'de bir** (ilk değişiklik hemen, aradakiler birleştirilir)
    ve uygulama arka plana geçerken (`DeferredWrites` boşaltıldıktan sonra) yazılır. Kaynak yokken (boş/silinmiş
    veritabanı) hiç yazılmaz: boş durum, geri yüklenebilecek aynayı ezemez.
  * Favori sırası, favori kategoriler, kategori tercihleri ve gizli kanallar zaten `UserDefaults`'tadır (ayna gerekmez).
  * **Bütçe**: aynanın toplamı ≤ **200 KB** (kullanıcı durumu payı 170 KB). Aşılırsa önce en eski ilerleme, sonra
    en eski favoriler çeyrek çeyrek atılır. Ölçüm (`DurableStateMirrorTests.testSizeBudgetForALargeLibrary`):
    5 kaynak ≈ 2,7 KB; 500 favori + 300 ilerleme + 50 arama ≈ 22 KB (sıkıştırılmış); toplam ≈ 25 KB.
* **Geri yükleme** (`AppEnvironment` başlatılırken, her şeyden önce): veritabanında kaynak yok ama aynada var →
  kaynaklar **aynı kimlik ve sırayla** eklenir, seçili kaynak geri gelir; Keychain'de gizli bilgisi olmayan kaynak
  atılmaz, "geçersiz kimlik bilgileri" durumuyla kalır. Kütüphane boşsa favoriler/ilerleme **orijinal
  `updatedAt`** ile yazılır (var olan daha yeni satır kazanır) ve **push işareti (`library_push`) oluşturulmaz**;
  senkron imleçleri de geri geldiği için senkron bu satırları yeniden göndermez. Gizli bilgisi olan her kaynak
  arka planda, sırayla, normal yenileme hattından **bir kez** yenilenir (`refreshDueSources` bu açılışta onları
  atlar; açılışı ve QuickStart'ı bekletmez). Yenileme sürerken alt kenarda odaklanamayan, dokunulamayan
  "Katalog yeniden yükleniyor…" (`catalog_restoring`) bildirimi görünür.
* **Veritabanı açma** (`AppDatabase.open`, asla başarısız olmaz): Application Support → dosya bozuksa
  (`SQLITE_CORRUPT`/`SQLITE_NOTADB`) silinip bir kez daha → Caches → bellek içi (yalnızca bu açılış; ayna bir sonraki
  açılışta yine geri yükler). Loglar yol içermez (`SafeLog`, yalnızca hata kodu ve konum).
* iOS'ta Application Support nadiren silinir; aynı kod yolu bozuk dosyayı da kapsar.
* **Test**: `DurableStateMirrorTests` (ayna güncelleme, geri yükleme, eksik gizli bilgi, gidiş-dönüş, bütçe,
  açma sırası) ve UI testleri `IOSCatalogRestoreTests` / `TVCatalogRestoreTests`: DEBUG `-uiSandbox <ad>` (gerçek
  SQLite + Keychain + UserDefaults, test adlarıyla) ve `-debugDeleteCatalogDB` (silinmeyi taklit eder) ile.

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
  bedel: tek bağlantılı hesaplarda daha az ısınma). **Xtream biçimli URL** (`{base}/[live/]U/P/{sayı}` + `.ts` /
  `.m3u8` / uzantısız; ör. `get.php?type=m3u_plus` ile M3U olarak eklenmiş Xtream hesabı) kaynak türünden
  bağımsız olarak hesabı bilinmeyen Xtream sayılır: bayt okunmaz ve URL ön ısıtmada **çözülmez** bile, çünkü
  çözümleyici panele istek atar (`.m3u8` ikizi GET'i / içerik koklama) – geçişte doğrudan açılış gibi çözülür. Başka bir kanal açılınca (önbellekte yoksa),
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
