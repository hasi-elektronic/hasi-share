# Ekran Akışları ve Etkileşim Tasarımı

Bu doküman hem mobil (Android / iOS) hem TV (Android TV / Apple TV) arayüzleri için
**normatif** tasarım spesifikasyonudur. Metin anahtarları `spec/strings.json` içindedir
(tek kaynak, her anahtar EN + TR + DE; Android `strings.xml` ve Apple `Localizable.xcstrings`
buradan üretilir – eksik çeviri üretimi durdurur).

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
**Alt sekme çubuğu ve başlık açılır menüsü yok.** Üstte başlık şeridi: solda uygulama işareti,
**metin sekmeleri** **Ana Sayfa · Filmler · Diziler · Canlı TV · TV Rehberi**
(seçili = beyaz metin + `primary` alt çizgi, diğerleri gri), sağda 🔍 Ara ve ⚙️ Ayarlar ikonları.
**Beş sekme her zaman görünür, yatay kaydırma yok** (TestFlight build 6: kaydırmalı şerit iPhone'da
"Canlı TV"/"TV Rehberi"ni gizliyordu, otomatik ortalama "Ana Sayfa"yı uygulama işaretinin altına
itiyordu). Her şey tek satıra sığarsa (yatay, iPad) tek satır; sığmazsa (dikey iPhone) **iki satır**:
üstte uygulama işareti · 🔍 · ⚙️, altında sekmeler tüm genişliğe eşit dağılmış. Sığmadığında yazı
önce küçülür (subheadline → footnote → caption, sonra ölçeklenir), hiçbir sekme kesilmez. Her
dokunma hedefi ≥ 44 pt yüksek. Başlık üst güvenli alan eki (`safeAreaInset`) olarak durur: hero'suz
ekranlar her yükseklikte (Dynamic Type, bir/iki satır) başlığın **altında** başlar; dinamik yazı
boyutu başlıkta `accessibility2` ile sınırlıdır.
Şerit hero üzerinde **şeffaf** durur, içerik kaydırılınca **siyaha** döner (hero'suz ekranlarda
hep siyah). Ara → genel arama ekranı (kanal + film + dizi). Ayarlar **sheet** olarak açılır (§3.9).
Favoriler ayrı sekme değildir: Ana Sayfa'da "Favoriler" satırı (+ "Tümünü gör" → Favoriler ekranı:
Kanallar · Filmler · Diziler segmenti), Filmler/Diziler'de "Favoriler" satırı, Canlı TV'de ilk
kategori çipi "★ Favoriler", TV Rehberi'nde "Tümü"nün ardından "Favoriler".
**Favori: her yerde tek dokunuş, onaysız, 4 sn geri al.**
1. ☆/★ düğmesi kanal kartında, film/dizi posterinin köşesinde (iOS), detay sayfasında, hero'da ve
   oynatıcı katmanında; tek dokunuş durumu **anında** değiştirir (iyimser güncelleme, onay diyaloğu yok).
2. Her değişiklikten sonra altta 4 sn "Favorilere eklendi / Favorilerden çıkarıldı · **Geri al**" kapsülü
   (VoiceOver duyurur); Geri al önceki durumu geri yükler. Kapsül oynatıcının üstünde de görünür.
3. Uzun bas (iOS bağlam menüsü / TV uzun OK) menüsünün **ilk öğesi** her zaman "Favorilere ekle/çıkar".
4. TV kartlarında ⭐ ikinci bir odak hedefi değildir (gösterge); TV'de favori: uzun OK menüsü, detay ⭐,
   oynatıcıda ▲ bilgi kartı.
5. Favoriler her listede **önce** gelir (Canlı TV "Tümü" ilk bölüm, oynatıcı kanal listesi). Favori
   **kategoriler** (kaynak başına, cihazda) kategori menüsünde ⭐ ile işaretlenir.
6. Favori sırası **yalnızca cihazda** (Favoriler ekranı → "Taşı"); senkronize olan yalnızca favori
   durumudur (CONTRACT §8 değişmez); yeni cihazda en yeni üstte.

**3 dokunuş kuralı:** Ana Sayfa'dan sık yapılan her iş en fazla 3 dokunuşla (TV: 3 OK) biter
(UI testi `testThreeTapPaths`):
* Canlı kanal izlemek: **Canlı TV** sekmesi → kanal satırı (2) – ya da Ana Sayfa'nın ilk satırı
  "Son izlenen kanallar" → kanal (1).
