# Yayın Formatı Uyumluluğu (Media3 vs AVPlayer)

Kural seti: `spec/CONTRACT.md §6`. Uygulama oynatmadan önce kapsayıcı (container) biçimini
URL şeması → ilk baytlar → `Content-Type` → uzantı sırasıyla tespit eder; platformun
desteklemediği biçimde oynatıcıyı hiç başlatmadan **anlaşılır hata** gösterir.

## 1. Kapsayıcı matrisi

| Biçim | Tipik IPTV kullanımı | Media3 (Android/Android TV) | AVPlayer (iOS/tvOS) | Apple'da davranış |
|---|---|---|---|---|
| HLS (`.m3u8`, TS veya fMP4 segment) | Xtream `m3u8` çıkışı, CDN'ler | ✅ | ✅ | – |
| MPEG-TS progresif (`.ts`) | Xtream canlı varsayılanı | ✅ | ❌ | Xtream'de otomatik `m3u8` istenir; yalnızca `ts` izinliyse "Sağlayıcınızdan HLS isteyin" |
| MP4 / MOV / M4V | VOD | ✅ | ✅ | – |
| MKV | VOD (çok yaygın) | ✅ | ❌ | "MKV bu cihazda oynatılamıyor" |
| WebM | nadir | ✅ | ❌ | hata |
| FLV | eski | ✅ | ❌ | hata |
| AVI | eski VOD | ✅ (kodeğe bağlı) | ❌ | hata |
| DASH (`.mpd`) | bazı CDN'ler | ✅ | ❌ | hata |
| RTSP | IP kameralar | ✅ | ❌ | hata |
| RTMP | eski panel | ❌ (eklenti paketlenmedi) | ❌ | hata |
| UDP/RTP multicast | operatör ağları | ❌ | ❌ | hata |
| DRM (Widevine/FairPlay, `KODIPROP`) | premium kanallar | ❌ (lisans entegrasyonu yok) | ❌ | "Korumalı yayın" |

## 2. Kodek notları (kapsayıcı desteklense bile cihaza bağlı)

| Kodek | Media3 | AVPlayer |
|---|---|---|
| H.264 / AAC | ✅ tüm cihazlar | ✅ |
| HEVC (H.265) | Donanım çözücüye bağlı (çoğu TV kutusu ✅) | ✅ (HLS'te fMP4 segment gerekir; TS içinde HEVC ❌) |
| AC-3 / E-AC-3 | Cihaz çözücüsü veya HDMI passthrough | ✅ (HLS) |
| MPEG-1/2 Audio Layer II (DVB kanalları) | Çoğu cihazda ✅ | ❌ HLS'te |
| VP9 / Opus | ✅ çoğu cihaz | ❌ (WebM zaten desteklenmiyor) |
| MPEG-2 Video | Cihaza bağlı (çoğu TV kutusu ✅, telefonlar ❌) | ❌ |
Kodek hatası (`UnsupportedCodec`) oynatıcının çözücü başlatma hatasından eşlenir.

## 3. Doğrulama

### 3.1 Bu depoda otomatik doğrulanan (Linux CI)
* ffmpeg 7.1 ile üretilmiş **gerçek** örnek dosyalar (`spec/test-vectors/media/`: TS, çok
  sesli TS, MP4, MKV, WebM, FLV, AVI, HLS, DASH) üzerinde biçim tespiti — Kotlin ve Swift
  çekirdeklerinde aynı vektörlerle.
* URL/Content-Type tabanlı tespit ve platform destek matrisi.
* Xtream canlı uzantı seçimi (Android: `ts` tercih, Apple: `m3u8` zorunlu) ve catch-up URL'leri.

### 3.2 Gerçek cihazda yapılacak (manuel — bu ortamda cihaz yok)
1. Bilgisayarda: `cd spec/test-vectors/media && python3 -m http.server 8000`
2. Uygulamada: *Ayarlar → Gelişmiş ve tanılama → Format testi* — liste
   `spec/test-vectors/stream-samples.json` (yerel örnekler + Apple/Mux/Akamai/Google genel test
   yayınları). Her örnek için sonuç "Oynatılıyor ✓", "Beklenen hata ✓" veya "Beklenmeyen".
3. Kontrol listesi:
   * Apple bipbop gelişmiş HLS: ≥ 2 ses parçası, altyazı seçimi çalışıyor (her iki platform).
   * `sample_multiaudio.ts` (Media3): `tur` / `eng` ses değişimi.
   * Akamai canlı HLS: uçak modu aç/kapat → "Yeniden bağlanılıyor (n/5)" → toparlanma.
   * MKV/TS/DASH Apple'da: oynatıcı açılmadan anlaşılır hata.
   * 404 ve erişilemeyen host: `StreamOffline` / ağ hatası + yeniden deneme davranışı.
4. Sonuçları `docs/STATUS.md` "Cihaz doğrulaması" tablosuna işleyin.

## 4. Gelecek seçenekler
* Apple'da TS/MKV için VLCKit veya ffmpeg tabanlı oynatıcı (lisans/boyut etkisi değerlendirilmeli).
* Android'de RTMP için `media3-datasource-rtmp` eklentisi (LGPL librtmp).
* Media3 ffmpeg ses eklentisi (AC-3/MP2 çözücüsü olmayan cihazlar için).
