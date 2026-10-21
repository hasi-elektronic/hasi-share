# Güvenlik ve Veri Koruma

## 1. Ne nerede saklanır?

| Veri | Android | iOS / tvOS | Backend |
|---|---|---|---|
| M3U URL, Xtream sunucu/kullanıcı/şifre, EPG URL | Android Keystore'daki AES-256-GCM anahtarıyla şifreli kayıt (anahtar cihazdan çıkamaz) | Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. **iCloud eşitleme açıkken (Build 17):** iCloud Anahtar Zinciri öğesi (`kSecAttrSynchronizable`, `kSecAttrAccessibleAfterFirstUnlock`; Apple'ın uçtan uca şifrelemesiyle yalnızca kullanıcının kendi cihazlarına gider) | **Hiç** (yalnızca eşleştirmede okunamaz şifreli metin, ≤10 dk) |
| iCloud eşitleme (Apple, Build 17): kaynak tanımları (**gizli bilgi yok**), favoriler, en yeni 300 izleme ilerlemesi, kategori sabitleme/gizleme/ülke, favori sırası, gizli canlı kanallar | – | Kullanıcının kendi iCloud'u: `NSUbiquitousKeyValueStore` (3 anahtar, < 900 KB, ARCHITECTURE §6.1). Ses gecikmeleri, seçili kaynak, son aramalar eşitlenmez | **Hiç** – geliştirici bu verilere erişemez (App Store anlamında "toplanan veri" değildir, PrivacyInfo değişmedi) |
| Kanal/film/dizi listeleri, EPG | Uygulamaya özel Room DB | Uygulama konteynerinde SQLite, `NSFileProtectionCompleteUntilFirstUserAuthentication`, iCloud yedeğinden hariç | Hiç |
| M3U kanal URL'leri (içerik) | Room DB (yedekten hariç) | SQLite (yedekten hariç) | Hiç |
| Xtream yayın URL'leri | **Saklanmaz** – oynatma anında oluşturulur | Saklanmaz | Hiç |
| Lisans token'ı, güvenilir saat durumu | DataStore (imzalı token, değiştirilirse geçersiz) | UserDefaults (aynı) | İmzalayan |
| Oturum token'ı (hesap) | Keystore-şifreli | Keychain | Yalnızca SHA-256 özeti |
| Cihaz kimliği | Gönderilmez; yalnızca `sha256(prefix|appId|ANDROID_ID)` | `sha256(prefix|bundleId|IDFV)` | `deviceKey` |
| E-posta (opsiyonel hesap) | – | – | D1, hesap silinince silinir |
| Dayanıklı ayna (Apple, Build 14): kaynak tanımları (ad, tür, host, ayarlar – **gizli bilgi yok**), seçili kaynak, favoriler/ilerleme (başlık, poster URL'si, içerik anahtarı), son aramalar, senkron imleçleri | – | `UserDefaults` (`durable.sources.v1`, `durable.userState.v1`, toplam ≤ 200 KB) – tvOS katalog veritabanını silebildiği için (ARCHITECTURE §3.3). iOS'ta UserDefaults cihaz yedeğine dahildir | Hiç |

**Yedekleme:** Android `dataExtractionRules` / `fullBackupContent` veritabanını, şifreli
kayıtları ve DataStore'u buluta yedeklemeden ve cihaz aktarımından hariç tutar (Keystore
anahtarı zaten taşınamaz). iOS'ta veritabanı dosyası `isExcludedFromBackup`, Keychain öğesi
`ThisDeviceOnly`. **İstisna (Build 14):** dayanıklı ayna `UserDefaults`'ta durduğu için iOS cihaz yedeğine
girer; içinde gizli bilgi yoktur (M3U/Xtream URL'si, kullanıcı adı, şifre yalnızca Keychain'de), ancak kaynak
adları/hostları, favori/izleme başlıkları ve son 10 arama yer alır. Apple TV uygulama verisini iCloud'a yedeklemez.
**Build 17 – iCloud eşitleme (Ayarlar → iCloud, iCloud hesabı varsa varsayılan açık):** açıkken kaynak gizli
bilgileri `ThisDeviceOnly` değil, iCloud Anahtar Zinciri öğesidir (eşitlenebilir öğeler cihaza bağlanamaz; şifreli
cihaz yedeğine de girer). Kapatınca cihaza özel kopya geri yazılır; iCloud kopyası kullanıcının diğer cihazları için
kalır (her yerden kaldırmak için: eşitleme açıkken kaynağı silmek – iCloud kopyası da silinir).
Anahtar-değer deposuna gizli bilgi yazılmaz (birim testi `testAudioDelaysAndSelectedSourceStayOnTheDevice` M3U
URL'lerinin depoda olmadığını kontrol eder); kaynak kaydında yalnızca parmak izi (host + kullanıcı adının SHA-256
öneki, zaten eşitlenen içerik anahtarlarında bulunan değer) vardır.

