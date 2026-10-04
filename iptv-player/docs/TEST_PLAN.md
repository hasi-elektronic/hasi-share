# Test ve Doğrulama Planı

İki katman: **(A) otomatik testler** (bu depoda, Linux'ta çalışır; ortak vektörler) ve
**(B) gerçek cihaz testleri** (telefon + TV, manuel kontrol listesi). Sonuçlar `docs/STATUS.md`'de.

## A. Otomatik testler

| Komut | Kapsam |
|---|---|
| `cd backend && npm test` | Lisans senkronu, deneme anlık görüntüsü, Google/Apple doğrulama (mock), iade webhook'ları, cron, hesap/OTP, cihaz-kodu girişi, senkron LWW, eşleştirme, admin, redaksiyon, token vektörleri |
| `gradle -p android/core test` | Kotlin çekirdek: tüm `spec/test-vectors` + ağ hata eşleme (MockWebServer), büyük liste performansı |
| `docker run … swift:6.1-jammy swift test` (`apple/IPTVCore`) | Swift çekirdek: tüm vektörler + hata eşleme, büyük liste performansı |

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

## C. Format testi
`docs/STREAM_COMPATIBILITY.md §3.2`.
