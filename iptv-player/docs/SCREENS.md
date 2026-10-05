# Ekran Akışları ve Etkileşim Tasarımı

Bu doküman hem mobil (Android / iOS) hem TV (Android TV / Apple TV) arayüzleri için
**normatif** tasarım spesifikasyonudur. Metin anahtarları `spec/strings.json` içindedir
(tek kaynak; Android `strings.xml` ve Apple `Localizable.xcstrings` buradan üretilir).

## 1. Görsel dil

| Token | Değer | Not |
|---|---|---|
| `bg` | `#000000` | Ana arka plan (saf siyah; hero görselleri buna doğru kararır) |
| `surface` | `#16181D` | Kart / liste satırı / çip |
| `surfaceElevated` | `#24272F` | Sheet, dialog, yuvarlak ikon butonu, odaklı kart zemini |
| `stroke` | `#FFFFFF` %10 | Kart / çip ince kenarlığı |
| `primary` | `#5B8CFF` | Vurgu (odak halkası, seçili sekme alt çizgisi, ilerleme çubuğu, "Tümünü gör", "YENİ" rozeti) |
| `primaryVariant` | `#7C5CFF` | Gradyan ikinci rengi (premium rozeti, paywall) |
| `textPrimary` | `#F2F4F8` | |
| `textSecondary` | `#A3ACBD` | |
| `live` | `#FF4D5E` | "CANLI" rozeti, EPG şimdiki zaman çizgisi |
| `success` / `warning` / `error` | `#2BD47D` / `#FFB547` / `#FF5C5C` | |

* Tipografi: sistem fontu (Roboto / SF Pro). Mobil gövde 15–16 sp/pt.
  TV gövde **≥ 18 sp**, başlıklar ≥ 28 sp, 3 m mesafeden okunur. TV kenar boşluğu
  (overscan-safe) yatay 48 dp / dikey 27 dp.
* Köşe yarıçapı: kart 12 (TV 16), poster 10 (TV 14), buton pill. Yuvarlak ikon butonları daire.
* Posterler 2:3, "İzlemeye devam et" kartları 16:9 (poster `fill` + kırpma). Kanal logosu kare/16:9
  kutuda `fit`; logo zemini **kanal adından deterministik renk** (FNV-1a → 14 renklik palet), logo
  yoksa ad kısaltması (ör. "ABB").
* Ana birincil eylem ("▶ Oynat") hero üzerinde **beyaz pill, siyah metin**; detayda yuvarlak oynat
  butonu. Başlık satırı solda kalın başlık + sağda `primary` renkli "Tümünü gör".
* Hareket: 150–200 ms; TV'de odaklanan kart 1.08× büyür + 3 dp `primary` halka + gölge.
* Yalnızca koyu tema (sistem açık temada da koyu kalır – içerik odaklı tasarım).

## 2. Navigasyon

### Mobil (iPhone / iPad)
**Alt sekme çubuğu ve başlık açılır menüsü yok.** Üstte tek başlık şeridi: solda uygulama işareti,
ortada yatay kaydırılabilir **metin sekmeleri** **Ana Sayfa · Filmler · Diziler · Canlı TV · TV Rehberi**
(seçili = beyaz metin + `primary` alt çizgi, diğerleri gri), sağda 🔍 Ara ve ⚙️ Ayarlar ikonları.
Şerit hero üzerinde **şeffaf** durur, içerik kaydırılınca **siyaha** döner (hero'suz ekranlarda
hep siyah). Ara → genel arama ekranı (kanal + film + dizi). Ayarlar **sheet** olarak açılır (§3.9).
Favoriler ayrı sekme değildir: Ana Sayfa'da "Favoriler" satırı (+ "Tümünü gör" → Favoriler ekranı:
Kanallar · Filmler · Diziler segmenti), Filmler/Diziler'de "Favoriler" satırı, Canlı TV ve TV Rehberi'nde
kategori seçicinin ilk öğesi "Favoriler".
Kaynak yoksa Karşılama ekranı. Film/Dizi sekmesi, kaynak bunları sunmuyorsa gizlenmez; boş durum gösterir.
Dikey ve yatay desteklenir; grid sütun sayısı genişliğe göre artar (poster min. 104 pt).

### TV
Üstte yerel tvOS sekme çubuğu (Apple TV uygulaması gibi): **🔍 · Ana Sayfa · Filmler · Diziler ·
Canlı TV · TV Rehberi · ⚙️**. Sekmeye odaklanmak onu seçer; aşağı ok içeriğe iner (açılışta odak
sekme çubuğundadır – tvOS standardı; içeriğin ★ öğesi aşağı okla ilk ulaşılan öğedir). Canlı TV
kartlarında tek odak hedefi vardır (favori / arşiv uzun OK menüsünde).

