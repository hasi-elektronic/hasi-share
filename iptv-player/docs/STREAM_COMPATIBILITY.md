# Yayın Formatı Uyumluluğu (Media3 vs Apple: AVPlayer + VLCKit)

Kural seti: `spec/CONTRACT.md §6` ve `§6.1`. Uygulama oynatmadan önce kapsayıcı (container)
biçimini URL şeması → ilk baytlar → `Content-Type` → uzantı sırasıyla tespit eder. Android'de
tek motor (Media3) vardır. Apple'da **iki motor** vardır: AVPlayer (HLS, MP4/MOV, bilinmeyen) ve
VLCKit 3.7 (geri kalan her şey). Hiçbir motorun oynatamadığı biçimde oynatıcı hiç başlatılmadan
**anlaşılır hata** gösterilir.

## 1. Kapsayıcı matrisi

| Biçim | Tipik IPTV kullanımı | Media3 (Android/Android TV) | Apple motoru | Not |
|---|---|---|---|---|
| HLS (`.m3u8`, TS veya fMP4 segment) | Xtream `m3u8` çıkışı, CDN'ler | ✅ | ✅ AVPlayer | – |
| MPEG-TS progresif (`.ts`) | Xtream canlı varsayılanı | ✅ | ✅ VLCKit | Xtream'de yine `m3u8` tercih edilir; yalnızca `ts` izinliyse `ts` + VLCKit |
| MP4 / MOV / M4V | VOD | ✅ | ✅ AVPlayer | AVPlayer kodek hatası verirse → VLCKit (bir kez) |
| MKV | VOD (çok yaygın, Xtream filmleri) | ✅ | ✅ VLCKit | – |
| WebM | nadir | ✅ | ✅ VLCKit | – |
| FLV | eski | ✅ | ✅ VLCKit | – |
| AVI | eski VOD | ✅ (kodeğe bağlı) | ✅ VLCKit | – |
| DASH (`.mpd`) | bazı CDN'ler | ✅ | ✅ VLCKit | libVLC 3 `adaptive` modülü; DRM'siz |
| RTSP | IP kameralar | ✅ | ✅ VLCKit | `:rtsp-tcp` (TCP üzerinden RTP) |
| RTMP | eski panel | ❌ (eklenti paketlenmedi) | ✅ VLCKit | – |
| UDP/RTP multicast | operatör ağları | ❌ | ❌ | iOS'ta multicast yetkisi (entitlement) gerekir |
| Bilinmeyen (uzantısız URL) | `play.php?id=` | dene | önce 1 KiB yoklama; yine bilinmiyorsa AVPlayer, biçim/kodek hatasında VLCKit | – |
| DRM (Widevine/FairPlay, `KODIPROP`) | premium kanallar | ❌ (lisans entegrasyonu yok) | ❌ | "Korumalı yayın" |

## 2. Kodek notları (kapsayıcı desteklense bile cihaza bağlı)

