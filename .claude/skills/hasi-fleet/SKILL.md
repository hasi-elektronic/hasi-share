---
name: hasi-fleet
description: >
  Çok-agent (paralel) çalışma, delegasyon ve doğrulama sistemi — platformdan bağımsız.
  Claude Code, claude.ai, Cursor/Windsurf, Codex CLI veya düz sohbet arayüzü fark etmez;
  hangi ortamda çalışıyorsan oradaki yeteneklere göre uyarlanır.
  Büyük kod incelemeleri, güvenlik/performans auditleri, çok modüllü implementasyon,
  toplu müşteri sitesi üretimi, zor bug avı, büyük refactor ve görsel varlık üretiminde kullan.
  Görevi tek agent / pipeline / fleet olarak sınıflandırır, lane sahipliğini (OWNS /
  DO NOT TOUCH) tanımlar, en dar yetkiyle çalışır, git worktree ile eşzamanlı yazmayı
  izole eder ve her lane'i doğrulama kapısından geçirir.
  Tetikleyiciler: "paralel çalış", "fleet başlat", "agent'lara dağıt", "çok agent",
  "tüm projeyi incele", "audit yap", "kod review", "büyük refactor", "aynı anda",
  "birden fazla site/proje", "parallel", "multi-agent", "orchestrate", "fan out",
  "Projekt prüfen", "Code Review", "Audit", "Refactor", "gleichzeitig".
---

# Hasi Fleet — Çok-Agent Orkestrasyonu (platformdan bağımsız)

**Sürüm:** 2.0.0

Amaç **"mümkün olduğunca çok agent açmak" değildir.** Amaç:
**kontrolü, doğruluğu ve repo bütünlüğünü kaybetmeden işi hızlı bitirmek.**

Bu dosya çekirdek doktrindir ve **her platformda geçerlidir.** Ortama veya teknoloji
yığınına özel detaylar ayrı referans dosyalarındadır — sadece gerektiğinde oku:

| Ne zaman | Oku |
|---|---|
| Hangi ortamdayım, delegasyonu nasıl yaparım | `references/platforms.md` |
| Bu projenin kabul/doğrulama komutu ne | `references/stacks.md` |
| Hasi KI-System agent'ları, MCP araçları, marka kuralları | `references/hasi-mapping.md` |
| Claude dışı bir araca (ChatGPT, Grok, Codex, Cursor) taşıyacağım | `references/portable-prompt.md` |

Kurulum ve dağıtım için: `INSTALL.md`.

---

## 0. Adım sıfır: yetenek tespiti

Delegasyondan önce **bulunduğun ortamın gerçekte ne yapabildiğini** belirle. Varsayma.

1. **Gerçek paralel agent açabiliyor muyum?** (subagent/task aracı, arka plan süreç, ayrı CLI)
2. **Dosya yazabiliyor muyum?** (dosya araçları veya shell)
3. **Komut çalıştırabiliyor muyum?** (test, build, git)
4. **Ağ / MCP erişimim var mı?**

Buna göre çalışma modunu seç:

| Yetenek | Mod |
|---|---|
| Paralel agent + shell + dosya | **Tam fleet** — bu dosyanın tamamı geçerli |
| Shell + dosya, paralel agent yok | **Seri fleet** — lane'leri sırayla, aynı sahiplik ve kapılarla çalıştır |
| Sadece sohbet (dosya/komut yok) | **Danışman modu** — lane brief'lerini, sahiplik haritasını ve kabul komutlarını *üret*, çalıştırılmış gibi davranma |

Ortama özgü komutlar ve delegasyon biçimi için `references/platforms.md`.

**Asla:** yapılmamış bir doğrulamayı yapılmış gibi raporlama; olmayan bir yeteneği varmış gibi kullanma.

---

## 1. Temel prensipler

### 1.1 En dar yetki (least privilege)

1. **Salt okuma** (inceleme, audit, teşhis, mimari çıkarımı)
2. **Workspace yazma** (yalnız gerçekten değişiklik gerekiyorsa)
3. **Ağ erişimi** (paket, API, doküman — ayrı gerekçe ister)
4. **Deploy / production** (yalnızca açık onayla, tek lane)

Kolaylık olsun diye geniş yetki kullanma. Kural/onay/güvenlik sınırını **atlatmak amaçlı**
bayrak veya komut asla kullanma.