* Uygulama dili: ⚙️ → **Uygulama dili** → dil (3).
* Kaynak eklemek: ⚙️ → **Kaynaklar** → **+ M3U / Xtream** (3; form açık).
* Ses/altyazı dili, Hızlı başlat, TV/soundbar ses gecikmesi: ⚙️ → satır (2).
* Oynatıcıda başka kanal: kanal paneli (iOS liste düğmesi / soldan kaydırma, TV: OK) → kanal (2).

Kaynak yoksa Karşılama ekranı. Film/Dizi sekmesi, kaynak bunları sunmuyorsa gizlenmez; boş durum gösterir.
Dikey ve yatay desteklenir; grid sütun sayısı genişliğe göre artar (poster min. 104 pt).

### TV
Üstte yerel tvOS sekme çubuğu (Apple TV uygulaması gibi): **🔍 · Ana Sayfa · Filmler · Diziler ·
Canlı TV · TV Rehberi · ⚙️**. Sekmeye odaklanmak onu seçer; aşağı ok içeriğe iner (açılışta odak
sekme çubuğundadır – tvOS standardı; içeriğin ★ öğesi aşağı okla ilk ulaşılan öğedir). Canlı TV
listesinde satır başına tek odak hedefi vardır (favori / arşiv uzun OK menüsünde).

**Geri tuşu kuralları (TV, öngörülebilir):**
1. Oynatıcıda: açık panel/menü varsa kapatır → yoksa oynatıcıdan çıkar (önceki ekrana, odak
   oynatılan öğede).
