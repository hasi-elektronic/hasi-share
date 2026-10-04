# Apple ailesi (iOS · iPadOS · tvOS)

Bu klasör Apple tarafının kodunu içerir. Davranış kuralları `spec/CONTRACT.md` ve
`spec/BACKEND_API.md` dosyalarındadır; Swift kodu Kotlin ve TypeScript ile **aynı test
vektörlerini** (`spec/test-vectors/`) geçmek zorundadır.

| Klasör | Durum | İçerik |
|---|---|---|
| `IPTVCore/` | ✅ `swift test`: 86 test yeşil | Platformdan bağımsız Swift Package: modeller, ayrıştırıcılar, ağ, lisans mantığı |
| `IPTVKit/` | ✅ `swift test`: 37 test yeşil | Apple'a özel paket: SQLite + FTS5, Keychain, StoreKit 2, lisans, hesap/senkron, eşleştirme, AVPlayer `PlayerController`, `@Observable` ViewModel'ler |
| `Shared/` | ✅ | Ortak SwiftUI ekranları (iOS + tvOS), tema, `L10n`, `Resources/Localizable.xcstrings` (üretilmiş) |
| `Apps/iOS`, `Apps/tvOS` | ✅ derleniyor, simülatörde çalıştı | Uygulama giriş noktaları: iPhone/iPad `TabView`, Apple TV sol menü |
| `Config/` | ✅ | `Shared.xcconfig` (ad, bundle id, ürünler, backend), `Products.storekit`, `PrivacyInfo.xcprivacy`, `license-keys.json`, entitlements |
| `AppTests/iOS` | ⚠️ yalnızca Xcode'dan | StoreKit akış testleri (`SKTestSession`) – komut satırında atlanır, aşağıya bakın |
| `UITests/` | ✅ iOS 4 + tvOS 4 UI testi yeşil | Ekran görüntüleri, Siri Remote ile odak gezinmesi, kilitli oynatma → paywall |
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
│   │   ├── Player/             PlayerController (AVPlayer), StreamResolver (format ön kontrolü), PlaybackErrorMapper
│   │   ├── ViewModels/         AddSource, LiveTV, Movies, Series(+Detail), Home, Favorites, Search, EpgGrid, Paywall, FormatTest
│   │   ├── Support/            SafeLog (Redactor), ImageLoader (URLCache 200 MB + NSCache, küçültülmüş çözümleme), AppSettings
│   │   └── AppEnvironment.swift  Manuel DI + uygulama durumu
│   └── Tests/IPTVKitTests/     macOS'ta `swift test`
├── Shared/
│   ├── Support/                Theme (SCREENS §1 token'ları), L10n, AppBootstrap (+ Router, debug kancaları)
│   ├── Views/                  Welcome/TrialCard, AddSource, Pairing (QR), Home, LiveTV + EPG ızgarası (+ TV 3 sütun),
│   │                           Movies/Series/Favorites/Search, Player (overlay), Paywall, Settings/Kaynak/Hesap/Format testi
│   └── Resources/Localizable.xcstrings   (node spec/tools/gen-strings.mjs – elle düzenleme yok)
├── Apps/iOS/                   NovaPlayerApp (TabView 5 sekme + arama/ayarlar), Assets (ikon)
├── Apps/tvOS/                  NovaPlayerTVApp (sol menü, odak kapsamı, Menü tuşu kuralları)
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
* **Oynatıcı:** tek `AVPlayer`; oynatmadan önce `StreamFormatDetector` + AVPlayer destek matrisi
  (MPEG-TS/MKV/DASH/RTMP… → anlaşılır hata, TS için "HLS isteyin"); uzantı belirsizse ilk 1 KiB
  okunur. Yeniden bağlanma `ReconnectPolicy` (1-2-4-8-15 sn), kanal değiştirme 400 ms debounce
  (bilgi kartı anında), `AVMediaSelectionGroup` ile ses/altyazı, `videoGravity` + 16:9/4:3 sabit
  çerçeve, `scenePhase != .active` olunca release + pozisyon kaydı.
* **tvOS geri tuşu:** içerikte → odak sol menüye; menüde (Ana Sayfa değilse) → Ana Sayfa; Ana
  Sayfa menüsünde → sistem (uygulamadan çıkış); alt sayfalarda `NavigationStack` kendisi geri gider;
  oynatıcıda önce panel/overlay kapanır, sonra oynatıcıdan çıkılır. İlk odak içerikte (★).

## Proje üretimi (XcodeGen)

`project.yml` tek doğruluk kaynağıdır; `NovaPlayer.xcodeproj` ve `Apps/*-Info.plist` **üretilir ve
git'e girmez** (`.gitignore`). Karar gerekçesi: proje dosyası birleştirme çakışması üretmez, iki
platform hedefi ve şemalar tek yerde tanımlıdır.

```sh
brew install xcodegen          # 2.46 ile doğrulandı
cd apple
xcodegen generate              # → NovaPlayer.xcodeproj
open NovaPlayer.xcodeproj      # Şemalar: NovaPlayer-iOS, NovaPlayer-tvOS
```

iOS ve tvOS hedefleri **aynı bundle id**'yi (`$(APP_BUNDLE_ID)`) kullanır → Universal Purchase.
Simülatör için imzalama ekibi gerekmez (ad-hoc, `CODE_SIGN_IDENTITY = -`). Cihaz için Xcode'da
ekip seçin veya `DEVELOPMENT_TEAM` ayarını komut satırından verin.

## Derleme ve test (komut satırı)

```sh
cd apple
# Paketler (macOS)
(cd IPTVCore && swift test)    # 86 test
(cd IPTVKit && swift test)     # 37 test: SQLite repo'ları (bellek içi), atomik yenileme, FTS5,
                               # LicenseManager geçişleri (sahte backend + ES256 imzalayıcı),
                               # SyncManager partileri/debounce/LWW, eşleştirme, hata eşleme, resolver

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
| Arayüz metinleri | `spec/strings.json` + `spec/strings.apple.json` → `node spec/tools/gen-strings.mjs` |
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
