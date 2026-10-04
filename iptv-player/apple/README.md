# Apple ailesi (iOS · iPadOS · tvOS)

Bu klasör Apple tarafının kodunu içerir. Davranış kuralları `spec/CONTRACT.md` ve
`spec/BACKEND_API.md` dosyalarındadır; Swift kodu Kotlin ve TypeScript ile **aynı test
vektörlerini** (`spec/test-vectors/`) geçmek zorundadır.

| Klasör | Durum | İçerik |
|---|---|---|
| `IPTVCore/` | ✅ derleniyor, testler yeşil | Platformdan bağımsız Swift Package: modeller, ayrıştırıcılar, ağ, lisans mantığı |
| `Shared/Resources/` | üretilmiş | `Localizable.xcstrings` (`node spec/tools/gen-strings.mjs`, elle düzenleme yok) |
| `IPTVKit/` | ⏳ sırada | Apple'a özel paket: SQLite + FTS5, Keychain, StoreKit 2, AVPlayer `PlayerController`, ViewModel'ler |
| `Apps/iOS`, `Apps/tvOS`, `project.yml` | ⏳ sırada | SwiftUI uygulamaları (aynı bundle id → Universal Purchase), XcodeGen projesi |

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
