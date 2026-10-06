# Performans & Kullanıcı Deneyimi Programı — Tasarım

Tarih: 2026-10-06 · Durum: kullanıcı onaylı (sıra: Hız → Favori → Menü → Ses senkronu)
Kapsam: önce iPhone/iPad + Apple TV (TestFlight Build 6), ardından Android/Android TV
(IPTVX tasarım geçişiyle birlikte). Normatif değişiklikler önce `docs/SCREENS.md`,
`docs/ARCHITECTURE.md` ve gerekiyorsa `spec/CONTRACT.md`'ye yazılır.

## Hedef
Kullanıcının diğer IPTV uygulamalarında yaşadığı dört sorunu ölçülebilir şekilde çözmek:
yavaşlık, ses senkron kayması, karmaşık menü, zahmetli favori ekleme.

## 1. Hız (performans bütçeleri)

| Ölçüm | Bütçe | Nasıl ölçülür |
|---|---|---|
| Soğuk açılış → son kanal ilk kare (HLS, yerel ağ) | ≤ 1,5 sn | `PerfTrace` (aşağıda) + UI test metriği |
| Kanal değiştirme (zap), komşu kanal, HLS | ≤ 1,0 sn (p50), ≤ 1,8 sn (p90) | `PerfTrace.zap` |
| Kanal listesi açma / FTS arama, 50.000 kanal | ≤ 100 ms | IPTVKit `measure` testi (sentetik DB) |
| Şimdi/sonraki sorgusu, 50.000 kanal görünür sayfa | ≤ 20 ms / sayfa | IPTVKit `measure` testi |
| EPG ızgarası / satır kaydırma | 60 fps, kare düşmesi < %1 | Instruments hitch (manuel, STATUS'ta raporlanır) |

Bileşenler:
- **Anında başlatma (`QuickStart`)**: açılışta, kaynak yenilemesini beklemeden son izlenen
  canlı kanal (ayar: Açık/Kapalı, varsayılan Açık — yalnızca son oturum canlı kanalda
  bittiyse) oynatıcıda açılır. Yenileme arka planda (atomik) sürer.
- **Komşu kanal ön ısıtma (`ZapPrefetcher`)**: canlı oynatırken önceki/sonraki kanal için
  DNS + TCP/TLS bağlantısı ve HLS ana/çeşit listesi önceden alınır (HEAD/GET, bayt sınırı
  256 KB, eşzamanlı en fazla 2). Kanal değişince hazır URL/manifest kullanılır. VLC/TS
  akışlarında yalnızca bağlantı ısıtılır. Hücresel ağda ve "Düşük veri modu"nda kapalı.
- **Canlı başlangıç ayarı**: AVPlayer canlıda `preferredForwardBufferDuration = 1`,
  `automaticallyWaitsToMinimizeStalling = false` ilk 3 sn, ardından `true`;
  ilk çeşit için `preferredPeakBitRate` sınırı (≈ 2,5 Mbps) ilk 4 sn, sonra kaldırılır.
  VLC canlı `network-caching` 1500 → 1000 ms (ayar "Arabellek: Büyük" ise 3000).
- **Liste/görsel**: görseller hedef boyuta küçültülerek (`CGImageSourceCreateThumbnailAtIndex`)
  çözülür, bellek + disk önbelleği; kaydırmada iptal. Şimdi/sonraki için
  `(sourceId, channelEpgId, start)` indeksli tek sorgu ve 60 sn önbellek.
- **Artımlı yenileme**: liste yenilemede değişmeyen satırlar yeniden yazılmaz
  (içerik karması karşılaştırması), yenileme UI'yi kilitlemez.
- **`PerfTrace` + gizli performans katmanı**: imleçler (uygulama açılış, oynatma isteği,
  ilk kare, zap). Ayarlar → Tanılama → "Performans katmanı" açılınca oynatıcıda: motor,
  zap süresi, tampon, bitrate, çözünürlük, düşen kare. Log'a yalnızca süreler yazılır
  (redaksiyon kuralı geçerli, URL yok).

## 2. Tek dokunuşla favori
- ⭐ düğmesi: kanal kartı, film/dizi kartı (köşe, uzun basış menüsü), detay sayfası,
  oynatıcı katmanı. Tek dokunuş → anında durum değişimi (iyimser güncelleme) + 4 sn
  "Geri al" bildirimi. Hiçbir onay diyaloğu yok.
- TV: oynatıcıda **yukarı tuşu = kanal bilgisi**, bilgi kartında ⭐ odakta; kartlarda uzun OK
  menüsünün ilk öğesi "Favorilere ekle/çıkar".
- Favori kanallar canlı ızgarada ve kanal panelinde **her zaman en üstte** ("Favoriler"
  çipi varsayılan seçili değil, ama ilk bölüm). Favori **kategoriler** (çip üzerinde ⭐).
- Sıralama: Favoriler ekranında sürükle-bırak (iOS), TV'de "Taşı" modu. Sıra v1'de
  **yalnızca cihazda** tutulur (senkron sözleşmesi değişmez; yeni cihazda en yeni üstte).

## 3. Basit menü
- **3 dokunuş kuralı**: her ana işleve açılıştan ≤ 3 etkileşim (SCREENS §2'ye eklenir,
  UI testleri yolları doğrular).
- **Oynatıcı içi kanal paneli**: iPhone'da sola kaydırma / liste düğmesi, TV'de OK →
  yan panel (kategori + kanallar + şimdiki program), oynatma durmadan.
- **TV rakam tuşları**: 1,5 sn içinde girilen numaraya geçiş (mevcut SCREENS §3.7) — kanal
  numarası kaynaktaki sırayla atanır, oynatıcıda büyük rakam göstergesi.
- **Sade ayarlar**: üstte en sık 5 ayar (Kaynaklar, Dil, Ses dili, Altyazı dili, Hızlı
  başlat); geri kalanı "Gelişmiş" altında. "Son izlenenler" ana sayfada ilk satır.

## 4. Ses senkronu
- **Ses gecikmesi**: oynatıcı → Ses menüsü → "Senkron" −2000…+2000 ms, 50 ms adım, canlı
  önizlemeli. **Kanal/içerik bazında** saklanır (`contentKey`), ayrıca global "Cihaz/soundbar
  gecikmesi" (Ayarlar → Oynatma). Uygulama (Apple): VLC `currentAudioPlaybackDelay` (µs,
  iki yön de). AVPlayer HLS akışlarında ses gecikmesi uygulanamaz (audio tap HLS'de
  çalışmaz) → **etkin gecikme ≠ 0 ise o içerik VLC motoruyla oynatılır** (motor seçimi
  CONTRACT §6.1'e eklenir: "audioDelayMs ≠ 0 → VLCKit"). Gecikme 0'a dönünce sonraki
  açılışta AVPlayer'a geri dönülür. Android: Media3 özel `AudioProcessor` (gecikme hattı,
  iki yön için video tarafı sabit, ses ileri/geri kaydırılır) — Android aşamasında.
