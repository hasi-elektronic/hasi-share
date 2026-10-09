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
* Ses/altyazı dili, Hızlı başlat, Ses senkronunu ayarla (VLC kalibrasyonu): ⚙️ → satır (2).
* Oynatıcıda başka kanal: kanal paneli (iOS liste düğmesi / soldan kaydırma, TV: OK) → kanal (2).

**Geri hareketi (iPhone/iPad):** her itilmiş sayfada (detay, grid, arama, ayarlar alt sayfaları) ekranın sol
kenarından sağa kaydırmak bir önceki sayfaya döner — gezinti çubuğu gizli olsa da (sistem kenar kaydırması
yeniden etkin; kök ekranda bir şey yapmaz). Sayfa gibi davranan tam ekran Kategoriler sayfası da sol kenardan
(ilk ~24 pt) yatay ≥ 80 pt kaydırmayla kapanır (sayfa parmağı izler). Yalnız kenardan başlar; yatay raflar,
kaydırma çubuğu ve liste kaydırma eylemleri etkilenmez. Bir geçiş (itme/geri) animasyonu sürerken kenar
kaydırması başlamaz. Oynatıcı kendi hareketlerini korur (§3.7).

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
2. Detay ekranında: bir önceki ekrana döner, odak açılan öğeye geri gelir. Film/dizi detayı tam ekrandır,
   üst sekme çubuğu gizlenir (Apple TV uygulaması gibi; Build 16).