### 1.2 Sadece bağımsız işi paralelleştir

**Paralel olur:** frontend review + backend review · güvenlik auditi + performans auditi ·
bağımsız müşteri projeleri · bağımsız paketler · bağımsız failing testler · bağımsız görseller.

**Paralel olmaz (pipeline gerekir):** şema/migration → ona bağlı kod · refactor → ona bağlı
testler · API → frontend · sıralı video/story kareleri · aynı dosyaya yazan iki lane ·
rakip mimari karar veren iki lane.

Bağımlılık varsa **fleet değil pipeline** kur.

### 1.3 Doğrulama > özgüven

Bir agent'ın "bitti" demesi kanıt değildir. Her önemli işi en güçlü uygun kapıdan geçir:
typecheck · hedefli test → geniş test · lint · build · dry-run deploy · şema doğrulama ·
`git diff` okuması · runtime smoke test · görsel işte gözle kontrol.

Bu projede hangi komutun geçerli olduğu için → `references/stacks.md`.

### 1.4 Kullanıcının işini koru

Yazma işleminden önce her zaman:

```bash
git status --short
git rev-parse --abbrev-ref HEAD
```

İlgisiz lokal değişiklik varsa **koru**. Kullanıcı açıkça istemedikçe ve kapsam
doğrulanmadıkça yıkıcı komut çalıştırma:

```
git reset --hard · git clean -fd · git checkout -- . · rm -rf <geniş-yol>
DROP/TRUNCATE içeren veritabanı komutları · force push · geçmiş yeniden yazma
```

---

## 2. Ortam ve proje keşfi

```bash
pwd
git rev-parse --show-toplevel 2>/dev/null || true
git status --short 2>/dev/null || true
ls package.json wrangler.toml schema.sql requirements.txt app.json composer.json 2>/dev/null
```

Bulguları `references/stacks.md` tablosuyla eşleştir → proje tipi ve kabul kapıları çıkar.

**Efor seçimi:** mekanik iş (rename, çeviri, format) → düşük–orta · normal mühendislik →
yüksek · zor teşhis/mimari/güvenlik → en yüksek, ama **her lane'de değil.**

Kullanıcı belirli bir model/araç istediyse sessizce düşürme; kullanılamıyorsa açıkça söyle.

---

## 3. Görev sınıflandırma

| Sınıf | Ne zaman | Varsayılan kurulum |
|---|---|---|
| **A. REVIEW** | incele ve raporla | salt okuma, dosya değişikliği yok, kanıtlı bulgu |
| **B. IMPLEMENT** | sınırlı değişiklik | workspace yazma, dar sahiplik, hedefli test |
| **C. DEBUG** | hata avı | Faz 1 teşhis (okuma) → Faz 2 yama + doğrulama |
| **D. FLEET** | ≥2 bağımsız iş kolu | paralel lane'ler + entegrasyon kapısı |
| **E. PIPELINE** | B, A'nın çıktısına bağlı | sıralı zincir |

Basit bir düzeltmeyi fleet'e çevirme. Tek dosyalık iş = tek agent.

---

## 4. Lane briefing sözleşmesi

Her delege **kendi başına yeterli** brief alır. Bu şablon platformdan bağımsızdır: subagent'a,
başka bir CLI'ya, hatta başka bir sohbet penceresine aynı şekilde verilir.

```text
ROL
<lane adı> lane'isin.

HEDEF
<tek, ölçülebilir hedef>

BAĞLAM
<mimari / hata / müşteri beklentisi — sadece gerekli kadar>

ÇALIŞMA DİZİNİ
<worktree veya repo yolu>

SAHİPLİK (OWNS)
- <bu lane'in değiştirebileceği dosya/dizinler>

DOKUNMA (DO NOT TOUCH)
- <başka lane'lerin dosyaları>
- ilgisiz lokal değişiklikler
- tek sahipli ortak dosyalar (bkz. references/stacks.md)

GEREKSİNİMLER
- <fonksiyonel gereksinim, kısıt: geriye dönük uyumluluk, DSGVO, dil, marka>

SÜREÇ
1. ilgili kodu incele
2. en küçük tutarlı yamayı yaz
3. ilgisiz refactor yapma
4. kabul kontrollerini çalıştır

KABUL KONTROLLERİ
- <somut komut(lar)>

ÇIKTI
- durum: DONE | PARTIAL | BLOCKED | FAILED
- özet · değişen dosyalar · çalıştırılan kontroller ve sonuçları
- kalan riskler · blocker (varsa)
```

