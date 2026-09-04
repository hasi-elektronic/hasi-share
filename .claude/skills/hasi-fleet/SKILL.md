---
name: hasi-fleet
description: >
  Hasi Elektronic işlerinde çok-agent'lı (paralel) çalışma ve delegasyon sistemi.
  Büyük kod incelemeleri, güvenlik/performans auditleri, çok modüllü implementasyon,
  toplu müşteri sitesi üretimi, zor bug avı ve görsel varlık üretiminde kullan.
  Görevi tek agent / pipeline / fleet olarak sınıflandırır, lane sahipliğini (OWNS /
  DO NOT TOUCH) tanımlar, en dar yetkiyle çalışır, git worktree ile eşzamanlı yazmayı
  izole eder ve her lane'i doğrulama kapısından geçirir.
  Tetikleyiciler: "paralel çalış", "fleet başlat", "agent'lara dağıt", "çok agent",
  "tüm projeyi incele", "audit yap", "kod review", "büyük refactor", "aynı anda",
  "birden fazla site/proje", "parallel", "multi-agent", "Projekt prüfen",
  "Code Review", "Audit", "Refactor", "gleichzeitig".
---

# Hasi Fleet — Çok-Agent Orkestrasyonu

**Sürüm:** 1.0.0
**Bağlı sistem:** Hasi KI-System (11 agent) + Claude Code subagent'ları

Amaç **"mümkün olduğunca çok agent açmak" değildir.** Amaç:
**kontrolü, doğruluğu ve repo bütünlüğünü kaybetmeden işi hızlı bitirmek.**

Bu skill `hasi-os` ile çakışmaz: `hasi-os` *ne yapılacağını* yönlendirir,
`hasi-fleet` *işin kaç agent'la ve hangi sahiplikle yapılacağını* yönetir.

---

## 1. Temel prensipler

### 1.1 En dar yetki (least privilege)

Yetki sırası — her zaman en alttakinden başla:

1. **Salt okuma** (inceleme, audit, teşhis, mimari çıkarımı)
2. **Workspace yazma** (yalnız gerçekten kod değişikliği gerekiyorsa)
3. **Ağ erişimi** (paket kurulumu, API, doküman çekme — ayrı gerekçe ister)
4. **Deploy / production erişimi** (yalnızca açık onayla, tek lane)

Kolaylık olsun diye geniş yetki kullanma. Kural/onay/güvenlik sınırını **atlatmak amaçlı**
bayrak veya komut asla kullanma.

### 1.2 Sadece bağımsız işi paralelleştir

**Paralel olur:**
- frontend review + backend review
- güvenlik auditi + performans auditi
- birbirinden bağımsız müşteri siteleri (Site Studio toplu üretim)
- bağımsız paketler / bağımsız failing testler
- bağımsız görseller (Instagram post + Angebot görseli)

**Paralel olmaz (pipeline gerekir):**
- D1 migration → migration'a bağlı Worker kodu
- refactor → refactor'a bağlı testler
- şema değişimi → API → frontend
- sıralı Reel/story kareleri (görsel süreklilik gerekir)
- aynı dosyaya yazan iki agent
- rakip mimari karar veren iki agent

Bağımlılık varsa **fleet değil pipeline** kur.

### 1.3 Doğrulama > özgüven

Bir agent'ın "bitti" demesi kanıt değildir. Önemli her işi en güçlü uygun kapıdan geçir:

- `npx tsc --noEmit` / typecheck
- targeted test → sonra geniş test
- lint / format
- `npm run build`
- `npx wrangler deploy --dry-run`
- D1 şema doğrulama (`schema.sql` + migration sırası)
- `git diff` okuması
- runtime smoke test (Worker `/health`, form POST, upload akışı)
- UI/görsel işte gözle kontrol

### 1.4 Kullanıcının işini koru

Yazma işleminden önce her zaman:

```bash
git status --short
git rev-parse --abbrev-ref HEAD
```

İlgisiz lokal değişiklik varsa **koru**. Kullanıcı açıkça istemedikçe ve kapsam
doğrulanmadıkça şunlar asla çalıştırılmaz:

```bash
git reset --hard
git clean -fd
git checkout -- .
rm -rf <geniş-yol>
npx wrangler d1 execute ... --command "DROP ..."
```

---

## 2. Ortam keşfi (ilk delegasyondan önce)

