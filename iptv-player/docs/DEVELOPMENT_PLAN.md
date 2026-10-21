# Geliştirme Planı

Aşamalar istenen sırayı izler. Her aşamanın çıktısı ve kabul kriteri aşağıdadır; güncel
durum için `docs/STATUS.md`.

| # | Aşama | Çıktılar | Kabul kriteri |
|---|---|---|---|
| 1 | Mimari, modeller, ekran akışları, klasör yapısı | `docs/ARCHITECTURE.md`, `spec/CONTRACT.md`, `spec/BACKEND_API.md`, `docs/SCREENS.md`, `spec/strings.json`, `spec/test-vectors/` | Üç kod tabanının uyacağı tek sözleşme + makinece doğrulanabilir vektörler |
| 2 | Bağlantı ve oynatma prototipi (iki aile) | Kotlin `core` + Swift `IPTVCore` (bağlantı, ayrıştırma, URL üretimi, format tespiti); Media3/AVPlayer `PlayerController` | Çekirdek testleri yeşil; cihazda bir HLS ve bir Xtream kanalı oynar |
| 3 | M3U, Xtream, EPG entegrasyonu | Akış ayrıştırıcılar, Xtream istemcisi, XMLTV, eşleme, veritabanına toplu yazım, yenileme | Vektörler + 200k liste performansı; hata türleri ayrı ayrı |
| 4 | Mobil ve TV arayüzleri | Android `app` (Compose M3 + Compose for TV), Apple `Apps/iOS` + `Apps/tvOS`, 9 ana ekran | SCREENS.md; TV'de tüm akışlar D-pad ile |
| 5 | Demo ve tek seferlik satın alma | Backend lisans uçları, Play Billing 8, StoreKit 2, `AccessPolicy`, `TrustedClock`, paywall | Deneme/satın alma/bekleyen/geri yükleme/iade senaryoları (backend testleri + cihaz B7–B8) |
| 6 | Favoriler, izleme geçmişi, senkron | Yerel favori/ilerleme, opsiyonel hesap (e-posta kodu, TV cihaz kodu), `/v1/sync` | LWW testleri; cihazlar arası devam et |
| 7 | Gerçek cihaz doğrulaması | `docs/TEST_PLAN.md` B bölümü, format testi ekranı | Kontrol listesi tamamlanır (cihaz gerektirir) |
| 8 | Mağaza yayını | `docs/STORE_SETUP.md`, StoreKit config, gizlilik manifesti, imzalama notları | Dahili test kanalı / TestFlight yüklemesi (hesap gerektirir) |

## Paralel iş akışı
Sözleşme sabitlendikten sonra backend, Android ve Apple çekirdekleri paralel geliştirildi;
platform veri/oynatıcı katmanı ve arayüzler çekirdek API'si üzerine kuruldu. Her davranış
değişikliği önce `spec/` içinde yapılır, sonra üç tarafta vektörlerle doğrulanır.

## Sonraki adımlar (ilk sürüm sonrası öneriler)
* Play Integrity / App Attest ile deneme kötüye kullanımına ek koruma.
* Apple'da VLCKit tabanlı ikinci oynatıcı (TS/MKV).
* PiP ve arka planda ses.
* Android TV "Watch Next" / Apple TV Top Shelf entegrasyonu.
* Kanal sıralamasını/gizlemeyi kullanıcıya açma, ebeveyn kilidi (PIN).
