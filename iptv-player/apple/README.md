# Apple ailesi (iOS · iPadOS · tvOS)

Bu klasör Apple tarafının kodunu içerir. Davranış kuralları `spec/CONTRACT.md` ve
`spec/BACKEND_API.md` dosyalarındadır; Swift kodu Kotlin ve TypeScript ile **aynı test
vektörlerini** (`spec/test-vectors/`) geçmek zorundadır.

| Klasör | Durum | İçerik |
|---|---|---|
| `IPTVCore/` | ✅ `swift test`: 86 test yeşil | Platformdan bağımsız Swift Package: modeller, ayrıştırıcılar, ağ, lisans mantığı |
| `IPTVKit/` | ✅ `swift test`: 52 test yeşil | Apple'a özel paket: SQLite + FTS5, Keychain, StoreKit 2, lisans, hesap/senkron, eşleştirme, iki motorlu `PlayerController` (AVPlayer + VLCKit, `PlaybackEngine`), `@Observable` ViewModel'ler |
| `Shared/` | ✅ | Ortak SwiftUI ekranları (iOS + tvOS), tema, `L10n`, `Resources/Localizable.xcstrings` (üretilmiş) |
| `Apps/iOS`, `Apps/tvOS` | ✅ derleniyor, simülatörde çalıştı | Uygulama giriş noktaları: iPhone/iPad üst başlık (metin sekmeleri, sekme çubuğu yok), Apple TV üst sekme çubuğu |
| `Config/` | ✅ | `Shared.xcconfig` (ad, bundle id, ürünler, backend), `Products.storekit`, `PrivacyInfo.xcprivacy`, `license-keys.json`, entitlements |
| `AppTests/iOS` | ⚠️ yalnızca Xcode'dan | StoreKit akış testleri (`SKTestSession`) – komut satırında atlanır, aşağıya bakın |
| `UITests/` | ✅ iOS 6 + tvOS 6 akış testi yeşil (+ VLC testleri) | Ekran görüntüleri (yeniden tasarım turu), Siri Remote ile odak/geri kuralları, Xtream formu (şifre alanı), kilitli oynatma → paywall |
| `project.yml` | ✅ | XcodeGen tanımı (tek doğruluk kaynağı) |

## Yapı

```
apple/
├── project.yml                 XcodeGen → NovaPlayer.xcodeproj (üretilir, git'te YOK)
├── Config/
│   ├── Shared.xcconfig         APP_DISPLAY_NAME, APP_BUNDLE_ID, PRODUCT_LIFETIME, PRODUCT_TRIAL, BACKEND_BASE_URL
│   ├── Debug.xcconfig          Shared + isteğe bağlı, git dışı Local.xcconfig
│   ├── Release.xcconfig
│   ├── Products.storekit       Yerel StoreKit testi: lifetime (9,99) + trial (0) non-consumable
│   ├── PrivacyInfo.xcprivacy   UserDefaults CA92.1, sistem açılış zamanı 35F9.1, toplanan veri türleri
│   ├── license-keys.json       Gömülü lisans açık anahtarları (kid → JWK)
│   └── NovaPlayer(-Debug).entitlements
├── IPTVCore/                   (bkz. aşağıda)
├── IPTVKit/
│   ├── Sources/IPTVKit/
│   │   ├── Database/           SQLiteDatabase (sistem SQLite3, kilitli, deyim önbelleği), AppDatabase (şema, FTS5)
│   │   ├── Repositories/       Catalog (sayfalı + FTS5 arama + atomik yenileme), Epg, Library (favori/ilerleme), Source, SourceRefresher
│   │   ├── Security/           KeychainStore (AfterFirstUnlockThisDeviceOnly), UserDefaults/bellek depoları
│   │   ├── Store/              StoreManager (StoreKit 2)
│   │   ├── License/            LicenseManager (AccessPolicy + TrustedClock + /v1/license/sync + son bilinen token)
│   │   ├── Account/            AccountManager (e-posta kodu, TV cihaz kodu), SyncManager (actor, LWW, 500'lük partiler)
│   │   ├── Pairing/            PairingManager (ECDH/HKDF/AES-GCM, 2 sn yoklama, 10 dk)
│   │   ├── Player/             PlayerController (motordan bağımsız politika), PlaybackEngine (protokol, EngineEvent,
│   │                       TrackNaming, VLCFailureClassifier), AVPlayerEngine, StreamResolver (format ön kontrolü
│   │                       + motor seçimi), PlaybackErrorMapper
│   │   ├── ViewModels/         AddSource, LiveTV, Movies, Series(+Detail), Home, Favorites, Search, EpgGrid, Paywall, FormatTest
│   │   ├── Support/            SafeLog (Redactor), ImageLoader (URLCache 200 MB + NSCache, küçültülmüş çözümleme), AppSettings
│   │   └── AppEnvironment.swift  Manuel DI + uygulama durumu
│   └── Tests/IPTVKitTests/     macOS'ta `swift test`
├── Shared/
│   ├── Player/                 VLCPlaybackEngine (MobileVLCKit/TVVLCKit), EngineVideoSurface (AVPlayerLayer / VLC drawable)
│   ├── Support/                Theme (SCREENS §1 token'ları), L10n, AppBootstrap (+ Router, debug kancaları)
│   ├── Views/                  Welcome/TrialCard, AddSource, Pairing (QR), Home/Filmler/Diziler (hero + satırlar, BrowseView),
│   │                           Canlı TV kart grid'i, TV Rehberi (EPG listesi + yan panel + catch-up arşivi),
│   │                           Movies/Series/Favorites/Search, Player (overlay), Paywall, Settings/Kaynak/Hesap/Format testi
│   └── Resources/Localizable.xcstrings   (node spec/tools/gen-strings.mjs – elle düzenleme yok)
├── scripts/fetch-vlckit.sh     VLCKit ikililerini indirir, SHA-256 doğrular, inceltir → Vendor/VLCKit (git dışı)
├── Apps/iOS/                   NovaPlayerApp (üst başlık: metin sekmeleri + arama + ayarlar sheet'i), Assets (ikon)
├── Apps/tvOS/                  NovaPlayerTVApp (yerel üst TabView, Menü tuşu kuralları)
├── AppTests/iOS/               StoreKitFlowTests
└── UITests/{Shared,iOS,tvOS}/  XCUITest akışları + ekran görüntüsü yardımcısı
```