3. Bir bölümün içeriğinde (satır/grid/EPG): odağı üst sekme çubuğuna taşır. İstisna Filmler/Diziler:
   sağ içerikte (göz atma sayfası / kategori grid'i) önce odağı soldaki kategori sütununa (seçili satır)
   taşır, sütunda ikinci basış sekme çubuğuna (§3.2).
4. Sekme çubuğundayken: sekmenin yığınında açılmış bir sayfa varsa (ör. Favoriler, ayar alt sayfası) önce o
   sayfa kapanır — yığın kökte değilken uygulamadan **asla** çıkılmaz (Build 16, B-01); kökteyse Ana Sayfa
   değilse Ana Sayfa'ya geçer; Ana Sayfa'da uygulamadan çıkar.
5. Diyaloglar her zaman geri tuşuyla kapanır (iptal anlamında). Kaynak ekleme hata kartında Menü doldurulmuş
   forma döner (yazılanlar korunur, B-04).

**Odak kuralları:** Her ekranın varsayılan odak öğesi tanımlıdır (aşağıda ★). Bir bölgeye dışarıdan
girildiğinde (sekme çubuğundan ▼, raflardan ▲) geometrik olarak en yakın öğe değil ★ odaklanır: hero ve detay
eylem satırında beyaz "▶ Oynat / Devam et" pill'i (Favori/Bilgi değil), sezon sekmelerinde seçili sezon,
kategori sütunlarında seçili satır, TV Rehberi'nde ilk satırın şu an yayındaki bloğu (Build 16). Satırlar arası
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
  **Build 16:** hesaplar/QR eşleştirme `ACCOUNTS_ENABLED = NO` (xcconfig, Info.plist) ile gizli – backend canlı
  olana kadar QR seçeneği, "Telefonla giriş yap", hesap satırları ve paywall hesap notu görünmez, backend'e
  (lisans senkronu dahil) hiç istek gitmez; yer tutucu backend URL'si (`*.example…`) ile de aynı. tvOS
  karşılamada odak ilk "kaynak ekle" seçeneğindedir.
  * M3U formu: Ad, URL, (isteğe bağlı) EPG URL, gelişmiş: User-Agent.
  * Xtream formu: Ad, Sunucu (`http://host:port`), Kullanıcı adı, Şifre (göster/gizle).
  * "Bağlan" → ilerleme (adım adım: *Bağlanılıyor → Hesap doğrulanıyor → Kanallar yükleniyor (12 430)
    → EPG yükleniyor*) → başarı ekranında özet (kanal / film / dizi sayıları, hesap bitiş tarihi).
  * Hatalar ayrı ayrı (bkz. §4). Kaydet butonu yalnızca form geçerliyken aktif. Form içindeki hata kartı her
    zaman **Düzenle** (forma dön) sunar, hiçbir zaman **Kaynağı sil** sunmaz (henüz kayıtlı kaynak yok).
  * İkinci ve sonraki kaynak eklenince **aktif kaynak değişmez**; başarı ekranında "Bu kaynağı kullan"
    düğmesi vardır. Kaynak seçicide (iOS) ve Kaynaklar listesinde aktif kaynak ✓ / "Aktif" ile işaretlidir.
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
  * **Ülke / dil grubu:** kategori adının başındaki 2–3 büyük harfli kod + ayraç (`•`, `|`, `:`, `-`, `]`
    ya da `[XX]`) grubu belirler — ISO ülke kodu olsun olmasın ("TR • …" → TR, "IT | Serie" → IT,
    "EN • Drama" → EN, "AR | مسلسلات" → AR; rakam içeren "4K | …" grup değildir). Öneki olmayan adlarda
    eski tespit sürer (ülke adları, "Sport (UK)", takma adlar UK → GB, USA → US, TÜRKİYE → TR); grubu olmayan
    kategoriler yalnız "Tümü"nde. Etiket / kanal / paket önekleri grup değildir (tek liste
    `CategoryCountry.tagCodes`: SD, HD, FHD, UHD, HDR, VO, VOD, TV, VIP, PPV, NEW, TOP, XXX, UFC, NBA, BBC,
    HBO, TRT …); `-` yalnızca ardından boşluk varsa ayraçtır ("Sci-Fi" bölünmez); bitişik
    "IT-Serie" / "EN-Drama" biçimleri önek grubu oluşturmaz (eski ad tespiti yalnızca tireli kelimenin ilk
    parçasına bakar: "TR-Yerli" → TR, "SCI-FI" → grup yok). Etiket önekleri görünen adda kalır
    ("4K | Germany" → 🇩🇪 "4K | Germany"); yalnızca grubun kendi kodu kaldırılır. Hero / detaydaki tür satırı
    kategori adını öneksiz gösterir ("EN | Amazon Prime" → "Amazon Prime"). **Gösterim:** rozet = kod (EN, AR, TR); ad = dil önce gelen kodlarda (EN,
    AR ve ISO ülkesi olmayan her kod; 3 harfli kodlarda yalnız kısa bir liste: ENG, GER, TUR, ARA, SPA …,
    gerisi ham kod) uygulama dilinde dil adı ("İngilizce", "Arapça"), diğerlerinde ülke adı
    ("Türkiye", "Almanya", "İtalya"); bayrak emojisi yalnız gerçek ülkelerde (EN'de bayrak yok, AR'de 🇦🇷 yok;
    TV/HD gibi etiketlerde de yok). Bayraksız gruplarda satırda kod rozeti durur.
    Seçim **kaynak + tür (film/dizi) başına** cihazda saklanır. İlk kullanımda varsayılan = arayüz dilinin
    grubu (tr → TR, de → DE, en → EN), **yalnızca** o grubun (gizlenmemiş) kategorisi varsa; yoksa ya da
    seçilen grubun kategorisi kalmadıysa Tümü. Grup seçiliyse **Yeni eklenenler, Top 10, hero** ve
    kategori satırları o grubun kategorilerinden gelir ("Tümünü gör" grid'i de); **Tümü** = önceki davranış
    (tüm kaynak, sağlayıcı sırası).
  * **iPhone/iPad:** üst sekmelerin hemen altında **sabit satır** (sayfa kayarken görünür kalır; hero üzerinde
    şeffaf, başlık siyaha dönünce siyah): geniş **"Kategoriler ▾"** düğmesi + **ülke seçici** hap
    ("TR Türkiye ▾" metin kodu rozeti + ülke adı, ya da "🌐 Tümü ▾"). Ülke seçici menüsü: "Tümü (n)" +
    kategorisi olan her ülke (bayrak, ad, kategori sayısı); seçili ülke önce, sonra en çok kategorisi olan.
  * **Kategori sayfası** (iPhone'da tam ekran, iPad'de büyük sheet): başlık "Film kategorileri" / "Dizi
    kategorileri"; **arama alanı** (büyük/küçük harf ve aksan duyarsız; tam ad ve grup kodu olmadan ad aranır – "hbo", "trt", "4k",
    "tr" bulunur);
    **ülke çipleri** (Tümü + ülkeler, sayılı, satır kaydırmalı – seçim sayfanın ülkesidir); bölümler
    **Sabitlenenler** · **Son açılanlar** (son 5, en yeni önce) · seçili ülkenin (ya da tüm) kategorileri,
    her birinde içerik sayısı. **Arama yazılıyken** sonuçlar seçili ülkeden bağımsız olarak **tüm**
    kategorilerden gelir (başlık "Tüm kategoriler"; Sabitlenenler / Son açılanlar gizlenir, ülke çipleri
    görünür kalır); arama silinince seçili ülkenin listesi döner. Dokunmak sheet'i kapatır, kategorinin grid'ini açar ve "Son açılanlar"a
    yazar. Uzun bas: **Sabitle / Sabitlemeyi kaldır**, **Kategoriyi gizle** (gizlemek sabitlemeyi de
    kaldırır). Sonda **"Gizlenenleri göster (n)"** anahtarı gizlenenleri listeler (👁 **Tekrar göster**).
    Gizlenen film/dizi kategorileri **kaynak + tür** başına tutulur (Xtream VOD ve dizi kategori kimlikleri
    çakışabilir); Canlı TV'nin gizlenenleri (`HiddenStore`) ayrıdır ve değişmedi.
  * **Apple TV:** solda ~360 pt **kategori sütunu**, sağda içerik. Sütun (satır başına tek odak hedefi):
    ülke seçici (menü) · **Keşfet** (sağda hero + satırlı göz atma sayfası; varsayılan) · Sabitlenenler ·
    Son açılanlar (sekme açıldığındaki hâli; seçim sırasında odak kaymasın diye canlı güncellenmez) ·
    ülkenin kategorileri (sayılı) · gizlenen varsa "Gizlenenleri göster (n)". Kategoride **OK** → sağda
    o kategorinin grid'i (odak sütunda kalır, ▶ grid'e geçer). Uzun OK: sabitle / gizle (gizlenende tekrar
    göster). Ülke değişince ya da seçili kategori sabitlemesi kaldırılıp / gizlenip sütundan çıkınca sağda
    yeniden Keşfet açılır. **Geri:** sağ içerikte → odak sütundaki seçili satıra (satır artık yoksa
    Keşfet'e); sütunda → üst sekme çubuğu (§2 TV). Keşfet sayfası kategori grid'i açıkken **canlı kalır**
    (gizli, odaklanamaz): Keşfet'e OK anında, satırlar/görseller ve kaydırma konumu korunarak geri gelir
    (Build 16, M-09). Sağ içerik üstte (yüzen sekme çubuğunun altında) ve solda (sütunun önünde) kırpılır;
    Canlı TV listesi de üstte kırpılır.
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
  **Erken QuickStart (Build 16, IOS-06):** oynatma beklemeden izinliyse (kayıtlı yetki/deneme ya da TestFlight
  makbuzu) kanal, ortam (`AppEnvironment`) kurulur kurulmaz – hiçbir ekran çizilmeden – açılır ve oynatıcı ilk
  karede sunulur (önce Ana Sayfa çizilip `.task` beklenmez). İzin hemen belli değilse yukarıdaki yol (≤ 1,5 sn
  StoreKit beklemesi) aynen çalışır. Performans katmanı açılış dökümünü gösterir ("Start: pre … · env … · open … ·
  surface … · frame …", ms; `pre` = süreç başlangıcından uygulama `init`'ine, VLCKit çerçevesi yüklemesi dahil).

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
  kısım koyu; bloklar karonun altına kayar, metin görünür kalır. Metin bloğun içinde dizilir ve kırpılır;
  dar bloklar önce kanal adını, daha da darsa saati bırakır (kısa programlar komşu bloğun üstüne yazmaz).
* **Zaman penceresi saati izler:** dakikada bir "şimdi" çizgisi ve yayındaki bloklar güncellenir; şimdi açılış
  konumundan 30 dk ilerleyince pencere yeniden "şimdi" karonun hemen sağında olacak şekilde kayar (açık
  bırakılan rehber donmaz / boşalmaz). Canlı TV listesinin şimdi/sonra bilgisi de dakikada bir yenilenir.
* Üstte kategori çipleri (Tümü · Favoriler · kategoriler).
* **iPad (geniş) ve TV:** sağda panel — **"Şimdi yayında"** (seçili/odaklı kanalın programı, saat, açıklama,
  "▶ Oynat") + **"Bugün"** sıradaki programlar listesi (saat + süre). iPhone'da panel yok. TV'de odak gelecekteki
  / geçmiş bir bloktaysa panel o programı gösterir (**"Daha sonra"** / **"Daha önce"** başlığı, saat, açıklama;
  "Bugün" listesi onun ardından başlar). Liste kartın içinde kırpılır.
* **TV ★:** sekme çubuğundan/çiplerden ▼ ilk satırın şu an yayındaki bloğuna iner, "şimdi" çizgisi görünür kalır.
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
  sezon sayısı); kısa açıklama; "Tür: …" satırı – **sağlayıcının türü** (`get_vod_info` / `get_series_info`
  `genre`), kategori adı asla tür olarak gösterilmez; "Oyuncular: …", "Yönetmen: …" satırları; küçük eylem satırı:
  ☆ favori (tek dokunuş, §2) · ⟲ baştan oynat (devam varsa) · **Fragman** (YouTube kimliği/URL'si varsa; iOS'ta
  YouTube uygulaması/web, tvOS'ta gizli) · format pill ("MKV · HD"). Detay verileri (`item_details`) önbellekte
  tutulur, bir sonraki açılışta hemen görünür ve 6 saatten eskiyse arka planda yenilenir. Birincil eylem metni: "Oynat" / "Devam et (01:12:30)" /
  "Devam et S02E05".
* **Dizi:** sezonlar yatay **metin sekmeleri** ("Sezon 1 · Sezon 2 …", seçili `primary` alt çizgi);
  bölüm satırı = 16:9 küçük resim (ortada oynat ikonu, altta ilerleme) + "1. Başlık" + süre /
  izlendi ✓. ★ "Devam et S02E05" (son izlenen bölüm — konumu %5'in altında olsa da; bitmişse sonraki).
  Detay yığında açık kalırken bir bölüm oynatılınca birincil eylem ve bölüm ilerlemeleri hemen güncellenir
  (kütüphane değişince tek sorguyla yeniden okunur). Önbellekteki bölümler hemen gösterilir, 6 saatten eskiyse
  `get_series_info` arka planda yeniden istenir (haftalık yeni bölümler); hiç bölüm yokken istek başarısız olursa
  boş sayfa yerine hata kartı + **Tekrar dene**. Sağlayıcı başlığı numarayı zaten içeriyorsa ("Bölüm 3") numara
  iki kez yazılmaz; izlenmemiş bölümde boş ilerleme çizgisi yok. Format pill'i hiçbir zaman alt satıra kırılmaz.
  TV'de bölümler yatay 16:9 kart rafı.
* **Sonraki bölüm (Build 16, iOS + tvOS):** bölümün son 90 sn'sinde sonraki bölüm aranır (aynı sezonda sonraki
  numara, yoksa bir sonraki mevcut sezonun ilk bölümü; kayıtlı liste yoksa / son kayıtlı bölümse Xtream'de
  `get_series_info` tembel yüklenir ve liste kaydedilir). Son **30 sn**'de (jenerik) ya da bölüm bitince sağ altta kart:
  "Nächste Folge in 10 s" (geri sayım) · "S02E01 · Başlık" · **Jetzt abspielen** (★) · **Abbrechen**. 10 sn sonra
  kendiliğinden oynar (mevcut bölüm izlendi sayılır, sonraki kayıtlı konumundan devam eder). Jeneriğin dışına geri
  sarınca kart kaybolur, tekrar girince gelir; Abbrechen o bölüm için kartı kapatır (sonda da gelmez); Oynat/Duraklat
  geri sayımı durdurur (kart kalır). tvOS: kart açılınca odak "Jetzt abspielen"de, ◀▶ iki düğme arasında, Menü =
  Abbrechen. Ayarlar (üst düzey) → **"Nächste Folge automatisch abspielen"** (varsayılan açık, cihaza yerel); kapalıyken
  kart geri sayımsız gelir. Süresi bilinmeyen / ≤ 60 sn öğelerde kart yalnızca sonda. Uyku zamanlayıcısı "Bölüm sonunda"
  iken kart gelmez.

### 3.6 Favoriler ve arama
* Favoriler ekranı (Ana Sayfa "Favoriler" satırı → "Tümünü gör"): segment Kanallar · Filmler ·
  Diziler; kanallar TV Rehberi satırlarıyla, filmler/diziler poster grid'i. Kaldırma: posterdeki ★ (iOS) veya
  uzun bas menüsü (geri alınabilir, §2). Hesap varsa favori durumu senkronize edilir (son senkron saati gösterilir).
* **Sıralama ("Taşı"):** sağ üstte (TV: segmentin yanında) "Taşı" → seçili segment liste olur. iOS: tutamaçla
  sürükle-bırak; TV: öğeyi seç → ▲▼ ile taşı → tekrar seç bırakır (taşınırken diğer satırlar odak almaz).
  "Bitti" çıkar. Sıra cihazda saklanır, diğer kaynakların favorileri yerinde kalır.
* **Arama (Build 11, "profesyonel arama"):** tek alan (sistem klavyesinin mikrofonu / tvOS dikte çalışır, ayrı
  ses tanıma yok). Yazarken 250 ms birleştirme; sorgu ana iş parçacığı dışında çalışır, yeni harf eski sorguyu iptal
  eder. iOS'ta klavyedeki "Ara" tuşu sorguyu hemen çalıştırır, sonuçları kaydırmak klavyeyi kapatır.
  * **Alan boşken – Son aramalar:** kaynağa göre cihazda son 10 arama (en yeni üstte, büyük/küçük harf ve aksan
    farkı tekrar sayılmaz). Dokun = yeniden ara; iOS'ta sola kaydır veya uzun bas → Sil, başlıkta "Temizle";
    tvOS'ta liste (uzun bas → Sil, son satır "Temizle"). Sorgu yalnızca "Ara" tuşu, öneri / "Bunu mu demek
    istediniz" seçimi ya da bir sonucu açınca kaydedilir (yarım yazılmış sorgu kaydedilmez); yedeklenmez, kaynak
    silinince silinir. Hiç arama yoksa kısa açıklama.
  * **Öneriler (≥ 2 karakter, 120 ms):** en fazla 5 – başlık tamamlamaları, sonra en fazla 2 kişi adı. iOS'ta
    alanın altında satırlar (sonuçlar altında görünmeye devam eder), tvOS'ta klavyenin altındaki sistem satırı.
    Dokunmak sorguyu doldurur ve çalıştırır.
  * **Filtre çipleri** (en az iki türde sonuç varsa): Tümü · Kategoriler · Canlı · Filmler · Diziler · TV programları –
    yalnızca sonucu olan çipler (tvOS: yatay odak satırı). "Tümü" dışındaki çip o türün **tam listesini** gösterir
    (60'lık sayfalar, kaydırdıkça yüklenir): Canlı/Filmler/Diziler'de başlık ≫ kişi > açıklama sıralı tüm
    eşleşmeler (tam ifade önce), satırda kişi ya da açıklama alıntısı.
  * **"Tümü" bölümleri** (her biri tür başına en fazla 30, başlıkta **"Tümünü göster"** → o bölümün tam,
    sayfalı listesi; tvOS'ta rafın sonundaki kart):
    1. **Kategoriler** (en üstte, en fazla 12; en az 2 karakterlik sorguda): her kelime, grup kodu olmadan adın
       bir sözcüğünün **başı** olmalı (büyük/küçük harf ve aksan duyarsız; "dis" → "Disney+", "isney" değil);
       grup kodu ("tr") yalnızca yanında başka bir kelime varsa sayılır ("tr disney"). Film, dizi ve canlı
       kategorileri; kartta bayrak / kod rozeti, ad, tür ve içerik (canlıda kanal) sayısı. Gizlenen kategoriler
       gösterilmez. Film/dizi kategorisi → grid; canlı kategori → Canlı TV o kategoriyle açılır.
    2. Başlığa göre **Kanallar** kartları · **Filmler** · **Diziler** posterleri. Gizli kanallar gösterilmez.
    3. **Kişiler**: başlığı eşleşmeyen ama oyuncu/yönetmeni (Xtream `cast` / `director`) her kelimeyle
       eşleşen filmler ve diziler (önek eşleşmesi, ör. "Hasan" → Hasan Can Kaya'nın programı); posterin altında
       eşleşen kişinin adı (kelimeler farklı kişilerde eşleştiyse en fazla iki ad). Film oyuncuları listede yoksa
       film detayı bir kez açıldığında aranabilir olur. M3U kaynaklarında kişi bilgisi yoktur.
    4. **Açıklamada geçenler**: kelimeleri ne yalnız başlıkta ne yalnız kişilerde olan, açıklamada (ya da
       sütunlara dağılmış) geçen filmler/diziler. Geniş kart: poster, ad, tür · yıl ve **en fazla 2 satır
       alıntı** – eşleşen sözcükler kalın ve açık renkte, kesilen yerlerde "…" (Türkçe harf katlamalı:
       "kizilcik" "Kızılcık"ı işaretler). Tam ifade ("hasan can kaya") dağınık kelimelerden önce gelir. Film
       açıklaması listede yoksa detay bir kez açılınca aranabilir olur.
    5. **TV'de**: güncel kaynağın EPG'sinde başlığı her kelimeyle eşleşen programlar, şimdiden 2 saat önce
       bitenlerden 48 saat sonrasına kadar; gizli kanallar hariç. Sıra: şu an yayında olanlar ("Şimdi" rozeti +
       ilerleme), sonra yaklaşanlar (saat sırasıyla, "Bugün 20:45", "Yarın 18:00", sonra gün + saat), en
       sonda bitmiş olanlar – yalnızca kanalın catch-up arşivi varsa ve oynatılabiliyorsa (Xtream; 🔁 simgesi).
       Kart/satır: kanal logosu + adı, program adı, rozet/saat. Dokun/OK: yayında veya yaklaşan → o kanal
       oynar; bitmiş → arşivden tekrar oynar.
    6. **Az sonuç (< 5) – "Bunu mu demek istediniz: <düzeltme>"** çipi + **Benzer sonuçlar** rafı: bilinmeyen
       her kelime kaynağın başlık/kişi sözlüğündeki en yakın kelimeyle değiştirilir ("hasn can kya" → "hasan can
       kaya", "konuşanlr" → "konuşanlar"); çip düzeltilmiş sorguyu çalıştırır. Düzeltme sonuç vermezse ikisi de
       gösterilmez.
  * **1–2 harf:** yalnızca başlıklar (2 harften itibaren kategoriler); kişiler, açıklamalar, TV programları ve
    düzeltme 3 harften itibaren (yazarken akıcı kalır).
  * Türkçe "ı" ile "i" her yerde aynı aranır ("kizilcik" → "Kızılcık", "haberlerı" → "Haberleri").
  * **tvOS:** bölümler raf, kart/satır başına tek odak hedefi; çipler yatay odak satırı; geri tuşu kuralları §2.
  * Bir sonuç açılıp geri dönülünce sorgu, sonuçlar ve alan yerinde kalır (iOS 26: arama `.automatic`
    yerleşimde; çekmece yerleşiminde geri dönünce alan kayboluyordu).

### 3.7 Oynatıcı
* Tam ekran, sistem çubukları gizli, **ekran açık kalır** (Build 16: her iki motorda – oynarken, yüklenirken,
  tamponlarken ve yeniden bağlanırken `isIdleTimerDisabled`; duraklatınca, bitince, hatada ve oynatıcı kapanınca
  otomatik kilit / Apple TV ekran koruyucu yine çalışır. libVLC bunu kendisi yapmaz, B2).
* **iPhone dikey (Build 16, IOS-01):** üst satır = ✕ · numara · ad + şu anki program; araçlar ikinci satırda sağa
  dayalı (canlıda 7 araca kadar ekrana sığmıyordu); erişilebilirlik boyutlarında aralık daralır, gerekirse yatay
  kaydırılır. Yatay / iPad tek satır.
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
* **VOD:** ◀▶ 10 sn ileri/geri (TV: önce hedef gösterilir, basılı tutunca hızlanır), OK oynat/duraklat. Kaldığı yerden
  devam: açılışta otomatik devam + "Baştan başla" kısa düğmesi (5 sn görünür, katmandan
  bağımsız; kayıtlı konum ≥ 10 sn ve < %95 ise).
  * **Mobil (iOS):** katmanın ortasında büyük taşıma satırı: ⟲10 · oynat/duraklat (64 pt) ·
    10⟳ (canlıda yalnızca oynat/duraklat). Görüntüye çift dokunma: sol üçte bir −10 sn, sağ
    üçte bir +10 sn, kısa "−10 sn"/"+10 sn" halkası (ard arda çift dokunmalar toplanır, katman
    açılıp kapanmaz); tek dokunma katmanı açar/kapatır; senkron paneli açıkken tek veya (orta üçte bir / canlı) çift
    dokunma önce paneli kapatır, katman açılmaz. Altta sürüklenebilir zaman çizgisi
    (44 pt dokunma yüksekliği): sürüklerken balonda hedef zaman + sıçrama ("01:30 · +1:26",
    sürüklemenin başladığı konuma göre; güvenli durumda önizleme karesiyle, TV ile aynı kural), gelen zaman
    güncellemeleri başparmağı oynatmaz, bırakınca atlar; balon bırakıştan sonra 1,5 sn iniş noktasında kalır.
    Süre bilinmiyorsa çizgi yalnızca gösterir (sürükleme yok), süre "--:--". **Build 16 (IOS-02):** bitmiş bir
    VOD'da (VLCKit sona atlamış olsa da) sarma/çift dokunma hedeften **oynatır**: libVLC biten girdide `time`'ı yok
    saydığından VLCKit öğeyi hedef konumdan yeniden açar; AVPlayer atlar ve oynatır (son 1 sn'ye sarmak hariç).
  * **TV (tvOS) – önizlemeli sarma (YouTube gibi, Build 14):** ◀▶ hemen atlamaz; oynatma sürerken zaman
    çizgisinde bir **hedef** işaretini taşır. Çizgi kalınlaşır, işaretin üstünde büyük balon hedef zamanı ve
    sıçramayı gösterir ("1:23:40 · +2:30", sarmanın başladığı konuma göre); sol etiket hedef zamanı, sağ etiket
    hedeften kalan süreyi ("−12:34") gösterir. Basış 10 sn; basılı tutunca 0,3 sn'de bir tekrar ve adım büyür:
    10 sn → 30 sn (1 sn) → 60 sn (3 sn) → 120 sn (5 sn); hedef [0, süre] içinde kalır (süre bilinmiyorsa üst
    sınır yok, çizgide işaret yok). **Gerçek atlama bir kez olur:** OK'de ya da 0,8 sn hiç girdi olmayınca (Build 16, B-19: bu kendiliğinden atlama sondan en az 10 sn önce durur – basılı ▶ filmi bitirip "izlendi" yapmaz; sona yalnızca OK götürür);
    **Menü iptal eder** (hedef geri döner, atlama yok, katman açık kalır). **Oynat/Duraklat** önce hedefe atlar,
    sonra her zamanki gibi duraklatır/sürdürür (duraklatılmışken hedefte oynatır). ▲ önce hedefe atlar, sonra
    üst satıra geçer. Önizleme sürerken katman kendiliğinden kapanmaz. **Siri Remote dokunmatik yüzeyi:**
    yatay kaydırma hedefi parmakla birlikte taşır (tam kaydırma ≈ max(5 dk, sürenin %10'u), momentum yok;
    parmak yüzeyde durdukça atlanmaz, kaldırınca 0,8 sn sonra ya da tıklamayla atlar); dikey kaydırmalar
    odak motorunda kalır; kanal/senkron paneli, bilgi kartı veya üst satır kullanılırken kapalıdır.
    **Önizleme karesi** (balonda ~320 px) yalnızca güvenliyse: yayın AVPlayer'da (VLCKit değil), ilerlemeli
    VOD dosyası (MP4; HLS'de görüntü üretici yok) ve kaynak `max_connections ≤ 1` (veya bilinmeyen) bir Xtream
    hesabı değil; M3U/ham URL'de Xtream biçimli adres (`/live|movie|series/U/P/id`, `ZapPrefetcher.isXtreamShaped`)
    bilinmeyen hesap sayılır → kare yok. Kare `AVAssetImageGenerator` ile oynayan URL'den (aynı User-Agent /
    Referer başlıkları) alınır: 300 ms'de en fazla bir istek, eski istek iptal, 10 sn'lik dilim başına önbellek,
    3 hata sonrası o yayın için kapanır. Aksi halde balon yalnızca zamanı gösterir; ikinci bağlantı açılmaz.
    Canlı yayında motor bir DVR/catch-up penceresi bildirmediği için önizleme yok (◀▶ eskisi gibi katmanı açar).
    Performans katmanı motorun atlama sayısını gösterir ("Atlama: n"). Katman
    görünürken odak oynat/duraklat'tadır: OK oynat/duraklat (önizleme varken: atla), ◀▶ hedefi taşır (odak yana kaymaz);
    ▲ üst satıra (kapat + araçlar, odak kapat'ta) geçer, ▼ geri döner. Üst satırda ◀▶ araçlar
    arasında gezinir (kapat · Ses · Altyazı · Oran · Senkronu düzelt · Uyku zamanlayıcısı · ⭐ · canlıda Kanal listesi ·
    Son izlenen kanal; uçlarda durur; Build 16: odaktaki aracın adı simgenin altında küçük bir etiketle görünür, U-04); üst satır (ve oradan açılan menü) kullanılırken katman 3 sn sonra
    kapanmaz, ▼ oynat/duraklat'a döner ve sayacı yeniden başlatır. Canlı: katman açıkken ▲ aynı üst
    satıra girer (katman kapalıyken ▲ = kanal bilgi kartı, değişmedi). Katman kapalıyken OK
    VOD'da duraklatır/sürdürür ve katmanı açar; **canlıda kanal panelini açar** (katman: ◀▶ veya
    Oynat/Duraklat tuşu). Tam tuş haritası aşağıdaki tabloda.
  * Katman 3 sn sonra yalnızca oynarken kaybolur: duraklatılmışken, çizgi sürüklenirken / TV'de hedef gösterilirken,
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
  | VOD, katman kapalı | Duraklat/sürdür + katman | Katmanı aç | Katmanı aç | Hedef −/+10 sn (basılı: 30/60/120 sn) + katman | Duraklat/sürdür + katman | Oynatıcıdan çık | – |
  | VOD, katman açık | Duraklat/sürdür | Üst satır | – | Hedef −/+10 sn (basılı: hızlanır) | Duraklat/sürdür | Katmanı kapat | – |
  | VOD, hedef gösteriliyor (balon) | Hedefe atla | Hedefe atla + üst satır | – | Hedefi taşı (basılı: hızlanır; dokunmatik: kaydır) | Hedefe atla + duraklat/sürdür | İptal (atlama yok) | – |

  Hedef gösterilirken 0,8 sn girdi yoksa hedefe atlanır (tek atlama).

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
  satırlık kontroller). İki satır: "Bu kanal/içerik" (bu içerik için kaydedilir; −2000…+2000 ms, 50 ms adım) ve
  "VLC kalibrasyonu (bu cihaz)" (Build 16, −500…+500 ms, 10 ms adım; yalnızca VLCKit'te oynayan her yayına
  eklenir, motoru değiştirmez – böylece izlerken ince ayar yapılabilir); değer yönüyle gösterilir: "+150 ms · ses daha geç",
  "−100 ms · ses daha erken"; her değişiklik canlı uygulanır (kanal değişimi 400 ms beklerken yapılan
  değişiklik hedef kanala kaydedilir ve o kanal açılınca uygulanır, terk edilen kanala asla). Panel açıkken
  katman hiçbir yoldan (dokunma, Oynat/Duraklat, VoiceOver) üstüne açılmaz. Altında yön ipucu ("Ses görüntüden önce
  mi geliyor? + kullan…"). iOS: kaydırıcı + −/+ düğmeleri, kapat düğmesi; tvOS: her satır tek
  odaklanabilir kontrol, ◀▶ değiştirir, art arda/basılı tutunca hızlanır (50 → 100 → 250 ms),
  Menü paneli kapatır. Motor AVPlayer ise not: "Gecikme ayarlanınca bu kanal VLC motoruyla
  oynatılır"; VLCKit oynatamazsa yayın gecikmesiz AVPlayer ile sürer ve "Senkron bu yayında
  uygulanamadı" notu (4 sn) görünür. Katmanın araçlarında "Senkronu düzelt" düğmesi
  (`arrow.triangle.2.circlepath`): canlıyı canlı uçtan, VOD'u mevcut konumdan yeniden açar.
* **Uyku zamanlayıcısı (Build 16):** araçlarda "Senkronu düzelt"ten sonra `moon.zzz` menüsü: Kapalı · 15 · 30 · 60 ·
  90 dk · (VOD) "Bölüm sonunda" / "Film sonunda". Çalışırken sağ üstte "Schlaf-Timer: 14:32" hapı (katmanla birlikte;
  son dakikada her zaman). Süre dolunca ses 5 sn'de kısılır, sonra VOD duraklar (konum kaydedilir), canlı durur
  (Oynat canlı uçtan yeniden açar); "Schlaf-Timer: Wiedergabe gestoppt" notu (4 sn); ekran kilidi / tvOS uyku tekrar
  serbest. Oynatıcı kapanınca zamanlayıcı iptal.
* **Altyazı stili ve gecikmesi (Build 16):** altyazı menüsünde izlerin altında **Stil** (Boyut: Klein/Mittel/Groß/
  Sehr groß · Farbe: Weiß/Gelb · Hintergrund: Ohne/Halbtransparent/Deckend; cihaza yerel kalıcı) ve yalnızca VLCKit'te
  **Verzögerung** (−2,0 … +2,0 sn hazır değerler, + = altyazı daha geç; öğe başına, yeni öğede 0). AVPlayer: stil
  `AVPlayerItem.textStyleRules` ile anında; altyazı gecikmesi yok → seçenek gizli. VLCKit: libVLC freetype seçenekleri
  (`freetype-rel-fontsize` 20/16/12/9, `freetype-color`, `freetype-background-opacity` 0/140/255) metin oluşturucu
  başlarken okunur → altyazı açıkken stil değişince yayın yerinde yeniden açılır (VOD aynı konum, seçili altyazı dili
  korunur); kalın/kontur libVLC varsayılanı. Gecikme `currentVideoSubTitleDelay` (µs).
  Panelin son satırı **"Senkronu sıfırla"** (Apple, Build 15) ve yanında **"Ses senkronunu ayarla"** (Build 16,
  test klibiyle kalibrasyon ekranı, §3.9; tvOS: sıfırla'dan ▶): **tüm** kanal/içerik gecikmeleri 0 olur (VLC
  kalibrasyonu kalır), yanında kısa onay "Tüm ses gecikmeleri 0 yapıldı" (2,5 sn). VLCKit'te oynayan yayın
  içerik gecikmesini hemen 0 alır; Otomatik yönlendirme bir sonraki açılıştan itibaren VLC'yi zorlamaz (CONTRACT §6.1).
  tvOS: kalibrasyon satırından ▼ → düğme, ▲ geri. **Oynatıcı motoru = Apple (AVPlayer)** iken panel
  adım kontrolleri yerine tek satır gösterir: "Oynatıcı motoru Apple (AVPlayer): ses gecikmesi kapalı…"
  (sıfırla düğmesi kalır, tvOS'ta odak onda).
* **Bağlantı koparsa:** katmanda "Yeniden bağlanılıyor… (2/5)" + son kare donuk; 1-2-4-8-15 sn
  aralıklarla 5 deneme, ardından hata kartı (Tekrar dene ★ / Kanal listesi / Geri).
  Canlıda "canlı pencerenin gerisinde" hatası sessizce canlı uca atlar.
* **Kilit:** deneme bittiyse oynatıcı açılmaz → Paywall (§3.8) açılır, geri tuşu listeye döner.
  (Diğer ekranlara referans: göz atma §3.2, Canlı TV §3.3, Rehber §3.4, detay §3.5.)
* Kaynaklar: ekran kapanınca / uygulama arka plana geçince (`.background`) oynatıcı **serbest bırakılır**
  (pozisyon kaydedilir). **Build 16 (B4):** `.inactive` (Denetim Merkezi, bildirim perdesi, arama bandı, Siri, iPad
  Slide Over, tvOS Denetim Merkezi) oynatıcıyı bırakmaz – canlı yeniden başlamaz, `max_connections = 1`'e takılmaz;
  gerçek ses kesintileri (arama sesi alır) `AVAudioSession` kesintisiyle duraklatır. Arka planda ses oynatma yok (varsayım).

### 3.8 Deneme durumu ve satın alma (Paywall)
* Başlık: "{app} Premium – tek seferlik satın alma", madde listesi (sınırsız oynatma, tüm
  cihazlarda aynı mağaza hesabıyla, abonelik yok).
* Durum kartı: *Deneme aktif – 3 gün 4 saat kaldı* / *Deneme sona erdi* / *Satın alındı ✓* /
  *Ödeme bekleniyor* (bekleyen işlem: "Ödeme onaylandığında erişim otomatik açılır").
* **★ Satın al – ₺xx,xx** (mağaza yerel fiyatı) · **Satın alımları geri yükle** · Kullanım
  koşulları · Gizlilik.
* Kullanım koşulları ve Gizlilik **bağlantıdır** (iOS: `Link`, URL'ler `TERMS_URL` / `PRIVACY_URL` –
  varsayılan hasi-elektronic.de/agb ve /datenschutz); tvOS'ta düğme → QR kod + okunur URL.
* Hesap bölümü (isteğe bağlı, yalnızca hesaplar etkinken): "Farklı platformda (Apple ↔ Google) satın aldıysanız
  hesabınıza giriş yapın".
* Satın alma sonuçları: başarı (konfeti yok, sade onay), iptal (sessiz), hata (mağaza mesajı),
  bekliyor (banner), zaten sahip (geri yükleme yapar).

### 3.9 Ayarlar ve kaynak yönetimi
**Üst düzey yalnızca kullanıcının sık değiştirdikleri** (tek grup, kaydırmasız):
**Kaynaklar** (sayı ile → Kaynaklar ekranı) · **Uygulama dili** · **Ses dili** · **Altyazı dili** ·
**Hızlı başlat** · **Ses senkronunu ayarla** (Build 16; mevcut VLC kalibrasyonu değeriyle, ör. "−120 ms" → kalibrasyon
ekranı; TV'deki dudak senkronu düzeltmesi, bu yüzden üstte – Gelişmiş'te de aynı satır); alt bilgide Hızlı başlat açıklaması.
* **Ses senkronunu ayarla (VLC kalibrasyonu, Build 16, iOS + tvOS):** uygulamaya gömülü 10 sn'lik test klibi
  (`avsync-test.mkv`, 640×360, 25 fps, H.264 + AAC): **her tam saniyede tek bir tam beyaz kare ("BEEP") ve tam aynı
  sunum zamanında 40 ms'lik 1 kHz bip**; aradaki karelerde büyük "s.kk" zaman kodu, kare numarası, 25 hücrelik sıra
  (o anki kare yanar) ve saniyede bir soldan sağa kayan turuncu işaret (flaşı önceden kestirmek için). Klip **VLCKit'te
  döngüde** oynar; altında tek kontrol "VLC kalibrasyonu (bu cihaz)" −500…+500 ms, 10 ms adım (iOS: kaydırıcı + −/+;
  tvOS: tek odaklanabilir satır, ◀▶, art arda/basılı tutunca 10 → 20 → 50 ms) – değer anında uygulanır. Kullanıcı bipi
  flaşla aynı anda duyana kadar ayarlar (bip flaştan sonra → −). Düğmeler: **Referans (Apple)** (aynı klip MP4 olarak
  AVPlayer'da, kalibrasyonsuz; tekrar basınca "Test (VLC)") · **Kaydet** (yanında "Kaydedildi: −120 ms", 2,5 sn).
  Değer cihaza yereldir, VLCKit'in oynattığı **her** yayına eklenir (içerik gecikmesi + otomatik gecikme terimiyle),
  motoru asla değiştirmez (AVPlayer içeriği AVPlayer'da kalır). Eski "Ses gecikmesi (TV/soundbar)" değeri bir kez
  buraya taşınır. Senkron panelinden açılınca yayın bu sırada serbest bırakılır, ekran kapanınca yeniden açılır (VOD
  aynı konumdan, canlı canlı uçtan); tvOS'ta Menü kapatır. Performans katmanı "VLC-Kalibrierung: N ms" satırını gösterir. Altında **Gelişmiş ve tanılama** → geri kalan her
şey; son satır **Hakkında** (Apple, Build 14).
* **iCloud (Apple, Build 17, ARCHITECTURE §6.1):** üst düzey grubun altında kendi bölümü: **"iCloud ile eşitle"**
  anahtarı (iCloud hesabı varsa varsayılan açık) + durum: "Güncel · 12:30" / "Eşitleniyor…" / "Kapalı – … bu cihazda
  kalır" / "iCloud hesabı yok – …" / "iCloud alanı dolu – yalnızca en son izleme durumu eşitlenir". Altında gizlilik
  notu (ne eşitlenir, şifreler yalnızca iCloud Anahtar Zinciri'nde, ses gecikmeleri cihazda kalır, veriler kullanıcının
  iCloud'unda – bizim erişimimiz yok). iOS: durum ve not bölüm alt bilgisinde; tvOS (liste alt bilgisi göstermez):
  durum anahtarın ikinci satırı (tek odaklanabilir satır), not ayrı odaklanabilir metin satırı.
  Başka cihazdan gelen ama gizli bilgisi henüz iCloud Anahtar Zinciri'nden gelmemiş kaynak: Kaynaklar listesinde
  hata değil "iCloud Anahtar Zinciri bekleniyor…" (anahtar simgesi, gri), detayda açıklama ("başka cihazda eklendi …
  birkaç dakika sürebilir, iCloud Anahtar Zinciri açık mı?"). Hakkında ekranında yasal bağlantıların altında tek
  satır gizlilik notu.
* **Hakkında ekranı (iOS/iPadOS/tvOS):** uygulama simgesi + adı (`CFBundleDisplayName`) + "Sürüm 1.0.0 (Derleme N)"
  (paketten okunur) · **Geliştiren:** Hasi Elektronic logosu (`HasiLogo`, iOS ≈200 pt, tvOS ≈360 pt), "Hamdi
  Güncavdı" (Hasi mavisi #3ABADF – yalnızca bu blokta), Hasi Elektronic, Grabenstraße 18, 71665 Vaihingen/Enz,
  web sitesi hasi-elektronic.de ve e-posta info@hasi-elektronic.de (iOS: bağlantı / mailto; tvOS: düz metin,
  tarayıcı yok) · **Açık kaynak lisansları** satırı (VLCKit LGPL-2.1 → lisans ekranı) · alt bilgi
  "© 2026 Hasi Elektronic". tvOS: satır başına tek odaklanabilir öğe, liste odakla kayar.
* **Kaynaklar ekranı:** liste (ad, tür, host, son yenileme, durum rozeti, hesap bitiş tarihi, birden çok
  kaynakta aktif olana "Aktif" ✓) – sıralama iOS'ta "Sırala" ile sürükle-bırak, tvOS'ta detayda **Yukarı taşı /
  Aşağı taşı** →
  detay: durum (katalog sayıları yerel sayı biçimiyle; **EPG durumu**: "TV rehberi: N program · tarih" veya hata
  `err_epg_failed` – EPG hatası artık sessiz değil) · Yenile · (aktif değilse) Bu kaynağı kullan · **Düzenle**
  (ekleme formu doldurulmuş olarak: ad, sunucu/kullanıcı/şifre veya M3U URL, EPG URL, User-Agent; Kaydet yeniden
  doğrular ve yeniler, hata olursa eski bilgiler aynen kalır; sağlayıcının host/kullanıcı adı değişirse favori ve
  izleme ilerlemesi yeni parmak izine taşınır) · **EPG URL** (yalnızca host + yol, kimlik bilgisi asla; boşsa
  "Varsayılan: …" – Xtream `xmltv.php`, M3U `x-tvg-url`) · EPG saat kaydırma (seçici: −12..+12 saat, 30 dk
  adım; iOS'ta ek olarak ±15 dk düğmeleri, VoiceOver etiketli) · Otomatik yenileme (Kapalı/6/12/24 saat) ·
  Sil (onaylı). "Kaynak ekle": **+ M3U** · **+ Xtream** · (TV, yalnızca hesaplar etkinken) **Telefonla ekle (QR)**.
* **Yenileme zamanlaması:** otomatik yenileme soğuk açılışta **ve uygulama ön plana döndüğünde** (en fazla
  dakikada bir kontrol, oynatma başlarken beklenir) vadesi gelmiş kaynaklarda çalışır; katalog vadesi gelmemiş
  kaynaklarda saklı rehber 24 saatten kısa sürede bitiyorsa EPG ayrıca (kaynak başına en fazla 6 saatte bir)
  yenilenir.
* **Uygulama dili:** Sistem / Deutsch / Türkçe / English – dil adları her zaman kendi dilinde. Arayüz üç
  dilde tamdır (EN/TR/DE); "Sistem" cihaz dilini izler, desteklenmeyen dillerde English. Dil değişince
  arayüz hemen yeniden çizilir; tarih/saat seçilen dile göre biçimlenir (DE/TR: 24 saat).
* **Gelişmiş ve tanılama** ekranı:
  * **Oynatma:** görüntü oranı varsayılanı, canlı yayın formatı (Android: Otomatik/TS/HLS), arabellek
    (Normal/Büyük). (Apple: işlevsiz "TV'de önizleme" anahtarı Build 16'da kaldırıldı.)
  * **Görünüm:** EPG saat dilimi – "Cihaz" veya aranabilir tüm IANA saat dilimleri listesi (UTC farkıyla);
    24 saat biçimi – seçilmemişse arayüz dilinin yerel ayarını izler (DE/TR 24 saat, EN-US 12 saat).
  * **Ses / altyazı dili tercihi:** tüm ISO 639-1 dilleri (önce TR, DE, EN, AR, KU, FR, ES, IT, RU, PL, NL,
    sonra arayüz dilindeki ada göre).
  * **Hesap (opsiyonel, yalnızca `ACCOUNTS_ENABLED` + gerçek backend):** e-posta ile giriş (kod), TV'de
    "Telefonla giriş yap" (cihaz kodu + QR), senkronizasyon durumu, çıkış, **hesabı sil**.
  * **Satın alma:** durum, geri yükle.
  * **Gelişmiş** grubunun başında (Apple, Build 15 – A/V senkron A/B testi): **Oynatıcı motoru**
    Otomatik (varsayılan) / Apple (AVPlayer) / VLC – cihaza özel, bir sonraki açılıştan geçerli; oynatıcı
    açıksa mevcut yayın hemen yeniden açılır (CONTRACT §6.1 kural −1). Apple: hiçbir zaman VLCKit, ses
    gecikmesi yok sayılır; Xtream canlı her zaman `.m3u8` (hesap yalnızca `ts` listelese de denenir, ilk
    kareden önce hata → "Sağlayıcınızdan HLS isteyin – veya motoru Otomatik yapın"); AVPlayer'ın açamadığı
    içerik (MKV, AVI…) → format hatası + "Bu içerik VLC motoruna ihtiyaç duyuyor – Otomatik yapın". VLC: her şey
    VLCKit ile (HLS ikiz denemesi yok). Hemen altında **Senkronu sıfırla** (panel ile aynı; kısa onay aynı satırın
    altında ikinci satır olarak, kesilmeden, 2,5 sn). Alt bilgide açıklama. Performans katmanının ilk satırı kalın: "Motor: AVPlayer" / "Motor: VLCKit"
    (+ "· Ayarlar'da zorunlu"), ses gecikmesi satırı "Ses gecikmesi: N ms (cihaz M, kanal K)" (N = motorun
    uyguladığı).
  * **Tanılama:** Format testi (`stream-samples.json`; Apple'da her örneğin motoru – AVPlayer/VLCKit –
    gösterilir ve `expect.apple` ile karşılaştırılır), performans katmanı, önbelleği temizle (görsel / EPG),
    uygulama sürümü, **Açık kaynak lisansları** ekranı (VLCKit LGPL-2.1 bildirimi + kaynak bağlantısı +
    tam metin, diğer bileşenler), **Gizlilik politikası** ve **Kullanım koşulları** bağlantıları (iOS: tarayıcı;
    tvOS: QR + URL; Hakkında ekranında da).
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
* Dinamik yazı boyutu (mobil) desteklenir; TV'de sabit büyük ölçek. Erişilebilirlik boyutlarında (AX) hero
  eylemleri alt alta dizilir (tam genişlik "▶" pill'i, altında Favori · Bilgi); Canlı TV satırında kanal adı
  kendi satırlarında, saat başlığın üstünde, program başlığı en çok 3 satır (Build 16).
* iPhone arama: sonuçlar alttaki yüzen arama kapsülünün üstüne kaydırılabilir (yatayda ilk satırı örtmez).