Salt-okuma lane'lerinde `OWNS` yerine `SCOPE` yaz ve **"DOSYA DEĞİŞTİRME"** talimatını açıkça ver.

---

## 5. Genel lane rolleri

| Lane | Odak |
|---|---|
| Frontend | bileşen mimarisi, render, state, a11y, responsive |
| Backend/API | route/endpoint, validation, hata yönetimi, eşzamanlılık, entegrasyon |
| Veritabanı | şema, index, migration, sorgu performansı, yetki sınırı (RLS vb.) |
| Güvenlik (salt okuma) | auth/authz, secret sızıntısı, injection, güvensiz varsayılan, bağımlılık riski |
| Performans | bundle, cache, gereksiz render, yavaş sorgu, ağ maliyeti |
| QA | kabul kriteri, test kapsamı, regresyon, uç durumlar |
| UI/UX | hiyerarşi, okunabilirlik, tutarlılık, etkileşim |
| Deploy | build, release, DNS/SSL, ortam değişkeni — **her zaman tek lane** |
| Doküman | README, API dokümanı, teslim/müşteri metni, migration notu |

Hasi KI-System'in 11 agent'ıyla eşleme → `references/hasi-mapping.md`.
Sadece göreve gerçekten gereken lane'leri aç.

---

## 6. Eşzamanlı yazma güvenliği

### 6.1 En iyi yöntem: lane başına git worktree

```bash
BASE_SHA=$(git rev-parse HEAD)
git worktree add --detach ../fleet-frontend "$BASE_SHA"
git worktree add --detach ../fleet-backend  "$BASE_SHA"
git worktree add --detach ../fleet-db       "$BASE_SHA"
```

Her lane kendi dizininde çalışır. Bitince:

1. lane diff'ini oku
2. lane kabul kontrolünü çalıştır
3. ana branch'e entegre et
4. çakışmayı **sahiplik niyetine göre** çöz (kör "onların/bizim" seçme yok)
5. entegrasyon kapısını çalıştır
6. `git worktree remove ../fleet-*` ile temizle

Worktree yoksa (git dışı proje, salt sohbet ortamı): lane'leri **sıraya al**, veya ayrı klasör
kopyalarında çalıştır. Aynı dosyaya eşzamanlı iki yazıcı asla olmaz.

### 6.2 Ortak ağaçta yazma

Yalnızca lane'ler **tamamen ayrık** dosyalara yazıyorsa. Tek sahipli, yüksek çakışmalı
dosya listesi teknoloji yığınına göre değişir → `references/stacks.md`.
Genel kural: paket manifesti, kilit dosyası, merkezi config, route tablosu, şema, üretilmiş
dosyalar → **tek sahip** veya paralel iş bittikten sonra **tek entegrasyon lane'i.**

---

## 7. Fleet boyutu ve maliyet

| Boyut | Ne zaman |
|---|---|
| 2–4 lane | normal |
| 5–8 lane | büyük kod tabanı, geniş audit, toplu üretim |
| >8 lane | iş doğal olarak parçalanıyorsa ve ortam kaldırıyorsa |

Lane açmadan önce sor: ayrı ve net hedefi var mı? · bağımsız ilerleyebilir mi? ·
bağlamı yeterli mi? · çıktısı sonucu gerçekten iyileştirir mi?
Biri "hayır" ise **açma.** Koordinasyon maliyeti hızla artar.

---

## 8. Canlılık (liveness) ve kurtarma

Bir lane takılmış olabilir: uzun süre çıktı üretmiyor, aynı adımı tekrar ediyor, süreç yaşıyor
ama ilerleme yok.

Yeniden denemeden önce: (1) lane çıktısını/logunu oku · (2) çalışma ağacında kısmi değişiklik
var mı bak (`git status --short`, `git diff`) · (3) tekrar denemenin güvenli olup olmadığına
karar ver.

Aynı yazılabilir dizine körlemesine ikinci lane açma. Başarısız bir agent'ın **hiç değişiklik
bırakmadığını varsayma.**

---

## 9. Entegrasyon kapısı

