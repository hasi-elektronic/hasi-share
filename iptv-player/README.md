# NovaPlayer (yer tutucu ad) – Premium IPTV Oynatıcı

Android · Android TV · iOS · Apple TV için M3U ve Xtream Codes kaynaklarını oynatan,
7 günlük ücretsiz demo + tek seferlik satın alma modelli IPTV oynatıcı.
Uygulama içerik barındırmaz/sağlamaz; kullanıcı kendi kaynağını ekler.

> Bu klasör, `hasi-share` deposunun içinde bağımsız bir projedir. Kalıcı olarak ayrı bir
> depoya taşınması önerilir (`git subtree split -P iptv-player`).

## Klasör yapısı

```
iptv-player/
├── docs/                    Türkçe dokümantasyon
│   ├── ARCHITECTURE.md      mimari, kararlar, varsayımlar
│   ├── DEVELOPMENT_PLAN.md  aşamalar
│   ├── SCREENS.md           ekran akışları, TV odak/geri kuralları, hata mesajları
│   ├── SECURITY.md          depolama, loglar, tehdit modeli, GDPR
│   ├── STORE_SETUP.md       Play Console / App Store Connect / backend kurulumu, ortam değişkenleri
│   ├── STREAM_COMPATIBILITY.md  Media3 vs AVPlayer format matrisi
│   ├── TEST_PLAN.md         otomatik testler + cihaz kontrol listesi
│   └── STATUS.md            tamamlanan / test edilen / doğrulanamayan
├── spec/                    platformlar arası normatif sözleşme
│   ├── CONTRACT.md          modeller, ayrıştırma kuralları, lisans algoritmaları
│   ├── BACKEND_API.md       REST API
│   ├── strings.json         EN/TR/DE arayüz metinleri (tek kaynak)
│   ├── test-vectors/        Kotlin + Swift + TS testlerinin ortak vektörleri, gerçek medya örnekleri
│   └── tools/               vektör ve string üreticileri (Node)
├── backend/                 Cloudflare Worker + D1 (lisans, deneme, hesap, senkron, eşleştirme, admin)
├── android/                 Gradle: core (saf Kotlin) · shared (Android lib) · app (telefon + TV)
└── apple/                   IPTVCore (Swift Package) · IPTVKit · Apps/iOS · Apps/tvOS · XcodeGen
```

## Hızlı başlangıç

```sh
# Ortak araçlar
node spec/tools/gen-strings.mjs          # strings.json (EN/TR/DE) → Android strings.xml + Apple xcstrings
node spec/tools/gen-vectors.mjs          # (yalnızca vektörleri yeniden üretmek için)

# Backend
cd backend && npm i && npm test

# Android çekirdek (Google Maven gerekmez)
gradle -p android/core test              # veya android/ içinde ./gradlew -p core test
# Android uygulaması: android/ klasörünü Android Studio ile açın

# Apple çekirdek (macOS: swift test; Linux: Docker)
cd apple/IPTVCore && swift test
# Apple uygulamaları: cd apple && xcodegen generate && open NovaPlayer.xcodeproj
```

Mağaza ve backend kurulumu: [`docs/STORE_SETUP.md`](docs/STORE_SETUP.md).
Durum raporu: [`docs/STATUS.md`](docs/STATUS.md).