| Kodek | Media3 | AVPlayer | VLCKit (Apple) |
|---|---|---|---|
| H.264 / AAC | ✅ tüm cihazlar | ✅ | ✅ (VideoToolbox donanım çözme) |
| HEVC (H.265) | Donanım çözücüye bağlı (çoğu TV kutusu ✅) | ✅ (HLS'te fMP4 segment gerekir; TS içinde HEVC ❌) | ✅ (TS/MKV içinde de) |
| AC-3 / E-AC-3 | Cihaz çözücüsü veya HDMI passthrough | ✅ (HLS) | ✅ (yazılım) |
| MPEG-1/2 Audio Layer II (DVB kanalları) | Çoğu cihazda ✅ | ❌ HLS'te | ✅ |
| VP9 / Opus | ✅ çoğu cihaz | ❌ | ✅ |
| MPEG-2 Video | Cihaza bağlı (çoğu TV kutusu ✅, telefonlar ❌) | ❌ | ✅ (yazılım; SD sorunsuz, HD'de CPU yükü) |
| Altyazı SRT/ASS/DVB-sub (MKV/TS içinde) | ✅ | – | ✅ |

Kodek hatası (`UnsupportedCodec`): Media3/AVPlayer'da çözücü hatasından eşlenir. VLCKit hata
nedeni bildirmez; yayın HTTP olarak erişilebilir olduğu hâlde hiç oynamadıysa `UnsupportedCodec`
gösterilir (bkz. CONTRACT §6.1). AVPlayer'da `UnsupportedFormat`/`UnsupportedCodec` alınan
yayın önce otomatik olarak VLCKit ile denenir.

## 3. Doğrulama

### 3.1 Bu depoda otomatik doğrulanan (Linux CI)
* ffmpeg 7.1 ile üretilmiş **gerçek** örnek dosyalar (`spec/test-vectors/media/`: TS, çok
  sesli TS, MP4, MKV, WebM, FLV, AVI, HLS, DASH) üzerinde biçim tespiti — Kotlin ve Swift
  çekirdeklerinde aynı vektörlerle.
* URL/Content-Type tabanlı tespit ve platform destek matrisi (Media3, AVPlayer, VLCKit) +
  Apple motor seçimi ve AVPlayer → VLCKit geri dönüşü (`media/expected.json` → `appleEngine`).
* Xtream canlı uzantı seçimi (Android: `ts` tercih; Apple: `m3u8` tercih, yalnızca `ts` izinliyse
  VLCKit ile `ts`) ve catch-up URL'leri.
* `IPTVKit` birim testleri (`EngineTests.swift`): sahte motorlarla biçim → motor, geri dönüş
  (bir kez, yeniden bağlanmada korunur), olay → durum, kanal değiştirme debounce'u, VLCKit hata
  sınıflandırması, parça dil adları.

### 3.2 Gerçek cihazda yapılacak (manuel — bu ortamda cihaz yok)
1. Bilgisayarda: `cd spec/test-vectors/media && python3 -m http.server 8000`
2. Uygulamada: *Ayarlar → Gelişmiş ve tanılama → Format testi* — liste
   `spec/test-vectors/stream-samples.json` (yerel örnekler + Apple/Mux/Akamai/Google genel test
   yayınları). Her örnek için sonuç "Oynatılıyor ✓", "Beklenen hata ✓" veya "Beklenmeyen".
3. Kontrol listesi:
   * Apple bipbop gelişmiş HLS: ≥ 2 ses parçası, altyazı seçimi çalışıyor (her iki platform).
   * `sample_multiaudio.ts` (Media3 ve Apple/VLCKit): `tur` / `eng` ses değişimi.
   * Akamai canlı HLS: uçak modu aç/kapat → "Yeniden bağlanılıyor (n/5)" → toparlanma.
   * MKV/TS/DASH/AVI/FLV Apple'da: VLCKit ile oynuyor; ses/altyazı listesi dil adlarıyla.
   * 404 ve erişilemeyen host: `StreamOffline` / ağ hatası + yeniden deneme davranışı.
4. Sonuçları `docs/STATUS.md` "Cihaz doğrulaması" tablosuna işleyin.

> Not (Apple): Format testi ekranı (`FormatTestViewModel`) şimdilik yalnızca **AVPlayer** motorunu
> ölçer ve `expect.avplayer` ile karşılaştırır; uygulamanın gerçek davranışı `expect.apple`'dır
> (MKV/TS/… VLCKit ile oynar). İki motorlu doğrulama: `UITests/*/…VLCPlaybackTests`
> (`apple/README.md` → "VLCKit doğrulaması").

## 4. Gelecek seçenekler
* Apple: VLCKit 4 (kararlı sürüm çıktığında) – PiP ve daha iyi hata bildirimi.
* Android'de RTMP için `media3-datasource-rtmp` eklentisi (LGPL librtmp).
* Media3 ffmpeg ses eklentisi (AC-3/MP2 çözücüsü olmayan cihazlar için).