```bash
pwd
git rev-parse --show-toplevel 2>/dev/null || true
git status --short 2>/dev/null || true
ls package.json wrangler.toml schema.sql 2>/dev/null
```

Proje tipi tespiti:

| Bulgu | Proje tipi | Tipik kapı |
|---|---|---|
| `wrangler.toml` + `worker.js` | Cloudflare Worker API | `wrangler deploy --dry-run` |
| `wrangler.toml` + `pages/` | Pages + Worker | build + dry-run |
| `schema.sql` / `migrations/` | D1 veritabanı | şema/migration sırası |
| `vite.config.*` + React/TS | Frontend | `tsc --noEmit` + `npm run build` |
| `app.json` + Expo | Mobil | `expo-doctor`, EAS build |
| Supabase client | Supabase | RLS + policy kontrolü |

**Model / efor seçimi:**
- mekanik iş (rename, çeviri, format) → düşük–orta efor
- normal mühendislik → yüksek
- zor teşhis / mimari / güvenlik → en yüksek, ama **her lane'de değil**

Kullanıcı bir model istediyse sessizce düşürme; yoksa açıkça belirt.

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

Her delege agent **kendi başına yeterli** brief alır:

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
- wrangler.toml / package.json / schema.sql (tek sahibi var)

GEREKSİNİMLER
- <fonksiyonel gereksinim>
- <kısıt: geriye dönük uyumluluk, DSGVO, dil, marka>

SÜREÇ
1. ilgili kodu incele
2. en küçük tutarlı yamayı yaz
3. ilgisiz refactor yapma
4. kabul kontrollerini çalıştır

KABUL KONTROLLERİ
- <somut komut(lar)>

ÇIKTI
- durum: DONE | PARTIAL | BLOCKED | FAILED
- özet
- değişen dosyalar
- çalıştırılan kontroller ve sonuçları
- kalan riskler
- blocker (varsa)
```

Salt-okuma lane'lerinde `OWNS` yerine `SCOPE` yaz ve **"DOSYA DEĞİŞTİRME"** talimatını
açıkça ver.

---

## 5. Lane rolleri → Hasi KI-System eşlemesi

| Fleet lane | Hasi agent | Odak |
|---|---|---|
| Frontend | `builder` | React/Vite/Tailwind, render, state, a11y, responsive |
| Backend/API | `builder` + `backend-architect` | Worker route'ları, validation, hata yönetimi, CORS |
| Veritabanı | `backend-architect` | D1/Supabase şema, index, migration, RLS, FTS5 |
| Güvenlik (salt okuma) | `security-guardian` | auth, secret sızıntısı, injection, CSP/headers, DSGVO |
| Performans | `builder` | bundle, cache, gereksiz render, yavaş sorgu, R2 erişimi |
| QA | `qa-reviewer` | kabul kriteri, test kapsamı, Lighthouse, Almanca dil kontrolü |
| UI/UX | `designer` | hiyerarşi, okunabilirlik, marka tutarlılığı |
| Deploy | `hasi-devops` | GitHub, Pages/Workers deploy, DNS, SSL — **tek lane** |
| Doküman/müşteri metni | `hasi-customer-comms` | README, Angebot, Kundenbericht, teslim notu |

Sadece göreve gerçekten gereken lane'leri aç. 6 lane'in hepsini otomatik açma.

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

### 6.2 Ortak ağaçta yazma

Yalnızca lane'ler **tamamen ayrık** dosyalara yazıyorsa. Tek sahipli, yüksek çakışmalı dosyalar:

- `package.json`, `package-lock.json`
- `wrangler.toml`, `.dev.vars` şablonları
- `schema.sql`, `migrations/`
- `worker.js` içindeki route tablosu
- merkezi config, barrel export, üretilmiş dosyalar
- `_redirects`, `_routes.json`

Birden çok lane bu dosyalara ihtiyaç duyuyorsa: **paralel iş bittikten sonra tek entegrasyon lane'i** yapsın.

---

## 7. Fleet boyutu ve maliyet

| Boyut | Ne zaman |
|---|---|
| 2–4 lane | normal |
| 5–8 lane | büyük kod tabanı, geniş audit, toplu site üretimi |
| >8 lane | iş doğal olarak parçalanıyorsa ve ortam kaldırıyorsa |

Lane açmadan önce sor:
- Ayrı ve net bir hedefi var mı?
- Bağımsız ilerleyebilir mi?
- Bağlamı kendi içinde yeterli mi?
- Çıktısı nihai sonucu gerçekten iyileştirir mi?

Cevaplardan biri "hayır" ise **açma.** Koordinasyon maliyeti hızla artar.

---

## 8. Canlılık (liveness) ve kurtarma

Bir lane şu durumlarda takılmış olabilir: uzun süre çıktı üretmiyor, aynı adımı tekrar
ediyor, veya süreç yaşıyor ama ilerleme yok.

Yeniden denemeden önce:
1. lane çıktısını/logunu oku
2. çalışma ağacında kısmi değişiklik var mı bak (`git status --short`, `git diff`)
3. tekrar denemenin güvenli olup olmadığına karar ver

Aynı yazılabilir dizine körlemesine ikinci bir lane açma. Başarısız bir agent'ın
**hiç değişiklik bırakmadığını varsayma.**

---

## 9. Entegrasyon kapısı

Tüm yazan lane'ler bittikten sonra kalite orkestratörün sorumluluğundadır:

1. `git status --short`
2. `git diff` incelemesi
3. lane başına hedefli test
4. repo geneli typecheck
5. lint
6. entegrasyon testleri
7. `npm run build`
8. `npx wrangler deploy --dry-run` (Worker/Pages projelerinde)
9. mümkünse runtime smoke test

Kapıyı projeye göre uyarla; gereksiz pahalı test paketi çalıştırma.
**Önceden var olan hata ile fleet'in ürettiği regresyonu net biçimde ayır.**

Deploy her zaman entegrasyon kapısından **sonra**, `hasi-devops` lane'i tarafından,
tek seferde yapılır.

---

## 10. Rapor formatı

Ham agent loglarını kullanıcıya dökme. Şu formatta özetle:

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
Frontend    DONE       pages/            build PASS
Backend     DONE       worker.js         dry-run PASS
Güvenlik    BULGU      salt okuma        3 bulgu (1 kritik)
QA          DONE       tests/            18/18 PASS
```