Tüm yazan lane'ler bittikten sonra kalite orkestratörün sorumluluğundadır:

1. `git status --short`
2. `git diff` incelemesi
3. lane başına hedefli test
4. repo geneli typecheck
5. lint
6. entegrasyon testleri
7. build
8. dry-run deploy (destekleyen yığınlarda)
9. mümkünse runtime smoke test

Kapıyı projeye göre uyarla (`references/stacks.md`); gereksiz pahalı test paketi çalıştırma.
**Önceden var olan hata ile fleet'in ürettiği regresyonu net ayır.**
Deploy her zaman entegrasyon kapısından **sonra**, tek lane tarafından yapılır.

---

## 10. Rapor formatı

Ham agent loglarını kullanıcıya dökme.

```text
SONUÇ
Durum: DONE | PARTIAL | BLOCKED | FAILED

Tamamlanan
- ...

Değişen
- yol/dosya.ext — kısa açıklama

Doğrulanan
- komut → PASS/FAIL

Önemli bulgular
- ...

Risk / kalan iş
- ...
```

Fleet için ayrıca lane tablosu:

```text
Lane        Durum      Kapsam            Doğrulama
Frontend    DONE       src/app           build PASS
Backend     DONE       src/api           test 18/18 PASS
Güvenlik    BULGU      salt okuma        3 bulgu (1 kritik)
```

---

## 11. Hata politikası

| Durum | Davranış |
|---|---|
| Araç/CLI/yetenek yok | Neyin eksik olduğunu ve nasıl tespit edildiğini söyle; yapılmış gibi davranma |
| Kimlik doğrulama hatası | Hatayı bildir, tekrar tekrar deneme |
| Yetki/sandbox hatası | Hemen geniş yetkiye çıkma; önce daha dar yazılabilir dizin, kapsamlı ağ izni veya farklı mod dene |
| Test hatası | Sınıflandır: lane'in yol açtığı / önceden var olan / başka lane / ortam-bağımlılık |
| Kısmi değişiklik | Yeniden denemeden önce diff'i oku |
| Ağ yok | Sınırlamayı bildir; "auth bozuk" gibi uydurma teşhis koyma |

---

## 12. Görsel varlık delegasyonu

Görsel üretim **yetenek bağımlıdır, varsayılmaz.** Önce ortamda gerçek bir görsel üretim
aracı var mı bak; yoksa söyle. Kod aracıyla (PIL vb.) sahte "üretilmiş görsel" yapma.

Hasi ortamındaki araç sırası ve marka kuralları → `references/hasi-mapping.md`.

**Brief şablonu:** kullanım amacı · konu · kompozisyon · stil · ışık · renk (marka paleti) ·
birebir metin · referanslar (kimlik/ürün/logo/önceki kare) · korunacaklar · kaçınılacaklar
(watermark, fazladan logo, bozuk yazı) · çıktı (oran, boyut, dosya adı).

**Paralellik:** bağımsız görseller paralel; süreklilik gerektiren kareler **sıralı**.

**Doğrulama:** dosya var mı · boyut/format doğru mu · logo, fiyat, metin doğru mu.
Dosya boyutu kalite kanıtı değildir. Sadece hatalı varlığı yeniden üret.

---

## 13. Hazır preset'ler

### 13.1 Tam proje auditi (salt okuma, paralel)

```text
Lane A — Mimari      : yapı, sorumluluk ayrımı, ölçeklenme
Lane B — Güvenlik    : auth, secret, injection, yetki sınırı, DSGVO
Lane C — Veritabanı  : şema, index, migration sırası, N+1
Lane D — Frontend    : render, a11y, responsive, dil/metin
Lane E — Performans  : bundle, cache, cold start, ağ maliyeti
Lane F — QA          : test kapsamı, kabul kriterleri
```

Bulgular birleştirilir → **kullanıcı onayı** → sadece onaylanan değişiklikler için yazan lane
açılır. Problemi anlamadan koda yazan agent açma.

### 13.2 Toplu üretim (çok müşteri / çok site / çok varlık)

Her müşteri veya varlık **bağımsız bir lane**: kendi repo'su/klasörü. Ortak marka-tasarım
kararı tek lane'de, deploy tek lane'de.

### 13.3 Büyük refactor