### Mimari notlar

* **Veritabanı:** `Application Support/catalog.sqlite`, `isExcludedFromBackup`, iOS/tvOS'ta
  `NSFileProtectionCompleteUntilFirstUserAuthentication` (SQLite açılış bayrağı), WAL.
  Arama `search_index` FTS5 tablosu (`unicode61 remove_diacritics 2`, belirteç başına önek eşleşmesi);
  FTS5 yoksa `LIKE` yedeği.
* **Atomik yenileme:** satırlar `kaynakId~staging` kimliğiyle 1000'lik işlemlerle yazılır, başarıda
  tek işlemde canlı kimliğe taşınır; hata/iptalde staging silinir – eski liste görünür kalır.
  EPG ayrı ve **arka planda** yüklenir (kaynak ekleme listeler hazır olunca biter).
* **Gizli bilgiler:** `SourceSecrets` yalnızca Keychain'de; veritabanındaki `Source` JSON'u
  kimlik bilgisi içermez (testle doğrulanır). Kaydedilen gizli değerler `Redactor`'a kaydedilir.
* **Lisans:** `StoreSnapshot` (StoreKit) + doğrulanmış token + güvenilir saat → `AccessPolicy`.
  Backend erişilemezse son geçerli token kullanılır ve "lisans sunucusuna ulaşılamıyor" bandı görünür.
  Deneme başlangıcı Apple'da ücretsiz `…trial` ürününün `purchaseDate` değeridir.
* **Oynatıcı – iki motor** (ayrıntı aşağıda "Oynatıcı: AVPlayer + VLCKit"): HLS/MP4/MOV AVPlayer,
  MKV/WebM/AVI/FLV/progresif TS/DASH/RTSP/RTMP VLCKit. Oynatmadan önce `StreamFormatDetector` +
  `ApplePlayback.engine(for:)`; uzantı belirsizse ilk 1 KiB okunur. Yeniden bağlanma
  `ReconnectPolicy` (1-2-4-8-15 sn), kanal değiştirme 400 ms debounce (bilgi kartı anında),
  ses/altyazı, görüntü oranı (Sığdır/Doldur/Uzat/16:9/4:3), `scenePhase != .active` olunca
  release + pozisyon kaydı – hepsi her iki motorda aynı.
* **tvOS geri tuşu:** içerikte → odak üst sekme çubuğuna (sistem); sekme çubuğunda (Ana Sayfa
  değilse) → Ana Sayfa (`UIFocusSystem` bildirimiyle odağın `UITabBar` içinde olduğu izlenir); Ana
  Sayfa sekmesinde → sistem (uygulamadan çıkış); alt sayfalarda `NavigationStack` kendisi geri gider;
  oynatıcıda önce panel/overlay kapanır, sonra oynatıcıdan çıkılır.

### Arayüz (SCREENS §2–3.6, IPTVX tarzı)

* **iPhone/iPad:** sekme çubuğu yok; üstte uygulama işareti + yatay kayan metin sekmeleri
  (Ana Sayfa · Filmler · Diziler · Canlı TV · TV Rehberi, seçili = beyaz + `primary` alt çizgi) + 🔍 + ⚙️
  (Ayarlar sheet). Başlık hero üzerinde şeffaf, kaydırınca siyah.
* **Ana Sayfa / Filmler / Diziler:** hero (☆ Favori · beyaz "▶ Oynat/Devam et" · ⓘ Bilgi) + satırlar:
  İzlemeye devam et (16:9, ortada oynat ikonu, altta ilerleme), Favoriler, Yeni eklenenler ("YENİ"),
  Top 10 (çerçeveli sıra numaraları; puan, yoksa en yeni), kategori satırları; "Tümünü gör" → grid.