---

## 11. Hata politikası

| Durum | Davranış |
|---|---|
| Araç/CLI yok | Neyin eksik olduğunu ve nasıl tespit edildiğini söyle; iş yapılmış gibi davranma |
| Kimlik doğrulama hatası | Hatayı bildir, tekrar tekrar deneme |
| Yetki/sandbox hatası | Hemen geniş yetkiye çıkma; önce daha dar yazılabilir dizin, kapsamlı ağ izni veya farklı mod dene |
| Test hatası | Sınıflandır: lane'in yol açtığı / önceden var olan / başka lane / ortam-bağımlılık |
| Kısmi değişiklik | Yeniden denemeden önce diff'i oku |
| Ağ yok | Sınırlamayı bildir; "auth bozuk" gibi uydurma teşhis koyma |

---

## 12. Görsel varlık delegasyonu

Görsel üretim **yetenek bağımlıdır, varsayılmaz.** Hasi ortamında yol:

1. **Higgsfield MCP** — `generate_image` / `generate_video` (kampanya, Reel, UGC)
2. **Canva MCP** — marka şablonu, Angebot görseli, brand kit
3. **hasi-social-media** skill'i — Instagram karussell (HTML → PNG, 1080x1350)
4. **gunar-angebot / gunar-campaign-pro** — Gün-Ar Market kampanyaları

Kod aracıyla (PIL vb.) sahte "üretilmiş görsel" yapma; kullanıcı gerçek görsel istediyse
uygun MCP yoksa bunu söyle.

**Brief şablonu:** kullanım amacı, konu, kompozisyon, stil, ışık, renk (marka paleti),
birebir metin, referanslar (kimlik / ürün / logo / önceki kare), korunacaklar,
kaçınılacaklar (watermark, fazladan logo, bozuk yazı), çıktı (oran, boyut, dosya adı).

**Paralellik:** bağımsız görseller paralel; süreklilik gerektiren kareler **sıralı**.

**Doğrulama:** dosya var mı, boyut/format doğru mu, logo ve fiyat doğru mu, metin doğru
yazılmış mı. Dosya boyutu kalite kanıtı değildir. Sadece hatalı varlığı yeniden üret.

---

## 13. Hazır preset'ler

### 13.1 Cloudflare full-stack audit (salt okuma, paralel)