```text
Faz 1 — salt okuma mimari haritası
Faz 2 — refactor planı + sahiplik haritası
Faz 3 — izole yazan lane'ler (worktree)
Faz 4 — entegrasyon
Faz 5 — test/build/deploy kapısı
```

"projeyi temizle", "kodu iyileştir", "her şeyi refactor et" gibi belirsiz brief'le çok-agent
refactor **başlatma.** Önce ölçülebilir sınır tanımla.

---

## 14. Güvenlik ve gizlilik

Aşağıdakiler **asla varsayılan davranış değildir:** repo kurallarını/sandbox'ı/onay
mekanizmasını atlatmak · güvenlik kontrollerini kapatmak · prompt veya log içinde secret
göstermek · özel kaynak kodu ilgisiz dış servise göndermek · takip edilmeyen dosyaları
silmek · git geçmişini yeniden yazmak, force push · production altyapısını veya veriyi
yıkıcı biçimde değiştirmek.

**Secret kuralı:** API key, token, parola, BitLocker key, müşteri kimlik bilgisi hiçbir lane
brief'ine yazılmaz. Ortam değişkeni, secret store veya mevcut oturum kullanılır. Örneklerde
`<SECRET_FROM_PASSWORD_MANAGER>` yaz. Log'da secret geçiyorsa ham dökme, özetle.

**Skill'i başka platforma taşırken:** bu dosyalar müşteri adı, adres, fiyat veya iç mimari
bilgi içerebilir (özellikle `references/hasi-mapping.md`). Üçüncü parti bir araca aktarmadan
önce gözden geçir; genel kullanım için `references/portable-prompt.md` yeterlidir.

Production'a dokunan işlerde otomatik yürütme değil, **aşamalı plan + doğrulama** kullan.

---

## 15. Karar ağacı

```text
Ortam ne yapabiliyor? (paralel agent / shell / sadece sohbet)
     ↓
İş birden fazla bağımsız kola ayrılıyor mu?
 ├─ Hayır → tek agent (veya doğrudan sen yap)
 └─ Evet
     ↓
Kollar birbirinin çıktısına bağlı mı?
 ├─ Evet → PIPELINE
 └─ Hayır → FLEET (paralel yetenek yoksa: seri fleet)
     ↓
Yazma gerekiyor mu?
 ├─ Hayır → salt okuma lane'leri
 └─ Evet
     ↓
Aynı repoda birden fazla yazan lane var mı?
 ├─ Hayır → normal çalışma
 └─ Evet → git worktree izolasyonu veya kesin ayrık sahiplik
     ↓
Entegrasyon kapısı → rapor → (onaylıysa) deploy
```

---

## 16. Orkestratör kontrol listesi

**Başlamadan:** hedef net mi · ortam yetenekleri tespit edildi mi · proje tipi ve kabul
komutları biliniyor mu · yazma varsa repo durumu temiz mi · en dar yetki seçildi mi ·
tek/pipeline/fleet kararı verildi mi · lane sahipliği yazılı mı.

**Çalışırken:** lane'ler bağımsız kaldı mı · worktree/log/çıktı takip ediliyor mu · ilgisiz
düzenleme yapılmadı mı · blocker dürüstçe raporlandı mı.

**Bitirirken:** diff okundu mu · hedefli kontroller çalıştı mı · entegrasyon kapısı geçildi mi ·
önceden var olan hatalar ayrıldı mı · sonuç ve riskler kısa özetlendi mi.

---

## 17. Bu skill bilerek şunları YAPMAZ

sınırsız kaynak varsaymaz · otomatik tam sistem erişimi vermez · hataları gizlemez ·
kural/onay atlamaz · agent'ın "bitti" demesine kanıtsız güvenmez · tek bir CLI, model veya
platform adını kalıcı varsaymaz · bağımlı işleri paralelleştirmez · eşzamanlı agent'ların aynı
dosyaya yazmasına izin vermez · dosya boyutunu görsel kalite kanıtı saymaz · ham log veya
secret dökmez.

---

## 18. İdeal sonuç

İyi bir Hasi Fleet çalışması **sıkıcıdır:** doğru sayıda lane, net sahiplik, en az yetki,
ezilmemiş dosya, sürpriz değişiklik yok, doğrulanmış sonuç, kısa rapor.

**Hız, dikkatsiz eşzamanlılıktan değil, iyi bölümlemeden gelir.**