* **Detay:** tam genişlik hero + yuvarlak ▶ + ✕, puan/yıl/süre, açıklama, tür; dizide sezon metin
  sekmeleri + 16:9 bölüm satırları. M3U adlarındaki "(2024) HD" ve "Dizi S01E02" başlıktan temizlenir.
* **Canlı TV:** kanal kartı grid'i (iPhone 2 sütun, TV 4) + yüzen kategori çipi (bayraklı);
  uzun bas → favori / kanalı gizle / kategoriyi gizle (yerel, `HiddenStore`).
* **TV Rehberi:** ortak zaman eksenli EPG listesi; iPad/Apple TV'de "Şimdi yayında" + "Bugün" paneli;
  catch-up arşivi (Xtream `timeshift` ile tekrar izleme).
* **Ayarlar → Açık kaynak lisansları:** VLCKit (LGPL-2.1, kaynak bağlantısı, `Vendor/VLCKit/COPYING.txt`
  tam metni paketlenir), swift-crypto / swift-asn1 (Apache-2.0). Format testi motoru (AVPlayer/VLCKit)
  gösterir ve `expect.apple` ile karşılaştırır.
* **Arama (Build 11, SCREENS §3.6):** son aramalar, yazarken öneriler, filtre çipleri (Tümü · Kategoriler · Canlı ·
  Filmler · Diziler · TV programları), bölüm başına "Tümünü göster" (60'lık sayfalar), açıklamada geçenler (alıntı),
  "TV'de" (EPG programları, oynatır / arşivden oynatır), az sonuçta "Bunu mu demek istediniz" + benzer sonuçlar
  (trigram sözlüğü). Dizin: `AppDatabase` v7, ARCHITECTURE §3.1 madde 8.
* **Ekran görüntüleri:** `IOSFlowTests.testRedesignScreens` + `TVFlowTests` (`TEST_RUNNER_SCREENSHOT_DIR`),
  demo verisi için `-uiSeedLibrary` (devam/favori tohumlar) ve `-uiScreen movieDetail|seriesDetail|guide|search`.

### Performans ve kullanım özellikleri (Build 7)

Bütçeler ve gerekçeler: `docs/superpowers/specs/2026-10-06-performance-ux-design.md`; ölçümler:
`docs/TEST_PLAN.md §D`. Ekran davranışları normatif olarak `docs/SCREENS.md`'dedir.

* **Performans katmanı (`PerfTrace`):** Ayarlar → Gelişmiş ve tanılama → "Performans katmanı" açılınca
  oynatıcıda sol üstte küçük bir kutu görünür: motor (AVPlayer/VLCKit), son zap süresi (+ son 50 örneğin
  p50/p90'ı), tampon durumu, bitrate, düşen kare, ses çıkış gecikmesi ve motorun uyguladığı ses gecikmesi.
  İşaretler: uygulama açılışı → oynatma isteği → ilk kare. Log'a yalnızca süreler (`perf coldStartMs=…`,
  `perf zapMs=…`) yazılır, URL asla (`SafeLog`; DEBUG derlemesinde `info`). DEBUG'da `-perfOverlay`
  katmanı açar.
* **Hızlı başlat (`QuickStart`):** Ayarlar'ın üst düzeyinde, varsayılan açık. Canlı kanal oynarken
  uygulama kapanırsa sonraki açılışta Ana Sayfa ve kaynak yenilemesi beklenmeden o kanal oynatıcıda açılır;
  oynatıcıyı Geri/Kapat ile kapatmak ya da son olarak VOD izlemek bunu kapatır. Canlıda
  komşu kanallar (önceki/sonraki) ilk kareden sonra arka planda çözülür (`ZapPrefetcher`: en fazla 2
  eşzamanlı, ≤ 256 KB, yalnızca HLS ve çoklu bağlantılı hesapta bayt okuması; hücreselde / Düşük veri
  modunda kapalı) – kanal değişimi bu çözümü kullanır.
* **Ses senkronu:** oynatıcı → **Ses** → **Senkron**: "Bu kanal/içerik" (içerik anahtarıyla kaydedilir) ve
  "Ses gecikmesi (TV/soundbar)" (**cihaz gecikmesi**, her içeriğe eklenir; Ayarlar'ın üst düzeyinde de var).
  −2000…+2000 ms, 50 ms adım, canlı uygulanır; tvOS'ta ◀▶ basılı tutunca hızlanır. **Etkin gecikme ≠ 0
  ise yayın VLCKit ile oynatılır** (AVPlayer HLS'de ses gecikmesi uygulayamaz); 0'a dönünce sonraki
  açılışta AVPlayer'a dönülür, VLCKit oynatamazsa yayın gecikmesiz AVPlayer'da sürer ve not görünür.
  Katmandaki "Senkronu düzelt" canlıyı canlı uçtan, VOD'u mevcut konumdan yeniden açar. Ayrıntı:
  SCREENS §3.7, ARCHITECTURE §3.2.
* **Oynatıcı içi kanal paneli:** iPhone'da katmandaki liste düğmesi veya soldan kaydırma, Apple TV'de
  katman kapalıyken **OK**: kategori seçici (Tümü · Favoriler · kategoriler) + kanallar + şu anki
  program, oynatma sürerken; favoriler önce. Satıra dokunmak/OK o kanala geçer ve gösterilen liste
  zapping listesi olur.
* **TV rakam tuşları (numara ile kanal):** canlıda girilen rakamlar (en fazla 4 hane) sağ üstte büyük
  görünür; son rakamdan 1,5 sn sonra numara **kaynağın tüm kanallarında** aranır (`(source_id, number)`
  indeksi). Kaynakta hiç numara yoksa listedeki sıra numarası sayılır; olmayan numara → "Kanal yok",
  kanal değişmez. Siri Remote'ta rakam yoktur (HDMI-CEC / klavye).
* **Canlı TV listesi + favori:** satır başına numara, logo, ad, şimdi/sonraki; bilgi paneli (iPad,
  iPhone yatay, tvOS). ⭐ tek dokunuş + 4 sn "Geri al"; favoriler her listede önce. Sıra cihazda
  tutulur. Diziler/Filmler'de her kategoriye "Kategoriler" sayfasından (iOS) / sol kategori sütunundan (tvOS) ulaşılır, ülke filtresiyle (Build 9, SCREENS §3.2) (`item_categories`: bir öğe birden çok
  kategoride görünür; veritabanı şeması v2–v5 göçleriyle yükselir, mevcut veri korunur).

## Oynatıcı: AVPlayer + VLCKit

```
PlayerView ──► PlayerController (IPTVKit, @Observable)          ◄── politika: faz, yeniden bağlanma,
                 │  StreamResolver → ResolvedStream.engine            zap debounce, ilerleme, geri dönüş
                 ▼
          PlaybackEngine (protokol, EngineEvent)
           ├─ AVPlayerEngine      (IPTVKit)   HLS, MP4/MOV, bilinmeyen
           └─ VLCPlaybackEngine   (Shared/Player, MobileVLCKit | TVVLCKit)  MKV, WebM, AVI, FLV, TS, DASH, RTSP, RTMP
EngineVideoSurface (UIViewRepresentable): AVPlayerLayer veya VLC drawable UIView
```

* **Seçim** (CONTRACT §6.1, vektör `media/expected.json` → `appleEngine`): AVPlayer'ın oynattığı
  her şey AVPlayer'da kalır (yerel HLS, enerji, AirPlay); geri kalanı VLCKit. UDP multicast
  desteklenmez. Xtream canlıda `m3u8` tercih; hesap yalnızca `ts` izin veriyorsa `ts` + VLCKit.
* **Geri dönüş:** AVPlayer `UnsupportedFormat`/`UnsupportedCodec` verirse aynı yayın **bir kez**
  VLCKit ile açılır (VOD kaldığı yerden); bu yayının sonraki yeniden bağlanmaları da VLCKit'te kalır.
  VLCKit → AVPlayer geri dönüşü yoktur.
* **VLCKit hataları:** libVLC neden bildirmez → `VLCFailureClassifier` 1 KiB'lık range isteğiyle
  sınıflandırır (401/403 → AccessDenied, 404/410 → StreamOffline, 5xx → ServerError, bağlantı yok →
  Network, erişilebilir ama hiç oynamadı → UnsupportedCodec, oynarken koptu / canlı "bitti" →
  Network → yeniden bağlanma politikası).
* **Parçalar:** `audioTrackIndexes` / `videoSubTitlesIndexes` ("Disable" hariç) + dil
  `media.tracksInformation`'dan; adlar `TrackNaming` ile UI dilinde ("tur" → "Türkçe"/"Turkish"),
  bilinmiyorsa "Parça n". Tercih edilen ses/altyazı dili ilk parçalar gelince uygulanır.
* **Görüntü oranı (VLCKit):** Sığdır → varsayılan; Doldur → `videoCropGeometry` = görünüm oranı;
  Uzat / 16:9 / 4:3 → `videoAspectRatio` = görünüm oranı (16:9 ve 4:3'te SwiftUI çerçeveyi zaten
  o orana sabitler, AVPlayer'daki `.resize` ile aynı sonuç).
* **Önbellek:** canlı `:network-caching=1500`, VOD 2000 ms; `User-Agent`/`Referer` M3U'dan
  `:http-user-agent` / `:http-referrer`; devam pozisyonu `:start-time`.
* **Test:** `IPTVKit/Tests/IPTVKitTests/EngineTests.swift` sahte motorlarla (VLCKit gerekmez).

### VLCKit bağımlılığı

| | |
|---|---|
| Sürüm | **VLCKit 3.7.3** (`319ed2c0-79128878`, Şubat 2026) – son kararlı 3.x; VLCKit 4 hâlâ alfa |
| Kaynak | Resmî VideoLAN ikilileri: `https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz` ve `TVVLCKit-…` (Carthage/CocoaPods JSON'ları `code.videolan.org/videolan/VLCKit/-/tree/master/Packaging`) |
| Neden SPM değil | Resmî `Package.swift` yalnızca VLCKit 4 alfa (`cocoapods/unstable`) nightly zip'ini gösteriyor; 3.x için resmî SPM yok, gayriresmî paketler doğrulanamaz |
| Bütünlük | `scripts/fetch-vlckit.sh` SHA-256 doğrular (`0d040599…a0a9` iOS, `b5f90c22…e46c` tvOS) |
| İnceltme | cihaz: yalnızca `arm64` (armv7/armv7s silinir), simülatör: `arm64 x86_64` (i386 silinir), simülatör dSYM'leri silinir; bitcode yok |
| Bağlama | **Dinamik** framework, `embed: true` (LGPL-2.1, bkz. `docs/SECURITY.md §7`) |
| Boyut | `MobileVLCKit` arm64 ≈ 36 MB, `TVVLCKit` arm64 ≈ 35 MB (sıkıştırılmamış, uygulamaya eklenen) |

`xcodegen generate` betiği `preGenCommand` olarak otomatik çalıştırır (sürüm damgası tutuyorsa hiçbir şey
yapmaz). İndirme önbelleği `~/Library/Caches/NovaPlayer/vlckit` (`VLCKIT_CACHE`), yeniden kurmak için
`VLCKIT_FORCE=1 scripts/fetch-vlckit.sh`. Güncelleme: betikteki `VERSION`, `BUILD`, iki SHA-256.

### VLCKit doğrulaması (simülatör)

Range destekli yerel sunucu (VLC, HTTP üzerinden MKV'de atlama için Range ister; `python3 -m
http.server` desteklemez) ve üç liste: `vlc-live.m3u` (1: uzantısız MKV, 2: progresif MPEG-TS
MPEG-2/MP2, 3: Apple HLS), `vlc-movie.m3u` (MKV film) ve `vod-movie.m3u` (aynı film progresif MP4
olarak → AVPlayer; `ffmpeg -i sintel.mkv -map 0:v:0 -map 0:a:1 -c copy -movflags +faststart
sintel.mp4`) ile `vod-403.m3u` (HTTP 403 dönen bir film: sunucu `/status/<kod>/…` yollarını o HTTP
durumuyla yanıtlar → `IOSPlaybackRobustnessTests`/`TVPlaybackRobustnessTests` AccessDenied kartı).
Test medyası ffmpeg ile üretilir (H.264 + AC-3 `tur` + AAC `eng`, SRT `tur`/`eng`).
Oynatıcı kontrolleri (`IOSPlayerControlsTests`, `TVPlayerControlsTests`: ±10 sn, çift dokunma,
zaman çizgisi, devam + "Baştan başla", katman yeniden gösterilince düğmeler) da bu sunucuyu
kullanır.

```sh
TEST_RUNNER_SCREENSHOT_DIR=/tmp/screens/vlc TEST_RUNNER_VLC_MEDIA_BASE=http://localhost:8766 \
xcodebuild test -project NovaPlayer.xcodeproj -scheme NovaPlayer-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:NovaPlayer-iOSUITests/IOSVLCPlaybackTests
# tvOS: -scheme NovaPlayer-tvOS … -only-testing:NovaPlayer-tvOSUITests/TVVLCPlaybackTests
```

Sunucu yoksa bu testler **atlanır** (`XCTSkip`), normal UI test koşusu etkilenmez.

## Proje üretimi (XcodeGen)

`project.yml` tek doğruluk kaynağıdır; `NovaPlayer.xcodeproj` ve `Apps/*-Info.plist` **üretilir ve
git'e girmez** (`.gitignore`). Karar gerekçesi: proje dosyası birleştirme çakışması üretmez, iki
platform hedefi ve şemalar tek yerde tanımlıdır.

```sh
brew install xcodegen          # 2.46 ile doğrulandı
cd apple
xcodegen generate              # → NovaPlayer.xcodeproj (preGenCommand: scripts/fetch-vlckit.sh → Vendor/VLCKit)
open NovaPlayer.xcodeproj      # Şemalar: NovaPlayer-iOS, NovaPlayer-tvOS
```

iOS ve tvOS hedefleri **aynı bundle id**'yi (`$(APP_BUNDLE_ID)`) kullanır → Universal Purchase.
Simülatör için imzalama ekibi gerekmez (ad-hoc, `CODE_SIGN_IDENTITY = -`). Cihaz için Xcode'da
ekip seçin veya `DEVELOPMENT_TEAM` ayarını komut satırından verin.

## Derleme ve test (komut satırı)

```sh
cd apple
# Paketler (macOS)
(cd IPTVCore && swift test)    # 91 test
(cd IPTVKit && swift test)     # 230 test: SQLite repo'ları (bellek içi), atomik yenileme, FTS5, motor seçimi/geri dönüş,
                               # LicenseManager geçişleri (sahte backend + ES256 imzalayıcı),
                               # SyncManager partileri/debounce/LWW, eşleştirme, hata eşleme, resolver,
                               # Build 7: PerfTrace, ZapPrefetcher, QuickStart, ses gecikmesi, favori denetleyicisi,
                               # numara zap, şema göçleri v2–v5 ve 50 000 kanallık performans bütçeleri

# Uygulamalar
xcodebuild -project NovaPlayer.xcodeproj -scheme NovaPlayer-iOS \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build
xcodebuild -project NovaPlayer.xcodeproj -scheme NovaPlayer-tvOS \
  -destination 'generic/platform=tvOS Simulator' -derivedDataPath build/DerivedData build

# Testler (simülatör adıyla veya UDID ile)
xcodebuild test -project NovaPlayer.xcodeproj -scheme NovaPlayer-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData
xcodebuild test -project NovaPlayer.xcodeproj -scheme NovaPlayer-tvOS \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -derivedDataPath build/DerivedData
```

UI testleri yerel bir test listesi kullanır (uygulamada örnek liste yoktur – V19):

```sh
# 1) Test M3U + XMLTV'yi Mac'te sunun (simülatör Mac'e localhost ile ulaşır)
mkdir -p /tmp/iptv-test && cd /tmp/iptv-test   # test.m3u (ör. Apple bipbop HLS) + epg.xml
python3 -m http.server 8765 --bind 127.0.0.1
# Kişi/kategori arama testi (IOSPeopleSearchTests) 8766 sunucusunda sahte Xtream paneli ister:
# UITests/Fixtures/range_server.py, /player_api.php?action=X → xtream/X.json (UITests/Fixtures/xtream/
# dosyalarını sunucu klasöründe xtream/ altına kopyalayın; yoksa test XCTSkip ile atlanır).
# Kategori gezintisi testleri (IOS/TVSeriesCategoriesTests) aynı klasörde series-cats.m3u ister
# (kopyası: UITests/Fixtures/series-cats.m3u; yoksa test XCTSkip ile atlanır).
# VLCKit / VOD / oynatıcı kontrol testleri Range destekli ikinci sunucu ister (MKV, MP4, TS…, port 8766:
# vlc-live.m3u, vlc-movie.m3u, vod-movie.m3u); yoksa bu testler XCTSkip ile atlanır.
# 2) Ortam değişkenleri TEST_RUNNER_ önekiyle test sürecine geçer
TEST_RUNNER_SEED_M3U=http://localhost:8765/test.m3u \
TEST_RUNNER_SCREENSHOT_DIR=/tmp/screens \
xcodebuild test -project NovaPlayer.xcodeproj -scheme NovaPlayer-iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

İsteğe bağlı: imzalı token'lı yerel backend (paywall'da "sunucuya ulaşılamıyor" bandı olmadan,
tvOS QR eşleştirme ekranı için gerekli):

```sh
cd backend
node scripts/keygen.mjs --kid dev-apple --keys-dir /tmp/devkeys           # özel anahtar depo DIŞINDA
npx wrangler d1 migrations apply iptv-backend --local --persist-to /tmp/wstate
npx wrangler dev --port 8798 --persist-to /tmp/wstate --var DEV_MODE:true --var LICENSE_KID:dev-apple \
  --var PUBLIC_BASE_URL:http://localhost:8798 --var "LICENSE_SIGNING_KEY:$(cat /tmp/devkeys/license-private.pem)"
# Testlere: TEST_RUNNER_DEV_BACKEND_URL=http://localhost:8798
#           TEST_RUNNER_DEV_LICENSE_KEYS=<license-public.json'ın base64url hali>
```

### Debug başlatma argümanları (yalnızca DEBUG derlemesi)

| Argüman | Etki |
|---|---|
| `-uiTestReset` | Bellek içi veritabanı + bellek içi gizli depo + ayrı UserDefaults (her açılış temiz) |
| `-seedM3U <url>` [`-seedName <ad>`] | Açılışta bir M3U kaynağı ekler |
| `-perfOverlay` | Performans katmanını açar (Ayarlar → Gelişmiş ve tanılama → Performans katmanı ile aynı) |
| `-pref.quickStart NO` | Hızlı başlat'ı bu açılış için kapatır (eski oturum oynatıcıyı açmasın) |
| `-uiTrial` | StoreKit denemesi 2 gün önce başlamış gibi davranır (oynatma açık) |
| `-uiScreen <ad>` | `paywall`, `player`, `live`, `movies`, `settings`, `addSource`, `addXtream`, `pairing`, `menu` |
| `-backendURL <url>` | `BACKEND_BASE_URL` yerine (ör. `http://localhost:8798`) |
| `-debugLicenseKeys <base64url>` | Gömülü anahtarlara ek, yerel dev `kid` (depoya girmez) |

Simülatörde elle çalıştırma:

```sh
xcrun simctl boot "iPhone 17 Pro"
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/NovaPlayer.app
xcrun simctl launch booted com.hasielektronic.novaplayer -uiTestReset -seedM3U http://localhost:8765/test.m3u -uiTrial -uiScreen live
xcrun simctl io booted screenshot live.png
```

## StoreKit testi

* **Xcode'dan (önerilen):** şemaların *Run* eyleminde `Config/Products.storekit` seçilidir →
  Xcode'da ▶︎ ile çalıştırınca ürünler yerel yapılandırmadan gelir (fiyat 9,99 / deneme 0).
  *Debug → StoreKit → Manage Transactions* ile satın alma, **Ask to Buy** (bekleyen işlem) onayı/reddi,
  **iade** (refund → `revocationDate` → erişim düşer) ve hata simülasyonu yapılabilir.
* **`AppTests/iOS/StoreKitFlowTests`** (`SKTestSession`): deneme "satın alma" → `TRIAL_ACTIVE`,
  lifetime satın alma → `PURCHASED`, iade → deneme durumuna dönüş, Ask to Buy → `pending` → onay,
  satın alma hatası. Bu testler **Xcode'dan** (*Product › Test*) çalıştırılmalıdır. Komut satırı
  `xcodebuild test` ile simülatörde storekitd yapılandırmayı reddeder
  (`not entitled for OctaneSaveConfigurationRequest`), ürünler yüklenmez → testler **atlanır**
  (`XCTSkip`), başarısız sayılmaz.
* `simctl launch` ile başlatılan uygulama yerel StoreKit yapılandırmasını kullanmaz; paywall'da fiyat
  "…" görünür (gerçek fiyat App Store / sandbox'tan gelir).
* Sandbox: App Store Connect'te ürünler (`STORE_SETUP.md §3`) ve sandbox test hesabı gerekir.

## Yapılandırma

| Ne | Nerede |
|---|---|
| Uygulama adı, bundle id, ürün id'leri, backend URL | `Config/Shared.xcconfig` (backend `wrangler.toml` ile aynı ürün id'leri) |
| Yerel geçersiz kılma (ör. dev backend) | `Config/Local.xcconfig` (git dışı): `BACKEND_BASE_URL = http:/$()/localhost:8798` |
| Lisans açık anahtarları | `Config/license-keys.json` |
| Arayüz metinleri | `spec/strings.json` + `spec/strings.apple.json` → `node spec/tools/gen-strings.mjs` (EN/TR/DE; `CFBundleLocalizations` en, tr, de) |
| Uygulama dili | Ayarlar → Görünüm & dil: Sistem / Deutsch / Türkçe / English (`AppSettings.appLanguage`, `L10n.setLanguage` → kök görünüm `.id` ile anında yeniden çizilir; `AppleLanguages` da yazılır) |
| ATS | Info.plist `NSAllowsArbitraryLoads = YES` (kullanıcının HTTP IPTV sunucuları, V17) |

> ⚠️ **`Config/license-keys.json` şu an yalnızca test anahtarını (`test-1`, `spec/test-vectors/license-token.json`)
> içerir.** Üretimden önce `cd backend && node scripts/keygen.mjs --write-clients --replace` çalıştırın
> (gerçek `kid` yazılır, özel anahtar `backend/.keys/` altında git dışı kalır) ve test anahtarını
> kaldırın; aksi halde test anahtarıyla imzalanmış token'lar kabul edilir.

## Doğrulanamayanlar / açık konular

* App Store Connect ürünleri, sandbox test hesapları, App Store Server API ile gerçek işlem doğrulaması
  (backend'de) ve ASSN v2 bildirimleri – mağaza erişimi gerekir.
* Gerçek cihaz (iPhone/Apple TV) – yalnızca simülatörde çalıştırıldı; tvOS katmanlı ikon ve Top Shelf
  görseli henüz yok (mağaza için gerekli).
* Gerçek IPTV sağlayıcıları (Xtream paneli, büyük listeler) – birim testleri sahte transport ile;
  simülatörde yerel M3U + Apple/Mux genel HLS yayınları kullanıldı.
* StoreKit akış testleri yalnızca Xcode IDE'den (yukarıya bakın).

## IPTVCore

Swift 6 dil modu (strict concurrency), `swift-tools-version:6.0`, iOS 17 / tvOS 17 / macOS 14.
Linux'ta da derlenecek şekilde yazıldı (CryptoKit yerine `swift-crypto`, `FoundationNetworking`);
Linux derlemesi bu turda ayrıca doğrulanmadı.

```
IPTVCore/
├── Package.swift
├── Sources/
│   ├── CZlib/               Sistem zlib'i için ince C köprüsü (inflateInit2/deflateInit2 makroları)
│   └── IPTVCore/
│       ├── Models/          Source, SourceSecrets, Channel, Movie, Series, Episode, EpgProgram …
│       ├── Errors/          SourceError / PlaybackError (CONTRACT §2) + ErrorPresentation (string anahtarları)
│       ├── Util/            URL normalizasyonu, yüzde kodlama, SHA-256/hex/base64url, içerik anahtarları,
│       │                    cihaz anahtarı, kanal adı normalizasyonu, log redaksiyonu
│       ├── M3U/             Akışlı M3U ayrıştırıcı (bayt düzeyinde, ≤ 1000'lik paketler) + katalog eşleme
│       ├── XMLTV/           XMLParser tabanlı akışlı XMLTV ayrıştırıcı, zaman ayrıştırma, gzip
│       ├── EPG/             Kanal eşleştirme, saklama penceresi, şimdi/sonraki, catch-up, saat biçimleme
│       ├── Xtream/          Hoşgörülü JSON, eşleme, hesap sınıflandırma, URL üretimi, async istemci
│       ├── Media/           Kapsayıcı tespiti (şema → bayt → content-type → uzantı) + destek matrisi
│       ├── Licensing/       ES256 lisans token doğrulama (CryptoKit), güvenilir saat, erişim politikası
│       ├── Pairing/         TV eşleştirme şifrelemesi (ECDH P-256 + HKDF-SHA256 + AES-256-GCM)
│       ├── Sync/            Senkron öğeleri, LWW birleştirme, "izlemeye devam et"
│       └── Networking/      HTTPTransport + URLSessionTransport, RetryPolicy (2 s/4 s),
│                            M3U/XMLTV yükleyicileri, ReconnectPolicy (1-2-4-8-15 s),
│                            BackendClient (BACKEND_API.md uç noktaları) + modeller
└── Tests/IPTVCoreTests/     XCTest paketleri (aşağıda)
```

### Derleme ve test

```sh
cd apple/IPTVCore
swift build
swift test                       # tüm testler (macOS)
swift test --filter XtreamVectorTests

# iOS ve tvOS Simulator için derleme
xcodebuild -scheme IPTVCore -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme IPTVCore -destination 'generic/platform=tvOS Simulator' build
```

Gereksinim: Xcode 16+ (Swift 6). İlk derlemede SwiftPM `swift-crypto` paketini çözer; bu
bağımlılık yalnızca Linux'ta bağlanır, Apple platformlarında CryptoKit kullanılır.

### Testler

Vektör dosyaları test dosyasının klasörüne göre `../../../../spec/test-vectors` yolundan
okunur (`Tests/IPTVCoreTests/VectorSupport.swift`, `#filePath`). Beklenen JSON ile karşılaştırma
Kotlin'deki `assertJsonEquals` ile aynı kurallara uyar (sayılar sayısal, `_` ile başlayan
anahtarlar yok sayılır).

| Test paketi | Kapsam |
|---|---|
| `M3UVectorTests` | `m3u/*` (farklı paket ve parça boyutlarıyla), tüm sürücüler (Data, dosya, async parça/bayt/satır), başlık bölme, sınıflandırma, katalog eşleme, uzun satır kırpma |
| `XMLTVVectorTests` | `xmltv/time-parsing.json`, `name-normalization.json`, `epg_basic` (düz + gzip, tüm diller/kaydırmalar), saklama penceresi, bozuk/HTML belgeler, eşleştirme, gzip |
| `MediaVectorTests` | `media/expected.json` (gerçek dosyalar, URL/content-type, destek matrisi), `stream-samples.json` tutarlılığı |
| `XtreamVectorTests` | `xtream/*` (tüm dosyalar), `auth.expected.json` hesap sınıflandırması, `url-vectors.json` (normalizasyon, URL'ler, canlı uzantı), sahte transport ile tam yenileme |
| `LicensingVectorTests` | `license-token.json` (ES256), `trusted-clock.json`, `access-policy.json` |
| `PairCryptoVectorTests` | `pair-crypto.json` (ortak sır, HKDF anahtarı, çözme, sabit iv ile şifreleme), kurcalama |
| `UtilVectorTests` | `content-keys.json` (parmak izi, içerik ve cihaz anahtarları), `redaction.json` |
| `TransportTests` | Sahte `URLProtocol` ile `URLSessionTransport`: 4xx/5xx eşleme, yeniden deneme (2 s, 4 s), JSON yerine HTML, ağ hataları, toplam süre aşımı, iptal, akışlı M3U, gzip EPG |
| `BackendClientTests` | Her uygulama uç noktası: istek biçimi, yanıt çözme, `{error, message}` eşleme, 422/503'te token, cihaz-kodu ve eşleştirme akışları |
| `PolicyTests` | ReconnectPolicy, EPG şimdi/sonraki, catch-up, LWW senkron, izleme geçmişi, hata metni anahtarlarının `spec/strings.json`'da varlığı |
| `M3UPerformanceTests` | Bellekte parça parça üretilen 200 000 girişlik listenin akışlı ayrıştırılması + eşlemesi (debug'da ~4 s, sınır 30 s) |

### Notlar

* **CZlib:** Apple SDK'larında ve Linux'ta sistem `libz` hazır; zlib'in başlatma fonksiyonları
  makro olduğu için Swift'ten doğrudan çağrılamaz, bu yüzden iki satırlık C köprüsü tutuldu.
  `Compression` framework'ü gzip başlığını ve çok parçalı gzip'i işlemediği ve Linux'ta
  bulunmadığı için tercih edilmedi.
* **Zaman aşımları:** URLSession'da ayrı bir bağlantı zaman aşımı yoktur; `read` (boşta kalma)
  ve `total` (tüm çağrı) uygulanır, `connect` değeri gerçek bağlantı zaman aşımı olan
  transport'lar içindir.
* **Gizlilik:** Xtream yayın URL'leri kimlik bilgisi içerdiği için saklanmaz; her log satırı
  `Redactor` üzerinden geçmelidir. Backend yalnızca eşleştirme şifreli metnini görür.