- **"Senkronu düzelt"** (tek dokunuş): canlıda canlı uca atla + oynatıcıyı yeniden hazırla;
  VOD'da mevcut konumdan yeniden yükle. Yeniden bağlanmadan (ReconnectPolicy) sonra
  otomatik uygulanır.
- **Canlıda HLS önceliği** (Apple): Xtream canlıda m3u8 zaten tercih; M3U'da `.ts`
  kanallar için aynı URL'nin `.m3u8` varyantı denenir (Xtream kalıbı tanınırsa), olmazsa VLC.

## Test & doğrulama
- IPTVKit birim testleri: ZapPrefetcher (bayt/eşzamanlılık sınırı, iptal), gecikme
  saklama/yükleme, favori iyimser güncelleme + geri al, QuickStart karar mantığı,
  performans `measure` testleri (50k sentetik kanal).
- UI testleri: tek dokunuş favori (kart, detay, oynatıcı), oynatıcı içi kanal paneli,
  3 dokunuş yolları, TV yukarı tuşu → bilgi kartı ⭐.
- Gerçek cihaz (kullanıcı, TestFlight Build 6): zap süresi ve ses senkronu kontrolü,
  performans katmanından ekran görüntüsü.

## Kapsam dışı (v1)
Favori sırasının hesaplar arası senkronu, otomatik dudak senkronu tespiti, kayıt/hatırlatıcı.