## 2. Loglar
* Tüm log çağrıları `SafeLog` → `Redactor` (CONTRACT §10) üzerinden geçer: kayıtlı gizli
  değerler, `password=`/`token=` vb. sorgu parametreleri, `user:pass@` URL kullanıcı bilgisi,
  Xtream yolundaki `/live/<u>/<p>/` kimlik bilgileri, `Bearer` token'ları maskelenir.
* Release derlemelerinde DEBUG/INFO logları kaldırılır (Android R8
  `-assumenosideeffects`, Apple `os.Logger` + `privacy: .private`). Çökme raporlayıcısı yoktur;
  eklenirse aynı redaksiyon zorunludur.
* Backend logları da `redact()`'tan geçer; e-posta maskeli (`a***@d***.com`), satın alma
  token'ları ve şifreli eşleştirme verisi loglanmaz.
* Oynatıcı hata mesajları kullanıcıya gösterilirken URL içermez.

## 3. Ağ
* IPTV kaynakları çoğunlukla HTTP'dir → Android `network_security_config` cleartext'e izin verir,
  iOS ATS `NSAllowsArbitraryLoads` (mağaza incelemesi için gerekçe: kullanıcının kendi eklediği
  rastgele IPTV sunucuları). **Backend her zaman HTTPS.**
* Tüm istekler iptal edilebilir; bağlantı/okuma/toplam zaman aşımları CONTRACT §2'de.
* Xtream şifresi zorunlu olarak URL sorgu parametresi/yol parçası olarak sunucuya gider
  (protokolün doğası); bu yüzden yalnızca kullanıcının girdiği sunucuya gönderilir, başka
  hiçbir yere gönderilmez.

## 4. Lisans ve deneme bütünlüğü (tehdit modeli)

| Tehdit | Önlem | Kalan risk |
|---|---|---|
| Cihaz saatini geri almak | `TrustedClock`: sunucu zamanı + monoton saat; yeniden başlatmada cihaz saati son sunucu zamanının gerisine düşemez | Uzun süre çevrimdışı + saat dondurma (IPTV internet gerektirdiği için pratik değil) |
| Uygulamayı silip yeniden kurmak | Android: `ANDROID_ID` türevi deviceKey yeniden kurulumda aynı; Apple: deneme Apple ID'ye bağlı ücretsiz IAP | Android fabrika ayarı / farklı kullanıcı profili → yeni deneme (Play Integrity ileride) |
| Lisans token'ını değiştirmek | ES256 imza, gömülü açık anahtar, `iss`/`aud` kontrolü | – |
| Eski "satın alındı" token'ını saklamak (iade sonrası) | Mağaza kütüphanesi iade edilen ürünü döndürmez; aynı mağazada `revoked` + token `src` eşleşirse yok sayılır | Backend'i engelleyen ve başka platformdan hesap lisansı olan kullanıcı |
| Sahte satın alma (root / Lucky Patcher vb.) | Play Billing imzası + backend `purchases.products.get` doğrulaması; StoreKit 2 JWS doğrulaması + App Store Server API | İstemci tarafı yamalanmış APK (her yerel kontrol aşılabilir) |
| Backend'e sahte webhook | Google: paylaşılan sır + Google'a yeniden sorgu; Apple: bildirimdeki işlem Apple'dan yeniden çekilir | – |
| Admin uçları | `ADMIN_TOKEN` (≥32 karakter, sabit zamanlı karşılaştırma), Cloudflare Access ile ek koruma önerilir | Token sızıntısı |
| Kaba kuvvet (e-posta kodu, eşleştirme kodu) | 5 deneme, oran sınırlama, 10 dk TTL, 31^6 ≈ 887 M kod uzayı | – |

