# Ekran Akışları ve Etkileşim Tasarımı

Bu doküman hem mobil (Android / iOS) hem TV (Android TV / Apple TV) arayüzleri için
**normatif** tasarım spesifikasyonudur. Metin anahtarları `spec/strings.json` içindedir
(tek kaynak; Android `strings.xml` ve Apple `Localizable.xcstrings` buradan üretilir).

## 1. Görsel dil

| Token | Değer | Not |
|---|---|---|
| `bg` | `#0B0D12` | Ana arka plan (neredeyse siyah, hafif mavi) |
| `surface` | `#151922` | Kart / liste satırı |
| `surfaceElevated` | `#1E2430` | Sheet, dialog, odaklı kart zemini |
| `primary` | `#5B8CFF` | Vurgu (odak halkası, seçili sekme, ilerleme çubuğu) |
| `primaryVariant` | `#7C5CFF` | Gradyan ikinci rengi (premium rozeti, paywall) |
| `textPrimary` | `#F2F4F8` | |
| `textSecondary` | `#A3ACBD` | |
| `live` | `#FF4D5E` | "CANLI" rozeti, EPG şimdiki zaman çizgisi |
| `success` / `warning` / `error` | `#2BD47D` / `#FFB547` / `#FF5C5C` | |

* Tipografi: sistem fontu (Roboto / SF Pro). Mobil gövde 15–16 sp/pt.
  TV gövde **≥ 18 sp**, başlıklar ≥ 28 sp, 3 m mesafeden okunur. TV kenar boşluğu
  (overscan-safe) yatay 48 dp / dikey 27 dp.
* Köşe yarıçapı: kart 12, poster 10, buton 24 (pill).
* Posterler 2:3, kanal logoları 16:9 içinde `fit`, arka plan `surface`.
* Hareket: 150–200 ms; TV'de odaklanan kart 1.08× büyür + 3 dp `primary` halka + gölge.
* Yalnızca koyu tema (sistem açık temada da koyu kalır – içerik odaklı tasarım).

## 2. Navigasyon

### Mobil
Alt gezinme (5 sekme): **Ana Sayfa · Canlı TV · Filmler · Diziler · Favoriler**.
Üst çubukta: arama (🔍) ve ayarlar (⚙️). Kaynak yoksa sekmeler yerine Karşılama ekranı.
Film/Dizi sekmesi, kaynak bunları sunmuyorsa gizlenmez; "Bu kaynakta film yok" boş durumu gösterir.
Dikey ve yatay desteklenir; yatayda grid sütun sayısı artar (poster min. genişlik 110 dp).

### TV
Solda daraltılabilir gezinme menüsü (ikon + metin): **Ara · Ana Sayfa · Canlı TV ·
Filmler · Diziler · Favoriler · Ayarlar**. Menü odak alınca genişler.

**Geri tuşu kuralları (TV, öngörülebilir):**
1. Oynatıcıda: açık panel/menü varsa kapatır → yoksa oynatıcıdan çıkar (önceki ekrana, odak
   oynatılan öğede).
2. Detay ekranında: bir önceki ekrana döner, odak açılan öğeye geri gelir.
3. Bir bölümün içeriğinde (liste/grid): odağı sol menüye taşır.
4. Sol menüdeyken: Ana Sayfa değilse Ana Sayfa'ya gider; Ana Sayfa'da uygulamadan çıkar.
5. Diyaloglar her zaman geri tuşuyla kapanır (iptal anlamında).