**Geri tuşu kuralları (TV, öngörülebilir):**
1. Oynatıcıda: açık panel/menü varsa kapatır → yoksa oynatıcıdan çıkar (önceki ekrana, odak
   oynatılan öğede).
2. Detay ekranında: bir önceki ekrana döner, odak açılan öğeye geri gelir.
3. Bir bölümün içeriğinde (satır/grid/EPG): odağı üst sekme çubuğuna taşır.
4. Sekme çubuğundayken: Ana Sayfa değilse Ana Sayfa'ya geçer; Ana Sayfa'da uygulamadan çıkar.
5. Diyaloglar her zaman geri tuşuyla kapanır (iptal anlamında).

**Odak kuralları:** Her ekranın varsayılan odak öğesi tanımlıdır (aşağıda ★). Satırlar arası
dikey geçişte odak, satırdaki son odaklanan öğeye döner (focus restorer). Liste yeniden
yüklendiğinde odak kaybolmaz (aynı id'ye geri yerleşir). Kenarlarda odak "kaçmaz"
(wrap yok; sekme çubuğuna yalnızca yukarı basınca / geri tuşuyla geçer).

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

### 3.2 Ana sayfa, Filmler, Diziler (göz atma ekranları)
Üçü aynı iskeleti kullanır: **hero** + Netflix tarzı yatay satırlar. Her satır: başlık + sağda
"Tümünü gör" (anlamlı olduğu satırlarda → o satırın/kategorinin poster grid'i, sıralama menülü).
* **Hero** (iPhone'da ekran yüksekliğinin ~%55'i, TV'de ~640 pt): öne çıkan öğe = son "izlemeye devam"
  öğesi, yoksa en yeni film / dizi. Görsel `fill` (poster bulanık uzantı + net poster), alta doğru
  siyaha gradyan; büyük kalın başlık; "tür · yıl · süre" satırı; üç eylem: **☆ Favori** (ikon + etiket)
  · **beyaz pill "▶ Oynat"** (devam ediyorsa "Devam et (01:12:30)") ★ · **ⓘ Bilgi** (detay).
* **Ana Sayfa satırları:** İzlemeye devam et (16:9 kart, ortada oynat ikonu, başlık kartın altında
  görsel üstünde, kartın altında `primary` ilerleme çubuğu) · Favoriler (posterler) · Favori kanallar ·
  Yeni eklenen filmler · Yeni eklenen diziler · Canlı kanallar (kanal kartları).
* **Filmler / Diziler satırları:** İzlemeye devam et (yalnız o tür) · Favoriler · **Yeni eklenenler**
  (2:3 poster, altta küçük `primary` "YENİ" rozeti) · **Top 10** (posterin arkasında büyük, içi boş
  çerçeveli sıra numarası 1–10) · ardından kaynaktaki **her kategori için bir satır** (kategori adı,
  ülke adı/kodu içeriyorsa bayrak emojisi; ilk 12 kategori, satır başına 20 öğe).
* **"YENİ" kuralı:** `added` sırasına göre en yeni 20 öğe. **Top 10 kuralı:** kaynağın puanı
  (`rating`) azalan; puanı olan öğe yoksa en yeni eklenen 10 öğe. (Sunucuya izlenme verisi
  gönderilmez – sıralama tamamen yereldir.)
* Üstte deneme durum çipi ve (birden fazla kaynak varsa) kaynak seçici Ana Sayfa hero'sunun üstünde.

### 3.3 Canlı TV
* **Kanal kartı grid'i:** iPhone dikeyde 2 sütun, iPad 3–4, TV 4. Kart: renkli logo karosu + kanal
  adı + kalite rozeti (adındaki HD/FHD/4K/UHD/SD etiketinden), şimdiki programın saat aralığı + başlığı,
  ince `primary` ilerleme çubuğu, alt satırda küçük eylem ikonları: ☆ favori, ⟲ geçmiş yayın (yalnız
  kanal destekliyorsa → arşiv sheet'i §3.4). EPG yoksa "Program bilgisi yok".
* Üstte ortada **yüzen kategori çipi** ("🇹🇷 Türkiye ⌄") → menü: Tümü · Favoriler · kategoriler (bayraklı)
  · "Gizlenenleri göster (n)".
* Dokun / OK → oynatıcı. **Uzun bas** (iOS bağlam menüsü / TV uzun OK) → Favorilere ekle/çıkar ·
  **Kanalı gizle** · **Kategoriyi gizle**. Gizlenen kanal/kategori listeleri kaynak başına **yerel**
  saklanır (UserDefaults, senkronize edilmez); "Gizlenenleri göster" hepsini geri getirir.
* Büyük listeler: sayfalı (Paging / lazy), arama debounced 250 ms, FTS.

### 3.4 TV Rehberi (EPG)
* Kanal başına bir satır: solda sabit renkli logo karosu (genişliğin ~¼'ü), sağda yatay kaydırılan
  program blokları; **tüm satırlar aynı zaman eksenini paylaşır** (üstte "Bugün" + 30 dk işaretleri,
  "şimdi" ▼ işareti ve kırmızı `live` dikey çizgi). Şu an yayındaki blok kanal rengiyle vurgulu, geçen
  kısım koyu; bloklar karonun altına kayar, metin görünür kalır.
* Üstte kategori çipleri (Tümü · Favoriler · kategoriler).
* **iPad (geniş) ve TV:** sağda panel — **"Şimdi yayında"** (seçili/odaklı kanalın programı, saat, açıklama,
  "▶ Oynat") + **"Bugün"** sıradaki programlar listesi (saat + süre). iPhone'da panel yok.
* Dokun / OK → kanal oynar (iPad'de karoya dokunmak paneli o kanala getirir). TV'de D-pad ▲▼ kanallar,
  ◀▶ programlar arası. Uzun bas → favori / gizle menüsü.
* **Geçmiş yayın (catch-up) arşivi:** kanal destekliyorsa panelde/kartta ⟲ → sheet "TV arşivi ·
  Geçmiş yayınlar": gün başlıkları (bugün → arşiv gün sayısı), her satır saat + başlık + açıklama +
  "Tekrar izle". Tekrar izleme Xtream kaynaklarında `timeshift` URL'siyle (CONTRACT §4) yapılır;
  M3U `catchup-source` şablonları için yalnızca liste gösterilir (bilgi notu).
* Saatler cihaz saat diliminde (ayar ile değiştirilebilir), 24 saat biçimi TR, sistem biçimi EN.

### 3.5 Film ve dizi detayı
* Tam genişlikte hero görsel (iPhone ~%50 yükseklik, TV tam ekran arka plan), ortada büyük **yuvarlak
  ▶ oynat** butonu, sağ üstte **✕ kapat**. Altında büyük başlık; "★ 7.8 · 2024 · 1 sa 52 dk" (dizide
  sezon sayısı); kısa açıklama; "Tür: …" satırı; küçük eylem satırı: ☆ favori · ⟲ baştan oynat
  (devam varsa) · format pill ("MKV · HD"). Birincil eylem metni: "Oynat" / "Devam et (01:12:30)" /
  "Devam et S02E05".
* **Dizi:** sezonlar yatay **metin sekmeleri** ("Sezon 1 · Sezon 2 …", seçili `primary` alt çizgi);
  bölüm satırı = 16:9 küçük resim (ortada oynat ikonu, altta ilerleme) + "1. Başlık" + süre /
  izlendi ✓. ★ "Devam et S02E05" (son izlenen bölüm; bitmişse sonraki). Bölüm bitince sonraki bölüm
  için 10 sn geri sayım kartı. TV'de bölümler yatay 16:9 kart rafı.

### 3.6 Favoriler ve arama
* Favoriler ekranı (Ana Sayfa "Favoriler" satırı → "Tümünü gör"): segment Kanallar · Filmler ·
  Diziler; kanallar TV Rehberi satırlarıyla, filmler/diziler poster grid'i. Kaldırma: uzun bas menüsü.
  Hesap varsa senkronize edilir (son senkron saati gösterilir).
* Arama: tek alan, sonuçlar satır olarak (Kanallar kartları · Filmler · Diziler posterleri).

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
  (Diğer ekranlara referans: göz atma §3.2, Canlı TV §3.3, Rehber §3.4, detay §3.5.)
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
* **Gelişmiş/Tanılama:** Format testi (`stream-samples.json`; Apple'da her örneğin motoru –
  AVPlayer/VLCKit – gösterilir ve `expect.apple` ile karşılaştırılır), önbelleği temizle (görsel / EPG),
  uygulama sürümü, **Açık kaynak lisansları** ekranı (VLCKit LGPL-2.1 bildirimi + kaynak bağlantısı +
  tam metin, diğer bileşenler), gizlilik politikası.
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