## 5. TV eşleştirme (uçtan uca şifreleme)
TV geçici P-256 anahtar çifti üretir; telefon tarayıcısı ECDH + HKDF-SHA256 + AES-256-GCM ile
şifreler (CONTRACT §9). Backend yalnızca şifreli metni 10 dakikaya kadar tutar ve TV aldıktan
sonra siler. Özel anahtar TV belleğinden hiç çıkmaz.

## 6. GDPR / gizlilik
* Veri minimizasyonu: hesapsız kullanımda backend yalnızca `deviceKey`, platform, uygulama
  sürümü, deneme zamanları ve mağaza satın alma referanslarını tutar.
* Hesap silme uygulama içinden (`DELETE /v1/account`): hesap, oturumlar, senkron verisi silinir;
  mağaza satın alma kayıtları kişisel veri olmadan (iade muhasebesi için) kalır.
* Gizlilik politikası ve Impressum URL'leri mağaza kayıtlarında ve Ayarlar'da gösterilmeli
  (harici: hukuki metinler hazırlanmalı).
* Google Play "Data safety" ve Apple "App Privacy" formları için beyan tablosu: `STORE_SETUP.md §5`.

## 7. Üçüncü taraf bileşenler ve lisanslar (Apple: VLCKit)
* **VLCKit 3.7.3** (MobileVLCKit / TVVLCKit, VideoLAN) – **LGPL-2.1-or-later** (libVLC ve
  eklentileri; bazı bağımlılıklar LGPL/BSD/MIT). Kaynak: `code.videolan.org/videolan/VLCKit`,
  ikili: `download.videolan.org/pub/cocoapods/prod/` (resmî CocoaPods/Carthage dağıtımı).
  `apple/scripts/fetch-vlckit.sh` sürümü ve SHA-256'yı sabitler; ikili depoya girmez.
* LGPL koşulları için yapılanlar: framework **dinamik** bağlanır ve uygulama paketinde ayrı
  `Frameworks/MobileVLCKit.framework` / `TVVLCKit.framework` olarak durur (kullanıcı/üçüncü taraf
  kütüphaneyi değiştirip yeniden bağlayabilir); VLCKit kodu değiştirilmez; kullanılan sürüm ve
  kaynak adresi burada ve `apple/README.md`'de belgelidir.
* **Yapılması gereken (yayından önce):** Ayarlar'daki "Açık kaynak lisansları" satırı şu an
  yalnızca bir etikettir; bir lisans ekranı eklenmeli ve en az şu metni içermelidir:
  *"Bu uygulama VLCKit/libVLC (© VideoLAN ve VLC yazarları) kullanır; GNU LGPL sürüm 2.1
  altında lisanslıdır. Kaynak kodu: https://code.videolan.org/videolan/VLCKit"* + LGPL-2.1 tam
  metni (`apple/Vendor/VLCKit/COPYING.txt`, fetch betiği kopyalar).
* App Store: LGPL-2.1 dinamik framework ile App Store dağıtımı VideoLAN'ın kendi "VLC for iOS"
  uygulamasıyla aynı modeldir; ek DRM/kısıtlama getirilmez.
* Güvenlik: libVLC güvenilmeyen ağ içeriğini ayrıştırır (demuxer/codec) → VideoLAN güvenlik
  bültenleri izlenmeli, VLCKit düzenli güncellenmeli (`VERSION`/`BUILD`/SHA-256 betikte).