```text
Lane A — Mimari      : Worker route yapısı, sorumluluk ayrımı, ölçeklenme
Lane B — Güvenlik    : auth, token, CORS/CSP, R2/D1 erişim sınırı, DSGVO
Lane C — Veritabanı  : şema, index, migration sırası, N+1 sorgu
Lane D — Frontend    : render, a11y, responsive, Almanca metin
Lane E — Performans  : bundle, cache, cold start, R2 transfer
Lane F — QA          : test kapsamı, kabul kriterleri
```

Bulgular birleştirilir → **kullanıcı onayı** → sadece onaylanan değişiklikler için yazan
lane açılır. Problemi anlamadan koda yazan agent açma.

### 13.2 Toplu müşteri sitesi (Site Studio)

Her müşteri sitesi **bağımsız bir lane**: kendi repo'su, kendi Pages projesi.
Ortak sahipler: marka/tasarım kararı tek lane'de, deploy tek lane'de (`hasi-devops`).

### 13.3 Büyük refactor

```text
Faz 1 — salt okuma mimari haritası
Faz 2 — refactor planı + sahiplik haritası
Faz 3 — izole yazan lane'ler (worktree)
Faz 4 — entegrasyon
Faz 5 — test/build/deploy kapısı
```

"projeyi temizle", "kodu iyileştir", "her şeyi refactor et" gibi belirsiz brief'le
çok-agent refactor **başlatma.** Önce ölçülebilir sınır tanımla.

---

## 14. Güvenlik ve gizlilik

Aşağıdakiler **asla varsayılan davranış değildir:**

- repo kurallarını, sandbox'ı veya onay mekanizmasını atlatmak
- güvenlik kontrollerini kapatmak
- prompt/log içinde secret göstermek
- özel kaynak kodu ilgisiz dış servise göndermek
- takip edilmeyen dosyaları silmek
- git geçmişini yeniden yazmak, force push
- production altyapısını veya D1 verisini yıkıcı biçimde değiştirmek

**Secret kuralı:** API key, token, parola, BitLocker key, müşteri kimlik bilgisi hiçbir
lane brief'ine yazılmaz. Wrangler secret, ortam değişkeni veya mevcut oturum kullanılır.
Örneklerde `<SECRET_FROM_PASSWORD_MANAGER>` yaz. Log'da secret geçiyorsa ham dökme, özetle.

Production'a dokunan işlerde otomatik yürütme değil, **aşamalı plan + doğrulama** kullan.

---

## 15. Karar ağacı

```text
İş birden fazla bağımsız kola ayrılıyor mu?
 ├─ Hayır → tek agent (veya doğrudan sen yap)
 └─ Evet
     ↓
Kollar birbirinin çıktısına bağlı mı?
 ├─ Evet → PIPELINE
 └─ Hayır → FLEET
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

**Başlamadan:**
- [ ] hedef net mi
- [ ] ortam ve proje tipi tespit edildi mi
- [ ] yazma varsa repo durumu temiz mi
- [ ] en dar yetki seçildi mi
- [ ] tek / pipeline / fleet kararı verildi mi
- [ ] lane sahipliği yazılı mı
- [ ] kabul kontrolleri tanımlı mı

**Çalışırken:**
- [ ] lane'ler bağımsız kaldı mı
- [ ] worktree/log/çıktı takip ediliyor mu
- [ ] ilgisiz düzenleme yapılmadı mı
- [ ] blocker dürüstçe raporlandı mı

**Bitirirken:**
- [ ] diff okundu mu
- [ ] hedefli kontroller çalıştı mı
- [ ] entegrasyon kapısı geçildi mi
- [ ] önceden var olan hatalar ayrıldı mı
- [ ] sonuç ve riskler kısa özetlendi mi

---

## 17. Bu skill bilerek şunları YAPMAZ

- sınırsız kaynak varsaymaz
- otomatik tam sistem erişimi vermez
- hataları gizlemez
- kural/onay atlamaz
- agent'ın "bitti" demesine kanıtsız güvenmez
- tek bir CLI veya model adını kalıcı varsaymaz
- bağımlı işleri paralelleştirmez
- eşzamanlı agent'ların aynı dosyaya yazmasına izin vermez
- dosya boyutunu görsel kalite kanıtı saymaz
- ham log veya secret dökmez

---

## 18. İdeal sonuç

İyi bir Hasi Fleet çalışması **sıkıcıdır:** doğru sayıda lane, net sahiplik, en az yetki,
ezilmemiş dosya, sürpriz değişiklik yok, doğrulanmış sonuç, kısa rapor.

**Hız, dikkatsiz eşzamanlılıktan değil, iyi bölümlemeden gelir.**
