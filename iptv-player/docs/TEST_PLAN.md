# Test ve Doğrulama Planı

İki katman: **(A) otomatik testler** (bu depoda, Linux'ta çalışır; ortak vektörler) ve
**(B) gerçek cihaz testleri** (telefon + TV, manuel kontrol listesi). Sonuçlar `docs/STATUS.md`'de.

## A. Otomatik testler

| Komut | Kapsam |
|---|---|
| `cd backend && npm test` | Lisans senkronu, deneme anlık görüntüsü, Google/Apple doğrulama (mock), iade webhook'ları, cron, hesap/OTP, cihaz-kodu girişi, senkron LWW, eşleştirme, admin, redaksiyon, token vektörleri |
| `gradle -p android/core test` | Kotlin çekirdek: tüm `spec/test-vectors` + ağ hata eşleme (MockWebServer), büyük liste performansı |
| `docker run … swift:6.1-jammy swift test` (`apple/IPTVCore`) | Swift çekirdek: tüm vektörler + hata eşleme, büyük liste performansı |

### A2. Build 7 – performans ve UX programı (Apple fazı)

Komutlar (macOS, simülatör): `cd apple/IPTVCore && swift test` · `cd apple/IPTVKit && swift test` ·
`cd apple && xcodegen generate && xcodebuild test -project NovaPlayer.xcodeproj -scheme NovaPlayer-iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
(tvOS: `-scheme NovaPlayer-tvOS -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'`). UI testleri iki yerel sunucu ister:
`python3 -m http.server 8765` (demo.m3u + epg.xml; `TEST_RUNNER_SEED_M3U=http://localhost:8765/redesign/demo.m3u`) ve Range destekli
8766 sunucusu (`vlc-live.m3u`, `vlc-movie.m3u`, `vod-movie.m3u`; yoksa VLCKit/VOD testleri `XCTSkip`). Ayrıntı: `apple/README.md`.

| Özellik | Birim testleri (`apple/IPTVKit/Tests/IPTVKitTests`) | UI testleri (`apple/UITests/{iOS,tvOS}`) |
|---|---|---|
| `PerfTrace` + performans katmanı | `PerfTraceTests` (zap/soğuk açılış aralıkları, isteksiz ilk kare yok sayılır) | `-perfOverlay` ile motor etiketi okunur (`IOSAudioSyncTests`, `TVAudioSyncTests`, `*VLCPlaybackTests`) |
| Canlı başlangıç ayarı (tampon, ilk 3 sn, ilk çeşit sınırı) | `LiveStartTuningTests` | `IOSPlaybackRobustnessTests/testLiveKeepsPlayingWithoutUserInput` ve `TVPlaybackRobustnessTests` (canlı kendiliğinden duraklamaz) |
| Komşu kanal ön ısıtma (`ZapPrefetcher`) | `ZapPrefetcherTests` (bayt/eşzamanlılık sınırı, TTL, hücresel kapalı, iptal) | – (ağ zamanlamasına bağlı, yalnızca birim) |
| Hızlı başlat (`QuickStart`) | `QuickStartTests` | `IOSPersistentModeTests/testQuickStartReopensLastChannel` (5 sn içinde oynatıcı) |
| Yapışkan duraklat/sürdür/sarma, ses oturumu | `AudioSessionTests`, `PlayerProgressTests`, `PlaybackRobustnessTests` | `IOSPlayerControlsTests`, `TVPlayerControlsTests/testVODRemoteSeekAndPlayPause`, `*PlaybackRobustnessTests` |
| İzlemeye devam et | `PlayerProgressTests` (`testResumePolicy`, `testResumeRequestStartsEngineAtSavedPosition`) | `IOSFlowTests/testRedesignScreens` (`-uiSeedLibrary` ile devam satırı) |
| EPG indeksi, şimdi/sonraki, ızgara | `CatalogPerformanceTests` (`testNowNextUnderBudget`, `testEpgGridLoadUnderBudget`, `testEpgQueriesUseChannelIndex`), `EpgRepositoryTests` | `IOSLiveListTests`, `TVFlowTests/testGuideFocusAndPanel` |
| Favori denetleyicisi (tek dokunuş ⭐ + geri al, yerel sıra) | `FavoritesControllerTests`, `FavoritesViewModelTests` | `IOSFlowTests/testOneTapFavoriteFromLiveCard`, `testFavoriteFromPlayerOverlay`, `IOSFavoritesReorderTests`, `TVFlowTests/testUpArrowInfoCardFavorite` |
| Tür başına arama (kanal/film/dizi) | `CatalogSearchTests`, `SearchViewModelTests`, `CatalogPerformanceTests/testSearchUnderBudget` | `IOSSearchTests` |
| Dizi/film çoklu kategori (`item_categories`) | `CategoryMembershipTests` | `IOSSeriesCategoriesTests`, `TVSeriesCategoriesTests` |
| Ses gecikmesi (kanal başına + cihaz), Senkronu düzelt, etkin ≠ 0 → VLCKit | `AudioDelayTests` | `IOSAudioSyncTests`, `TVAudioSyncTests` (4 test) |
| Oynatıcı içi kanal paneli | `NumberZapTests/testPanelOpenUnderBudget` (50 000 kanal), `testZapWithNewListReplacesZapList` | `IOSThreeTapTests/testInPlayerChannelPanel`, `TVChannelPanelTests` |
| TV rakam tuşları (kaynağın tamamında numara) | `NumberZapTests` (toplama/zaman aşımı, numaralı/numarasız kaynak, indeks) | – (Siri Remote'ta rakam yok; yalnızca birim) |
| Canlı TV liste görünümü + bilgi paneli | – | `IOSLiveListTests`, `TVLiveListTests` |
| Sade ayarlar, 3 dokunuş yolları, başlık sekmeleri | – | `IOSThreeTapTests`, `IOSHeaderTests` |
| Şema göçleri v2–v5 | `DatabaseMigrationTests` (v1→v2 veri korunur, idempotent, v2 üyelik doldurma, v4 kullanılmayan indeksler) | – |
| 50 000 kanal bütçeleri | `CatalogPerformanceTests` (liste, derin sayfa, arama, şimdi/sonraki, ızgara) | – |

### İstenen senaryoların eşlemesi

| Senaryo | Otomatik (çekirdek/backend) | Cihazda (B bölümü) |
|---|---|---|
| Geçerli ve bozuk M3U | `m3u/*` vektörleri (geçerli, BOM+CRLF, başlıksız, kısmen bozuk, HTML, boş) | B1 |
| Başarılı/başarısız Xtream | `xtream/auth*` (OK, hatalı bilgi, süresi dolmuş, tarihi geçmiş, banlı, HTML, 401/403/404/5xx), ağ hataları (zaman aşımı, DNS, reddedildi, iptal) | B2 |
| EPG zaman eşleşmesi | `xmltv/time-parsing`, `epg_basic` (+0300, −0500, ofsetsiz=UTC, kaydırma), timeshift sunucu saat dilimi | B3 |
| Yayın kesilmesi / yeniden bağlantı | `ReconnectPolicy` durum makinesi | B4 |
| Büyük listelerde gezinme | 200 000 girdilik akış ayrıştırma testi (süre + bellek) | B5 |
| TV kumandasıyla temel akışlar | – | B6 |
| Demo başlangıcı ve bitişi | `access-policy`, `trusted-clock`, backend deneme anlık görüntüsü + admin uzatma | B7 |
| Satın alma, bekleyen, geri yükleme, iade | `access-policy` (pending/revoked), backend Google/Apple doğrulama + RTDN/ASSN iade/iade geri alma | B8 |
| Kapanıp açılınca izleme ilerlemesi | `sync` LWW + devam-et seçim kuralları | B9 |

## B. Gerçek cihaz kontrol listesi

Önerilen cihazlar: Android telefon (Android 14+), Android TV / Google TV (Chromecast with
Google TV veya Android 9+ kutu), iPhone (iOS 17+), Apple TV 4K (tvOS 17+).

**B1 – M3U:** geçerli liste ekle (kanal/grup/logo görünür) · EPG URL'si başlıktan önerilir ·
HTML döndüren URL → "Geçersiz liste" · 404 → "Liste bulunamadı" · boş liste → "Liste boş" ·
iki kaynak ekle, kaynak seçici çalışır · Yenile → favoriler korunur.

**B2 – Xtream:** doğru bilgiler → kanal/film/dizi sayıları + bitiş tarihi · yanlış şifre →
"Kullanıcı adı veya şifre hatalı" · süresi dolmuş hesap → tarihli mesaj · yanlış port → "Sunucuya
ulaşılamıyor" · uçak modu → "İnternet bağlantısı yok" · bağlanırken geri tuşu → istek iptal.

**B3 – EPG:** cihaz saat dilimi değiştir (ör. Europe/Berlin ↔ Europe/Istanbul) → saatler
kayar, "şimdi" doğru · kaynak başına ±1 saat kaydırma · catch-up kanalında geçmiş program →
"Baştan izle" (Xtream timeshift).

**B4 – Kopma:** canlı yayında Wi-Fi kapat 10 sn → "Yeniden bağlanılıyor (n/5)" → aç → devam ·
60 sn kapalı → hata kartı + Tekrar dene · VOD'da kopma → kaldığı yerden devam.

**B5 – Büyük liste:** ≥ 50 000 kanallı liste: ekleme sırasında UI donmaz, ilerleme sayacı artar ·
liste kaydırma akıcı (TV'de D-pad basılı tutma) · arama < 300 ms.

**B6 – TV kumandası (Android TV + Apple TV Siri Remote):** tüm ekranlara yalnızca D-pad/OK/Geri
ile ulaş · odak her zaman görünür · Geri kuralları (SCREENS §2) · oynatıcıda ▲▼ kanal değiştir,
rakam tuşları (Android TV), ◀▶ sarma · ses/altyazı/oran menüsü kumandayla · QR eşleştirme: telefonla
kaynak ekle → TV otomatik bağlanır · telefonla hesap girişi (cihaz kodu).

**B7 – Demo:** ilk açılış → deneme bilgisi ve fiyat görünür → başlat → çip "7 gün kaldı" ·
admin panelinde süreyi 1 güne indir → mevcut deneme değişmez, yeni cihazda 1 gün · cihaz saatini
ileri/geri al → kalan süre değişmez · admin ile denemeyi −8 gün uzat (bitir) → oynatma kilitli,
kaynak/ayar/satın alma erişilebilir · Apple: iPhone'da başlatılan deneme Apple TV'de görünür.

**B8 – Satın alma:** Google test kartı "always approves" → anında açılır; telefon ve TV'de aynı
hesap → TV'de de açık · "slow test card" → "Ödeme bekleniyor" → birkaç dakika sonra otomatik açılır ·
"declines" → hata mesajı · uygulamayı sil/kur → Geri yükle · Play Console'dan iade → bir sonraki
açılışta kilit · Apple: StoreKit config ile Ask to Buy (bekleyen) → onay → açılır; Xcode'dan Refund
→ kilit; sandbox'ta geri yükleme · Hesapla Apple↔Google: Android'de satın al (girişli) → iOS'ta aynı
hesapla giriş → açık.

**B9 – İlerleme:** filmi 10. dakikada kapat (uygulamayı zorla durdur) → yeniden aç → "Devam et
(00:10:xx)" · bölüm %95 izlenince ✓ ve sonraki bölüm kartı · hesap varsa telefonda bırakılan film
TV'de "İzlemeye devam et" satırında.

**B10 – Build 7 performans/UX (kullanıcı, TestFlight):** Ayarlar → Gelişmiş ve tanılama → Performans katmanı'nı aç ·
canlıda 10 komşu zap → katmandaki p50/p90 (hedef ≤ 1,0 sn / ≤ 1,8 sn) ve ekran görüntüsü · uygulamayı canlı kanalda
kapatıp aç → son kanal ≤ 1,5 sn'de oynar (Hızlı başlat açık) · kanal listesinde ⭐ tek dokunuş + "Geri al" ·
oynatıcı → Ses → Senkron: kanal gecikmesi ve cihaz gecikmesi (soundbar) ile dudak senkronu; ≠ 0 iken motor katmanda VLCKit ·
iPhone'da soldan kaydırma / Apple TV'de OK ile kanal paneli, oynatma durmadan · TV'de rakam tuşlarıyla numara · Canlı TV
listesi akıcı kaydırma, 50 000 kanallı kaynakta TV Rehberi · Instruments → Animation Hitches (iPhone): Canlı liste ve TV
Rehberi kaydırma, hitch oranı < %1 (simülatörde ölçülemedi, bkz. D3).

## C. Format testi
`docs/STREAM_COMPATIBILITY.md §3.2`.

## D. Ölçümler – Build 7 (2026-10-07)

Bütçeler: `docs/superpowers/specs/2026-10-06-performance-ux-design.md §1`. Aşağıdaki sayılar **simülatör** sayılarıdır
(Mac mini, iPhone 17 Pro simülatörü iOS 26.4, **Debug** derleme, Build 7); gerçek cihaz sayıları TestFlight'tan kullanıcıdan gelir.

### D1. Zap (komşu kanal, HLS) – `PerfTrace` (`perf zapMs`)
Koşul: `redesign/demo.m3u` (12 kanal, genel internet HLS: `devstreaming-cdn.apple.com` bipbop, `test-streams.mux.dev`;
yerel ağ değil), canlıda oynatıcıda dikey kaydırma ile 10 ardışık zap, her zaptan sonra 6 sn bekleme (ilk kare + ön ısıtma).
`PerfTrace` ölçümü 400 ms'lik birleştirme (debounce) **sonrasında** başlar; aşağıda ikisi de verilmiştir.

| | ms |
|---|---|
| 10 örnek (sıra) | 1183 · 1158 · 366 · 388 · 1213 · 1145 · 360 · 364 · 377 · 388 |
| p50 / p90 (en yakın sıra) – debounce hariç | **388 / 1183** |
| p50 / p90 – 400 ms debounce dahil (hesap: +400) | 788 / 1583 |
| Bütçe | p50 ≤ 1000, p90 ≤ 1800 → her iki hesapta karşılandı |

Dağılım iki kümeli (6 örnek 360–390 ms, 4 örnek 1145–1213 ms); nedeni araştırılmadı (ön ısıtma isabeti/ıskası olduğu doğrulanmadı).
Zaplar yalnızca bu 10 örneklik tek koşuya dayanır.

### D2. Soğuk açılış → son kanal ilk kare (Hızlı başlat) – `perf coldStartMs`
Koşul: canlı kanal oynarken uygulama sonlandırıldı, sonra yeniden başlatıldı (gerçek SQLite/UserDefaults, `-uiTrial`). Ölçüm uygulama
başlatıcısından (`App.init`) ilk kareye kadardır; işlem başlatma/dyld hariç. İki seri: 5 örnek (UI testi) + 10 örnek (`simctl launch`).

| Seri | Örnekler (ms) |
|---|---|
| 1 (5) | 2429 · 1435 · 885 · 870 · 901 |
| 2 (10) | 815 · 616 · 1609 · 616 · 687 · 642 · 592 · 622 · 563 · 603 |
| Tümü (15) | p50 **687**, p90 **1609**, en küçük 563, en büyük 2429; 13/15 örnek ≤ 1500 |

Bütçe ≤ 1,5 sn: tipik değerler karşılıyor (p50 687 ms), ancak 15 örnekten ikisi aştı (2429 ms – seri 1'in ilk yeniden açılışı, hemen
zap koşusundan sonra; 1609 ms). Bu iki aykırı değerin nedeni araştırılmadı. p90 bütçeyi **aşıyor** (1609 > 1500).

### D3. Animation Hitches (kaydırma kare düşmesi, hedef < %1)
**Ölçülemedi.** `xcrun xctrace record --template 'Animation Hitches' --device <iPhone 17 Pro simülatörü> --attach NovaPlayer --time-limit 26s`
bağlanır ama kayıt `Hitches is not supported on this platform.` hatasıyla biter (simülatörde hitch şablonu desteklenmiyor);
bağlı fiziksel cihaz yok. Bu yüzden hitch oranı **kaydedilmedi**; ölçüm gerçek iPhone'da B10 ile yapılmalıdır. Kaydırma yükü
için 5 000 kanallı / 300 kanal EPG'li sentetik liste hazırlandı ve simülatörde içe aktarılıp Canlı liste açıldı; TV Rehberi kaydırması çalıştırılmadı (hitch kaydı
zaten desteklenmediği için durduruldu). Bu bir akıcılık ölçümü değildir.

### D4. 50 000 kanal bütçeleri – `CatalogPerformanceTests`, `NumberZapTests` (`swift test`, macOS arm64, medyan)

| Ölçüm | Medyan | Bütçe |
|---|---|---|
| Liste sayfası (Tümü, ofset 40 000) | 0,82 ms | 100 ms |
| Liste sayfası (kategori) | 0,12 ms | 100 ms |
| EPG ızgarası (200 kanal × 6 sa) | 0,85 ms | 100 ms |
| Şimdi/sonraki (100 kanal) | 2,22 ms | 20 ms |
| FTS arama (50k kanal) | 24,22 ms | 100 ms |
| FTS arama (50k kanal + 20k film + 5k dizi) | 29,59 ms | 100 ms |
| Kanal paneli açma (50k, kategori, oynayan kanalı göster) | 3,05 ms | 100 ms |

Testler bütçenin 2 katında (factor 2.0) başarısız olacak şekilde kuruludur; hepsi geçti.

### D5. Doğrulama koşusu (2026-10-07)

| Paket | Sonuç |
|---|---|
| `apple/IPTVCore` `swift test` | 91 test, 0 hata |
| `apple/IPTVKit` `swift test` | 230 test, 0 hata |
| Kotlin çekirdek `./gradlew -p android :core:test` | 90 test, 0 hata/atlama |
| `backend` `npm test` | vitest 204/204 (11 dosya) + keygen 5/5 |
| iOS / tvOS derleme (`generic/platform=… Simulator`) | başarılı, uyarı/hata yok |
| iOS UI (`NovaPlayer-iOS`, iPhone 17 Pro) | 37 geçti, 0 başarısız; `StoreKitFlowTests` 4 test `XCTSkip` (komut satırında storekitd yapılandırmayı reddeder, `apple/README.md` StoreKit bölümü) |
| tvOS UI (`NovaPlayer-tvOS`, Apple TV 4K (3. nesil)) | 21 test: 20 geçti, 1 başarısız = bilinen `TVFlowTests/testPairingQRCode` (geliştirme backend'i `DEV_BACKEND_URL` gerekir) |