**Odak kuralları:** Her ekranın varsayılan odak öğesi tanımlıdır (aşağıda ★). Satırlar arası
dikey geçişte odak, satırdaki son odaklanan öğeye döner (focus restorer). Liste yeniden
yüklendiğinde odak kaybolmaz (aynı id'ye geri yerleşir). Kenarlarda odak "kaçmaz"
(wrap yok, menüye sadece sola basınca geçer).

## 3. Ekranlar

### 3.1 Karşılama ve kaynak ekleme
* Logo + "{app} – IPTV oynatıcı" + yasal not: *"Uygulama içerik sağlamaz; yalnızca size ait
  M3U / Xtream kaynaklarını oynatır."*
* Deneme bilgisi kartı (ilk açılış): süre, deneme sonunda kilitlenecekler (oynatma),
  tek seferlik fiyat (mağazadan alınan yerel fiyat) → **★ Ücretsiz denemeyi başlat** /
  "Satın al" / "Satın alımları geri yükle".
* Kaynak ekleme seçenekleri: **M3U bağlantısı** · **Xtream Codes** · (TV'de ★) **Telefonla ekle (QR)**.
  * M3U formu: Ad, URL, (isteğe bağlı) EPG URL, gelişmiş: User-Agent.
  * Xtream formu: Ad, Sunucu (`http://host:port`), Kullanıcı adı, Şifre (göster/gizle).
  * "Bağlan" → ilerleme (adım adım: *Bağlanılıyor → Hesap doğrulanıyor → Kanallar yükleniyor (12 430)
    → EPG yükleniyor*) → başarı ekranında özet (kanal / film / dizi sayıları, hesap bitiş tarihi).
  * Hatalar ayrı ayrı (bkz. §4). Kaydet butonu yalnızca form geçerliyken aktif.
* TV QR akışı: büyük QR + kısa kod (`ABC-123`) + `{BASE}/pair` adresi + geri sayım (10 dk).
  Telefon formu doldurup gönderince TV otomatik "Kaynak alındı – bağlanılıyor…" ekranına geçer.
  Süre dolarsa "Yeni kod al".

### 3.2 Ana sayfa
Yatay satırlar (TV'de satır başlığı + kart rafı, mobilde aynı):
1. **İzlemeye devam et** (film/bölüm, ilerleme çubuklu) ★
2. **Son izlenen kanallar** (logo + şu anki program)
3. **Favori kanallar**
4. **Yeni eklenen filmler** / **Yeni diziler** (kaynakta varsa, `added` sırasına göre)
Üstte kaynak seçici (birden fazla kaynak varsa) ve deneme durum çipi ("Deneme: 5 gün kaldı").

### 3.3 Canlı TV ve EPG
* **Mobil:** üstte kategori çipleri (Tümü, Favoriler, kategoriler…); liste satırı: numara, logo,
  ad, şimdiki program + ilerleme çubuğu, sıradaki program saati. Dokun → oynatıcı.
  Uzun bas → favori ekle/çıkar. Sağ üst "Rehber" → tam EPG ızgarası (yatay zaman ekseni,
  30 dk = 120 dp, "şimdi" çizgisi kırmızı).
* **TV:** 3 sütun: kategoriler | kanallar ★ | önizleme paneli (logo, şimdiki/sıradaki program,
  açıklama, mini oynatıcı 600 ms odak beklemesinden sonra opsiyonel – ayar). OK → tam ekran.
  Menü/uzun OK → favori. "Rehber" butonu → EPG ızgarası (D-pad ile programlar arası gezinme,
  geçmiş program + catch-up varsa "Baştan izle").
* Saatler cihaz saat diliminde (ayar ile değiştirilebilir), 24 saat biçimi TR, sistem biçimi EN.
* Büyük listeler: sayfalı (Paging / lazy), arama debounced 250 ms, FTS.

### 3.4 Filmler
Kategori çipleri/menü + poster grid. Sıralama: Eklenme · A-Z · Puan. Detay: arka plan
(poster blur), başlık, yıl, puan, süre, özet, **★ Oynat / Devam et (01:12:30)** · Baştan oynat ·
Favori.

### 3.5 Diziler ve bölüm detayları
Grid → Dizi detayı: kapak, özet, sezon seçici (çip / TV'de yatay sekme), bölüm listesi
(numara, başlık, süre, izlenme ilerlemesi, ✓ izlendi). ★ "Devam et S02E05" (son izlenen
bölüm; bitmişse sonraki). Bölüm bitince sonraki bölüm için 10 sn geri sayım kartı.

### 3.6 Favoriler
Sekmeler: Kanallar · Filmler · Diziler. Düzenle modu (mobil: sürükle sırala, kaldır; TV:
seçenek menüsünden "Kaldır"). Hesap varsa senkronize edilir (son senkron saati gösterilir).

### 3.7 Oynatıcı
* Tam ekran, sistem çubukları gizli, ekran açık kalır.
* Katman (3 sn sonra kaybolur): üstte kanal/başlık, solda kanal numarası; altta zaman çizgisi
  (VOD) veya program ilerlemesi (canlı), "CANLI" rozeti; sağda araçlar: Ses · Altyazı ·
  Görüntü oranı · (canlı) Kanal listesi · Favori.
* **Kanal değiştirme (canlı):** mobil yukarı/aşağı kaydır, TV D-pad ▲▼ / CH+/CH−. Basıldığı
  anda (< 100 ms) üstte büyük bilgi kartı: numara, logo, ad, şimdiki program; yükleme
  göstergesi kartın içinde. Ard arda basışlar 400 ms içinde birleştirilir (yalnızca son kanal
  açılır). TV'de rakam tuşları: 1,5 sn içinde girilen numaraya geçer. "Önceki kanal" (TV: geri
  değil, OK uzun basış menüsünde / mobil buton).
* **VOD:** ◀▶ 10 sn ileri/geri (basılı tutunca hızlanır), OK oynat/duraklat. Kaldığı yerden
  devam: açılışta otomatik devam + "Baştan başla" kısa düğmesi (5 sn görünür).
* **Görüntü oranı:** Sığdır · Doldur (kırp) · Uzat · 16:9 · 4:3 – seçim kanal başına değil,
  global hatırlanır.
* **Ses / altyazı:** dil adıyla listelenir (`Türkçe`, `English`, bilinmiyorsa `Parça 2`),
  altyazı "Kapalı" seçeneği; tercih edilen ses/altyazı dili ayarlardan otomatik uygulanır.
* **Bağlantı koparsa:** katmanda "Yeniden bağlanılıyor… (2/5)" + son kare donuk; 1-2-4-8-15 sn
  aralıklarla 5 deneme, ardından hata kartı (Tekrar dene ★ / Kanal listesi / Geri).
  Canlıda "canlı pencerenin gerisinde" hatası sessizce canlı uca atlar.
* **Kilit:** deneme bittiyse oynatıcı açılmaz → Paywall (§3.8) açılır, geri tuşu listeye döner.
* Kaynaklar: ekran kapanınca / uygulama arka plana geçince oynatıcı **serbest bırakılır**
  (pozisyon kaydedilir). Arka planda ses oynatma yok (varsayım).

### 3.8 Deneme durumu ve satın alma (Paywall)
* Başlık: "{app} Premium – tek seferlik satın alma", madde listesi (sınırsız oynatma, tüm
  cihazlarda aynı mağaza hesabıyla, abonelik yok).
* Durum kartı: *Deneme aktif – 3 gün 4 saat kaldı* / *Deneme sona erdi* / *Satın alındı ✓* /
  *Ödeme bekleniyor* (bekleyen işlem: "Ödeme onaylandığında erişim otomatik açılır").
* **★ Satın al – ₺xx,xx** (mağaza yerel fiyatı) · **Satın alımları geri yükle** · Kullanım
  koşulları · Gizlilik.
* Hesap bölümü (isteğe bağlı): "Farklı platformda (Apple ↔ Google) satın aldıysanız hesabınıza
  giriş yapın".
* Satın alma sonuçları: başarı (konfeti yok, sade onay), iptal (sessiz), hata (mağaza mesajı),
  bekliyor (banner), zaten sahip (geri yükleme yapar).

### 3.9 Ayarlar ve kaynak yönetimi
* **Kaynaklar:** liste (ad, tür, host, son yenileme, durum rozeti, hesap bitiş tarihi) →
  detay: Yenile · Düzenle · EPG URL · EPG saat kaydırma (−12..+12 saat, 15 dk adım) ·
  Otomatik yenileme (Kapalı/6/12/24 saat) · Sil (onaylı). "+ Kaynak ekle".
* **Oynatma:** tercih edilen ses dili, altyazı dili, görüntü oranı varsayılanı, canlı yayın
  formatı (Android: Otomatik/TS/HLS), arabellek (Normal/Büyük), TV'de önizleme oynatıcısı.
* **Görünüm & dil:** Uygulama dili (Sistem/Türkçe/English), EPG saat dilimi (Cihaz/özel),
  24 saat biçimi.
* **Hesap (opsiyonel):** e-posta ile giriş (kod), TV'de "Telefonla giriş yap" (cihaz kodu + QR),
  senkronizasyon durumu, çıkış, **hesabı sil**.
* **Satın alma:** durum, geri yükle.
* **Gelişmiş/Tanılama:** Format testi (`stream-samples.json`), önbelleği temizle (görsel / EPG),
  uygulama sürümü, açık kaynak lisansları, gizlilik politikası.
* Kilitliyken bu ekran tamamen erişilebilir.

## 4. Hata ve boş durumlar (ayrı ayrı mesajlar)

| Durum | Başlık | Açıklama | Eylem |
|---|---|---|---|
| `Network(offline)` | İnternet bağlantısı yok | Bağlantınızı kontrol edin. | Tekrar dene |
| `Network(timeout/dns/refused/tls)` | Sunucuya ulaşılamıyor | Adres doğru mu? Sunucu yanıt vermiyor (zaman aşımı / DNS / bağlantı reddedildi / güvenli bağlantı hatası). | Tekrar dene · Düzenle |
| `InvalidCredentials` | Kullanıcı adı veya şifre hatalı | Sağlayıcınızın verdiği bilgileri kontrol edin. | Düzenle |
| `AccountExpired(date)` | Kaynak hesabınızın süresi dolmuş | {tarih} tarihinde sona erdi. Sağlayıcınızla iletişime geçin. | Düzenle · Kaynağı sil |
| `AccountDisabled` | Kaynak hesabı devre dışı | Sağlayıcı hesabı askıya almış. | Düzenle |
| `NotFound` | Liste bulunamadı (404) | URL'yi kontrol edin. | Düzenle |
| `ServerError(code)` | Sunucu hatası ({code}) | Daha sonra tekrar deneyin. | Tekrar dene |
| `InvalidFormat` | Geçersiz liste | Adres bir M3U listesi döndürmüyor. | Düzenle |
| `InvalidResponse` | Beklenmeyen yanıt | Sunucu Xtream API yanıtı vermiyor; adresi kontrol edin. | Düzenle |
| `Empty` | Liste boş | Kaynakta oynatılabilir içerik yok. | Yenile |
| Playback `UnsupportedFormat(c)` | Bu yayın biçimi desteklenmiyor | {c} biçimi bu cihazda oynatılamıyor. (Apple + TS: "Sağlayıcınızdan HLS/m3u8 çıkışını isteyin.") | Geri |
| Playback `UnsupportedCodec` | Video/ses kodeki desteklenmiyor | Cihaz bu kodeki çözemiyor. | Geri |
| Playback `AccessDenied` | Yayına erişim reddedildi | Bağlantı sınırı aşılmış veya hesap süresi dolmuş olabilir. | Tekrar dene |
| Playback `StreamOffline` | Yayın şu anda kapalı | Kanal yayında değil. | Tekrar dene · Kanal listesi |
| Playback `Drm` | Korumalı yayın | DRM korumalı yayınlar desteklenmiyor. | Geri |

## 5. Erişilebilirlik
* Tüm ikon butonlarda içerik açıklaması (TalkBack/VoiceOver).
* Dokunma hedefi ≥ 48 dp / 44 pt. Kontrast ≥ 4.5:1 (metin), odak halkası ≥ 3:1.
* Dinamik yazı boyutu (mobil) desteklenir; TV'de sabit büyük ölçek.