2. Detay ekranında: bir önceki ekrana döner, odak açılan öğeye geri gelir.
3. Bir bölümün içeriğinde (satır/grid/EPG): odağı üst sekme çubuğuna taşır. İstisna Filmler/Diziler:
   sağ içerikte (göz atma sayfası / kategori grid'i) önce odağı soldaki kategori sütununa (seçili satır)
   taşır, sütunda ikinci basış sekme çubuğuna (§3.2).
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
* **Posterler** (satırlar, "Tümünü gör" grid'i, arama, Favoriler): iOS'ta sağ üst köşede küçük yuvarlak ☆/★
  (tek dokunuş, 44 pt hedef); uzun bas menüsünün ilk öğesi Favorilere ekle/çıkar (TV: uzun OK).
* **Ana Sayfa satırları:** **Son izlenen kanallar** (ilk satır: son oynatılan canlı kanallar, en yeni önce,
  en fazla 20; gizli kanallar hariç; zapping listesi = bu satır; CONTRACT §8 canlı ilerleme öğeleri) ·
  İzlemeye devam et (16:9 kart, ortada oynat ikonu, başlık kartın altında
  görsel üstünde, kartın altında `primary` ilerleme çubuğu; kural CONTRACT §8: %5 < konum < %95,
  süre bilinmiyorsa konum ≥ 10 sn ve çubuk gizli; en son `updatedAt` önce) · Favoriler (posterler) · Favori kanallar ·
  Yeni eklenen filmler · Yeni eklenen diziler · Canlı kanallar (kanal kartları).
* **Filmler / Diziler satırları:** İzlemeye devam et (yalnız o tür) · Favoriler · **Yeni eklenenler**
  (2:3 poster, altta küçük `primary` "YENİ" rozeti) · **Top 10** (posterin arkasında büyük, içi boş
  çerçeveli sıra numarası 1–10) · ardından **kategori satırları**: önce sabitlenen (📌) kategoriler, sonra
  seçili ülkenin kategorileri sağlayıcı sırasıyla (ilk 12, satır başına 20 öğe; ad + bayrak emojisi).
  Her satırda "Tümünü gör" → o kategorinin poster grid'i. Bir öğe birden fazla kategorideyse (Xtream
  `category_ids`, CONTRACT §4.3) her birinde görünür. İzlemeye devam et ve Favoriler **filtrelenmez**.
* **Kategori gezintisi (Build 9, Filmler/Diziler):** sağlayıcılar yüzlerce kategori listeler
  ("TR • NETFLIX DIZILER", "DE | …", "EN | …"); eski yatay çip satırı aranamıyordu (kaldırıldı).
  * **Ülke:** kategori adındaki kod/ülke adından tespit edilir (`CategoryCountry`, IPTVKit: "TR | …",
    "[TR] …", "TÜRKİYE", "Germany" …; "EN", "IT", "4K" gibi belirteçler ülke sayılmaz → yalnız "Tümü"nde).
    Seçim **kaynak + tür (film/dizi) başına** cihazda saklanır. İlk kullanımda varsayılan = arayüz dilinin
    ülkesi (tr → TR, de → DE, en → Tümü), **yalnızca** o ülkenin (gizlenmemiş) kategorisi varsa; yoksa ya da
    seçilen ülkenin kategorisi kalmadıysa Tümü. Ülke seçiliyse **Yeni eklenenler, Top 10, hero** ve
    kategori satırları o ülkenin kategorilerinden gelir ("Tümünü gör" grid'i de); **Tümü** = önceki davranış
    (tüm kaynak, sağlayıcı sırası).
  * **iPhone/iPad:** üst sekmelerin hemen altında **sabit satır** (sayfa kayarken görünür kalır; hero üzerinde
    şeffaf, başlık siyaha dönünce siyah): geniş **"Kategoriler ▾"** düğmesi + **ülke seçici** hap
    ("TR Türkiye ▾" metin kodu rozeti + ülke adı, ya da "🌐 Tümü ▾"). Ülke seçici menüsü: "Tümü (n)" +
    kategorisi olan her ülke (bayrak, ad, kategori sayısı); seçili ülke önce, sonra en çok kategorisi olan.
  * **Kategori sayfası** (iPhone'da tam ekran, iPad'de büyük sheet): başlık "Film kategorileri" / "Dizi
    kategorileri"; **arama alanı** (büyük/küçük harf ve aksan duyarsız, "TR | " gibi ülke öneki aranmaz);
    **ülke çipleri** (Tümü + ülkeler, sayılı, satır kaydırmalı – seçim sayfanın ülkesidir); bölümler
    **Sabitlenenler** · **Son açılanlar** (son 5, en yeni önce) · seçili ülkenin (ya da tüm) kategorileri,
    her birinde içerik sayısı. Dokunmak sheet'i kapatır, kategorinin grid'ini açar ve "Son açılanlar"a
    yazar. Uzun bas: **Sabitle / Sabitlemeyi kaldır**, **Kategoriyi gizle** (gizlemek sabitlemeyi de
    kaldırır). Sonda **"Gizlenenleri göster (n)"** anahtarı gizlenenleri listeler (👁 **Tekrar göster**).
    Gizlenen film/dizi kategorileri **kaynak + tür** başına tutulur (Xtream VOD ve dizi kategori kimlikleri
    çakışabilir); Canlı TV'nin gizlenenleri (`HiddenStore`) ayrıdır ve değişmedi.
  * **Apple TV:** solda ~360 pt **kategori sütunu**, sağda içerik. Sütun (satır başına tek odak hedefi):
    ülke seçici (menü) · **Keşfet** (sağda hero + satırlı göz atma sayfası; varsayılan) · Sabitlenenler ·
    Son açılanlar (sekme açıldığındaki hâli; seçim sırasında odak kaymasın diye canlı güncellenmez) ·
    ülkenin kategorileri (sayılı) · gizlenen varsa "Gizlenenleri göster (n)". Kategoride **OK** → sağda
    o kategorinin grid'i (odak sütunda kalır, ▶ grid'e geçer). Uzun OK: sabitle / gizle (gizlenende tekrar
    göster). **Geri:** sağ içerikte → odak sütundaki seçili satıra; sütunda → üst sekme çubuğu (§2 TV).
    Sütunda arama yok (genel arama sekmesi var).
* **"YENİ" kuralı:** `added` sırasına göre en yeni 20 öğe. **Top 10 kuralı:** kaynağın puanı
  (`rating`) azalan; puanı olan öğe yoksa en yeni eklenen 10 öğe. (Sunucuya izlenme verisi
  gönderilmez – sıralama tamamen yereldir.)
* Üstte deneme durum çipi ve (birden fazla kaynak varsa) kaynak seçici Ana Sayfa hero'sunun üstünde.
* **QuickStart (Hızlı başlat, Ayarlar üst düzey, varsayılan açık):** uygulama bir canlı kanal oynarken
  arka plana alındıysa / sonlandırıldıysa (`LastSession.endedInPlayer = true`), sonraki açılışta Ana Sayfa
  beklenmeden — kaynak yenilemesinden (`env.start()`) önce — o kanal doğrudan oynatıcıda açılır (kanal
  zapping listesi = kanalın kategorisi, ilk 200). Kullanıcı oynatıcıyı Geri / Kapat ile kapattıysa ya da en
  son VOD oynattıysa bayrak düşer ve normal Ana Sayfa açılır. Hiç kaynak yoksa (karşılama), kanal artık
  yoksa veya oynatma kilitliyse (`canPlay` false; TestFlight tam erişimi değerlendirildikten SONRA kontrol
  edilir) QuickStart çalışmaz. TestFlight erişimi önce eşzamanlı sandbox makbuzuyla verilir (StoreKit beklenmez);
  yalnızca o vermezse `AppTransaction` arka planda doğrular ve QuickStart onu en çok StoreKit yetki
  beklemesiyle aynı **1,5 sn** pencere içinde bekler. Hedef: soğuk başlangıç → ilk kare ≤ 1,5 sn.

### 3.3 Canlı TV
**Liste görünümü** (TestFlight build 6 sonrası kullanıcı kararı: kart grid'i yerine, ekranda daha çok kanal).
* **Satır** (iPhone ~76 pt): kanal numarası (soluk, eş aralıklı) · 48 pt renkli logo karosu (logo sığdırılmış)
  · ad (yarı kalın, tek satır) + kalite rozeti (adındaki HD/FHD/4K/UHD/SD) + ⟲ (geçmiş yayın varsa) ·
  **Şimdi:** saat aralığı + program başlığı (tek satır) + ince `primary` ilerleme çubuğu · **Sonra:**
  "Sonra 21:00 · Başlık" (ikincil, tek satır) · sağda **☆/★** (tek dokunuş, §2; yalnız iOS). EPG yoksa
  "Program bilgisi yok". Oynatılan kanalın — oynatıcı kapalıyken bu kaynakta **en son oynatılan** kanalın (LastSession) — satırı:
  solda `primary` çubuk + "● İzleniyor".
* **Kategori çipleri** (iOS: başlığın altında sabit, yatay kaydırılır): **★ Favoriler (n)** · **Tümü (n)** ·
  favori kategoriler (⭐) · diğer kategoriler; bayrak emojisi kategori adından (TR/Türkiye → 🇹🇷, DE → 🇩🇪 …),
  yanında kanal sayısı (çoklu kategori üyeliği dahil, tek sorgu). Seçili çip dolu beyaz. Kategori çipine
  uzun bas → "⭐ Kategoriyi favorilere ekle / çıkar" (kaynak başına, yalnız bu cihazda). Gizlenen varsa
  sonda "Gizlenenleri göster (n)".
* **Favoriler önce:** "Tümü" seçiliyken önce **★ Favoriler** bölümü (cihazdaki sıra), sonra **Tüm kanallar**
  (sayfalı). ⭐ değişince yalnızca favori bölümü ve sayılar yeniden yüklenir.
* Dokun → oynatıcı. **Uzun bas** (iOS bağlam menüsü / TV uzun OK) → Favorilere ekle/çıkar (ilk öğe) ·
  **Kanalı gizle** · **Kategoriyi gizle** · ⟲ Arşiv (varsa) · **Rehberde göster** (TV Rehberi kanalın
  kategorisiyle açılır — kategorisi yoksa Tümü —, satır yüklenip ortaya kaydırılır, iPad/TV'de panelde o kanal). Gizlenen kanal/kategori
  listeleri kaynak başına **yerel** saklanır (UserDefaults, senkronize edilmez).
* **Geniş ekran** (iPad, iPhone yatay; genişlik ≥ 700 pt): solda liste (~%55), sağda **bilgi paneli**: logo + ad,
  **ŞİMDİ YAYINDA** başlık + saat + ilerleme + açıklama, ▶ Oynat · ☆ · 📅 Rehber · ⟲ Arşiv, **BUGÜN** sıradaki
  programlar (saat · başlık · süre). **Yalnız iPad'de** (geniş boyut sınıfı) ilk dokunuş satırı seçer (panel),
  seçili satıra dokunmak oynatır; iPhone yatayda panel ilk satırı gösterir, dokunuş hemen oynatır.
  Otomatik video önizlemesi yok.
* **Apple TV:** solda kategori sütunu (dikey, sayılı; OK seçer; gizlenen varsa en altta "Gizlenenleri göster (n)")
  | kanal listesi | bilgi paneli (butonsuz).
  Satır başına **tek odak hedefi** (⭐ gösterge; favori: uzun OK menüsü veya oynatıcıda ▲ bilgi kartı).
  D-pad ▲▼ satırlar arasında akıcı; panel odağı 150 ms gecikmeyle izler; OK oynatır.
* Performans: lazy liste, sabit id'ler, sayfa başına (120) tek now/next sorgusu (§ bütçe ≤ 20 ms), logolar
  küçültülerek önbellekli (ImageLoader); 5 000+ kanallı kategoride 60 fps kaydırma hedefi. Arama ayrı
  ekranda (debounce 250 ms, FTS).

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
  sezon sayısı); kısa açıklama; "Tür: …" satırı; küçük eylem satırı: ☆ favori (tek dokunuş, §2) · ⟲ baştan oynat
  (devam varsa) · format pill ("MKV · HD"). Birincil eylem metni: "Oynat" / "Devam et (01:12:30)" /
  "Devam et S02E05".
* **Dizi:** sezonlar yatay **metin sekmeleri** ("Sezon 1 · Sezon 2 …", seçili `primary` alt çizgi);
  bölüm satırı = 16:9 küçük resim (ortada oynat ikonu, altta ilerleme) + "1. Başlık" + süre /
  izlendi ✓. ★ "Devam et S02E05" (son izlenen bölüm; bitmişse sonraki). Bölüm bitince sonraki bölüm
  için 10 sn geri sayım kartı. TV'de bölümler yatay 16:9 kart rafı.

### 3.6 Favoriler ve arama
* Favoriler ekranı (Ana Sayfa "Favoriler" satırı → "Tümünü gör"): segment Kanallar · Filmler ·
  Diziler; kanallar TV Rehberi satırlarıyla, filmler/diziler poster grid'i. Kaldırma: posterdeki ★ (iOS) veya
  uzun bas menüsü (geri alınabilir, §2). Hesap varsa favori durumu senkronize edilir (son senkron saati gösterilir).
* **Sıralama ("Taşı"):** sağ üstte (TV: segmentin yanında) "Taşı" → seçili segment liste olur. iOS: tutamaçla
  sürükle-bırak; TV: öğeyi seç → ▲▼ ile taşı → tekrar seç bırakır (taşınırken diğer satırlar odak almaz).
  "Bitti" çıkar. Sıra cihazda saklanır, diğer kaynakların favorileri yerinde kalır.
* Arama: tek alan, sonuçlar satır olarak (Kanallar kartları · Filmler · Diziler posterleri).

### 3.7 Oynatıcı
* Tam ekran, sistem çubukları gizli, ekran açık kalır.
* Katman (3 sn sonra kaybolur): üstte kanal/başlık, solda kanal numarası; altta zaman çizgisi
  (VOD) veya program ilerlemesi (canlı), "CANLI" rozeti; sağda araçlar: Ses · Altyazı ·
  Görüntü oranı · **⭐ Favori** (kanal / film / bölümün dizisi; tek dokunuş, 4 sn geri al kapsülü alt çubuğun
  üstünde) · (canlı) Kanal listesi. Kanal listesinde favori kanallar en üstte.
* **Kanal paneli (canlı, oynatıcı içinde):** oynatma arkada sürer. Solda panel: iOS yatayda genişliğin
  %40'ı, iOS dikeyde tam ekran (sayfa gibi, kapat ✕), tvOS 600 pt. Üstte "Kanallar" + **kategori seçici**
  (Tümü · ★ Favoriler · favori kategoriler · diğerleri; gizliler hariç); açılışta oynayan kanalın
  kategorisi seçili, oynayan kanal görünür (TV: odakta) ve işaretli. **Favoriler önce** (Tümü: favoriler
  bölümü, kategori: içindeki favoriler üstte). Satır: numara · logo · ad · şu anki program · ⭐ göstergesi.
  Satıra dokunmak/OK o kanala geçer (zapping yolu, 400 ms birleştirme) ve paneli kapatır; gösterilen liste
  yeni zapping listesi olur (▲▼ / kaydırma onda devam eder). Panel açılırken katman kapanır (kapanınca katman
  takılı kalmaz). iOS: katmandaki liste düğmesi veya **soldan kaydırma** açar; panelin yanına dokunmak ya da
  sola kaydırmak kapatır. tvOS: katman kapalıyken **OK** açar, Menü kapatır; ilk satırda ▲ kategori seçiciye,
  oradan ▼ listeye gider; tvOS başlığında tek satır ipucu "◀▶ Araçlar · ▲ Bilgi" (`player_tv_hint`). Oynayan
  kanal başka bir kategoride seçilirse yayın yeniden açılmaz, yalnızca o liste zapping listesi olur. Açılış
  ≤ 100 ms (kategori sayıları yüklenmez; sayfa 120 satır; oynayan kanal en fazla 600 satır içinde aranır –
  50 000 kanalda ölçüm `PanelLoadPerformanceTests`).
* **TV canlı – ▲ = kanal bilgisi:** katman kapalıyken ▲ altta bilgi kartını açar (logo, numara, ad, Şimdi +
  saat + ilerleme, Sonra), **⭐ odakta** (OK = favori ekle/çıkar). Kart açıkken ▲/▼ kanal değiştirir (kart yeni
  kanalı gösterir), Geri kartı kapatır; ⭐ sonrası "Geri al" kapsülü kartın **altında** (⭐'ın hizasında) durur:
  teklif sürerken ▼ "Geri al"a, ▲ ⭐'a gider (kanal değişmez); 6 sn dokunulmazsa kaybolur (⭐ değişince süre yeniden başlar).
  Katman kapalıyken ▼ = sonraki kanal. Katman veya kanal listesi açıkken ▲▼ yalnızca odağı taşır.
* **Kanal değiştirme (canlı):** mobil yukarı/aşağı kaydır, TV D-pad ▼ (▲ önce bilgi kartı, kart açıkken ▲▼) / CH+/CH−. Basıldığı
  anda (< 100 ms) üstte büyük bilgi kartı: numara, logo, ad, şimdiki program; yükleme
  göstergesi kartın içinde. Ard arda basışlar 400 ms içinde birleştirilir (yalnızca son kanal
  açılır). TV'de rakam tuşları: 1,5 sn içinde girilen numaraya geçer (aşağıda "Rakamlar").
  **Son izlenen kanal** (bir önceki açık kanala dönüş): mobilde ve TV'de katmanın araçlarındaki
  `arrow.uturn.backward` düğmesi (TV: üst satırın son öğesi); Geri tuşu değildir. Bilgi kartındaki ▲▼ ise
  zapping listesinde **önceki/sonraki kanaldır**.
* **VOD:** ◀▶ 10 sn ileri/geri (basılı tutunca hızlanır), OK oynat/duraklat. Kaldığı yerden
  devam: açılışta otomatik devam + "Baştan başla" kısa düğmesi (5 sn görünür, katmandan
  bağımsız; kayıtlı konum ≥ 10 sn ve < %95 ise).
  * **Mobil (iOS):** katmanın ortasında büyük taşıma satırı: ⟲10 · oynat/duraklat (64 pt) ·
    10⟳ (canlıda yalnızca oynat/duraklat). Görüntüye çift dokunma: sol üçte bir −10 sn, sağ
    üçte bir +10 sn, kısa "−10 sn"/"+10 sn" halkası (ard arda çift dokunmalar toplanır, katman
    açılıp kapanmaz); tek dokunma katmanı açar/kapatır; senkron paneli açıkken tek veya (orta üçte bir / canlı) çift
    dokunma önce paneli kapatır, katman açılmaz. Altta sürüklenebilir zaman çizgisi
    (44 pt dokunma yüksekliği): sürüklerken hedef zaman balonda görünür, gelen zaman
    güncellemeleri başparmağı oynatmaz, bırakınca atlar. Süre bilinmiyorsa çizgi yalnızca
    gösterir (sürükleme yok), süre "--:--".
  * **TV (tvOS):** ◀▶ 10 sn; basılı tutunca 0,3 sn'de bir tekrar, 1 sn sonra 30 sn adım. Katman
    görünürken odak oynat/duraklat'tadır: OK oynat/duraklat, ◀▶ atlar (odak yana kaymaz);
    ▲ üst satıra (kapat + araçlar, odak kapat'ta) geçer, ▼ geri döner. Üst satırda ◀▶ araçlar
    arasında gezinir (kapat · Ses · Altyazı · Oran · Senkronu düzelt · ⭐ · canlıda Kanal listesi ·
    Son izlenen kanal; uçlarda durur); üst satır (ve oradan açılan menü) kullanılırken katman 3 sn sonra
    kapanmaz, ▼ oynat/duraklat'a döner ve sayacı yeniden başlatır. Canlı: katman açıkken ▲ aynı üst
    satıra girer (katman kapalıyken ▲ = kanal bilgi kartı, değişmedi). Katman kapalıyken OK
    VOD'da duraklatır/sürdürür ve katmanı açar; **canlıda kanal panelini açar** (katman: ◀▶ veya
    Oynat/Duraklat tuşu). Tam tuş haritası aşağıdaki tabloda. Siri Remote dokunmatik
    yüzeyinde kaydırarak sarma v1'de yok (SwiftUI odak modeliyle güvenilir değil); basılı tutma
    aynı ihtiyacı karşılar.
  * Katman 3 sn sonra yalnızca oynarken kaybolur: duraklatılmışken, çizgi sürüklenirken,
    ses/altyazı/oran menüsü açıkken veya kanal listesi açıkken kalır; her atlama/duraklatma
    sayacı yeniden başlatır.
  * **İlerleme kaydı:** oynarken 10 sn'de bir, duraklatınca, kapatınca ve uygulama arka plana
    geçince (her iki motor). Motor süre bildirmezse (bazı MKV/Xtream VOD) konum `durationMs` 0
    ile yine kaydedilir (devam çalışır ve ≥ 10 sn ise "İzlemeye devam et" satırında çubuksuz
    görünür; "izlendi" (≥ %95) süre ister). Dosya sonu = tamamı izlendi.
  * **Kendiliğinden duraklama yok** (canlı + VOD): oynatıcı yalnızca kullanıcı duraklatınca (veya
    kulaklık çıkarılınca / ses kesintisinde) duraklar; motorun başka her "paused" bildirimi
    takılmadır (yükleniyor göstergesi, otomatik sürdürme, 12 sn sonra yeniden bağlanma).
* **TV tuş haritası (tvOS, Siri Remote + rakam tuşları):**

  | Durum | OK | ▲ | ▼ | ◀ ▶ | Oynat/Duraklat | Menü | Rakamlar |
  |---|---|---|---|---|---|---|---|
  | Canlı, katman kapalı | Kanal paneli | Bilgi kartı | Listede sonraki kanal | Katmanı aç | Duraklat/sürdür + katman | Oynatıcıdan çık | Numaraya geç |
  | Canlı, katman açık (odak oynat/duraklat) | Duraklat/sürdür | Üst satır (kapat'ta) | – | – | Duraklat/sürdür | Katmanı kapat | Numaraya geç |
  | Üst satır (kapat + araçlar) | Seçili araç (menü / panel) | – | Oynat/duraklat'a dön | Araçlar arasında (uçlarda durur) | Duraklat/sürdür | Katmanı kapat | Numaraya geç |
  | Bilgi kartı (⭐ odakta) | Favori ekle/çıkar | Listede önceki kanal (Geri al teklifinde: ⭐) | Listede sonraki kanal (Geri al teklifinde: Geri al) | – | Duraklat/sürdür | Kartı kapat | Numaraya geç |
  | Kanal paneli | Kanala geç, paneli kapat | Odak yukarı (ilk satırda kategori seçici) | Odak aşağı | – | Duraklat/sürdür | Paneli kapat | Numaraya geç |
  | Senkron paneli | – | Satırlar arası | Satırlar arası | Değeri değiştir (hızlanır) | Duraklat/sürdür | Paneli kapat | – (yok sayılır) |
  | VOD, katman kapalı | Duraklat/sürdür + katman | Katmanı aç | Katmanı aç | −/+10 sn (basılı: hızlanır) | Duraklat/sürdür + katman | Oynatıcıdan çık | – |
  | VOD, katman açık | Duraklat/sürdür | Üst satır | – | −/+10 sn | Duraklat/sürdür | Katmanı kapat | – |

  "Üst satır" araçlarının sonu: Kanal listesi · **Son izlenen kanal** (yalnızca bir önceki kanal varsa).

  **Rakamlar (numara ile kanal):** IR kumanda (HDMI-CEC) / klavye rakamları canlıda sağ üstte büyük
  gösterilir (en fazla 4 hane; senkron paneli açıkken yok sayılır); son rakamdan 1,5 sn sonra numara
  **kaynağın tüm kanallarında** aranır (`CatalogRepository.channelForNumberZap`, `(source_id, number)`
  indeksi; aynı numara birden çoksa liste sırasında ilki). Kanal zapping listesinde değilse kendi kategorisinde
  çevresi (liste sırasında en fazla 100 önce + 100 sonra, `channelZapWindow`) yeni zapping listesi olur; ▲▼
  gerçek komşulara gider. Veritabanı hatası "Kanal yok" gibi gösterilmez: loglanır, kanal değişmez. Kaynakta **hiç kanal numarası yoksa** numara listedeki sıra olarak
  okunur (1'den); numaralı kaynakta olmayan numara → kanal değişmez, aynı yerde 2 sn "Kanal yok"
  (`zap_no_channel`). Siri Remote'ta rakam yoktur.
* **Görüntü oranı:** Sığdır · Doldur (kırp) · Uzat · 16:9 · 4:3 – seçim kanal başına değil,
  global hatırlanır.
* **Ses / altyazı:** dil adıyla listelenir (`Türkçe`, `English`, bilinmiyorsa `Parça 2`),
  altyazı "Kapalı" seçeneği; tercih edilen ses/altyazı dili ayarlardan otomatik uygulanır.
* **Ses senkronu:** Ses menüsünde her zaman "Senkron" satırı (ses izi olmasa da). Açılan panel
  **modal değildir**, altta durur ve görüntü üstünde oynamaya devam eder (iPhone yatayda alçak, tek
  satırlık kontroller). İki satır: "Bu kanal/içerik" (bu içerik için kaydedilir) ve "Ses gecikmesi
  (TV/soundbar)" (cihaz gecikmesi, her içeriğe eklenir) – böylece cihaz gecikmesi izlerken
  ayarlanabilir. −2000…+2000 ms, 50 ms adım; değer yönüyle gösterilir: "+150 ms · ses daha geç",
  "−100 ms · ses daha erken"; her değişiklik canlı uygulanır (kanal değişimi 400 ms beklerken yapılan
  değişiklik hedef kanala kaydedilir ve o kanal açılınca uygulanır, terk edilen kanala asla). Panel açıkken
  katman hiçbir yoldan (dokunma, Oynat/Duraklat, VoiceOver) üstüne açılmaz. Altında yön ipucu ("Ses görüntüden önce
  mi geliyor? + kullan…"). iOS: kaydırıcı + −/+ düğmeleri, kapat düğmesi; tvOS: her satır tek
  odaklanabilir kontrol, ◀▶ değiştirir, art arda/basılı tutunca hızlanır (50 → 100 → 250 ms),
  Menü paneli kapatır. Motor AVPlayer ise not: "Gecikme ayarlanınca bu kanal VLC motoruyla
  oynatılır"; VLCKit oynatamazsa yayın gecikmesiz AVPlayer ile sürer ve "Senkron bu yayında
  uygulanamadı" notu (4 sn) görünür. Katmanın araçlarında "Senkronu düzelt" düğmesi
  (`arrow.triangle.2.circlepath`): canlıyı canlı uçtan, VOD'u mevcut konumdan yeniden açar.
  Ayarlar (üst düzey) → "Ses gecikmesi (TV/soundbar)" (aynı kontrol, alt bilgide yön ipucu).
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
**Üst düzey yalnızca kullanıcının sık değiştirdikleri** (tek grup, kaydırmasız):
**Kaynaklar** (sayı ile → Kaynaklar ekranı) · **Uygulama dili** · **Ses dili** · **Altyazı dili** ·
**Hızlı başlat** · **Ses gecikmesi (TV/soundbar)** (§3.7 – TV'deki dudak senkronu düzeltmesi, bu yüzden üstte);
alt bilgide Hızlı başlat açıklaması ve gecikme yön ipucu. Altında tek satır **Gelişmiş ve tanılama** →
geri kalan her şey.
* **Kaynaklar ekranı:** liste (ad, tür, host, son yenileme, durum rozeti, hesap bitiş tarihi) →
  detay: Yenile · Düzenle · EPG URL · EPG saat kaydırma (−12..+12 saat, 15 dk adım) ·
  Otomatik yenileme (Kapalı/6/12/24 saat) · Sil (onaylı). "Kaynak ekle": **+ M3U** · **+ Xtream** ·
  (TV) **Telefonla ekle (QR)**.
* **Uygulama dili:** Sistem / Deutsch / Türkçe / English – dil adları her zaman kendi dilinde. Arayüz üç
  dilde tamdır (EN/TR/DE); "Sistem" cihaz dilini izler, desteklenmeyen dillerde English. Dil değişince
  arayüz hemen yeniden çizilir; tarih/saat seçilen dile göre biçimlenir (DE/TR: 24 saat).
* **Gelişmiş ve tanılama** ekranı:
  * **Oynatma:** görüntü oranı varsayılanı, canlı yayın formatı (Android: Otomatik/TS/HLS), arabellek
    (Normal/Büyük), TV'de önizleme oynatıcısı.
  * **Görünüm:** EPG saat dilimi (Cihaz/özel), 24 saat biçimi.
  * **Hesap (opsiyonel):** e-posta ile giriş (kod), TV'de "Telefonla giriş yap" (cihaz kodu + QR),
    senkronizasyon durumu, çıkış, **hesabı sil**.
  * **Satın alma:** durum, geri yükle.
  * **Tanılama:** Format testi (`stream-samples.json`; Apple'da her örneğin motoru – AVPlayer/VLCKit –
    gösterilir ve `expect.apple` ile karşılaştırılır), performans katmanı, önbelleği temizle (görsel / EPG),
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

Oynatma HTTP hataları birkaç saniye içinde karta dönüşür, sonsuz yükleniyor göstergesi olmaz:
AVPlayer'da hata kodu (401/403/404) doğrudan, nedensiz hata ilk karede önce veya öğe 8 sn hâlâ
hazır değilse 1 KiB HTTP yoklamasıyla (CONTRACT §6.1, VLCKit ile aynı) sınıflandırılır:
401/403 → AccessDenied, 404/410 → StreamOffline (kart hemen), 5xx → ServerError (yeniden
bağlanma politikası, sonra kart).

## 5. Erişilebilirlik
* Tüm ikon butonlarda içerik açıklaması (TalkBack/VoiceOver).
* Dokunma hedefi ≥ 48 dp / 44 pt. Kontrast ≥ 4.5:1 (metin), odak halkası ≥ 3:1.
* Dinamik yazı boyutu (mobil) desteklenir; TV'de sabit büyük ölçek.
