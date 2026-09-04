# Platform adaptörleri

Çekirdek doktrin (`SKILL.md`) her yerde aynıdır. Değişen tek şey **delegasyonun nasıl
yapıldığıdır.** Bulunduğun ortamı tespit et, karşılık gelen bölümü uygula.

---

## 1. Claude Code (CLI, desktop, web, IDE eklentisi)

**Yetenek:** gerçek paralel subagent + shell + dosya + MCP → **tam fleet.**

- Bağımsız lane'leri **tek mesajda birden çok Task/Agent çağrısı** olarak başlat; böylece
  gerçekten paralel koşarlar. Sıralı çağrı = paralellik yok.
- Salt-okuma lane'leri için arama/inceleme odaklı agent tipi, yazan lane'ler için tam yetkili
  agent tipi seç.
- Uzun süren komutları arka planda çalıştır, log dosyasını lane başına ayır:
  `/tmp/fleet-<lane>.log`.
- Proje seviyesinde kullanmak için skill'i `.claude/skills/hasi-fleet/`, tüm projeler için
  `~/.claude/skills/hasi-fleet/` altına koy (bkz. `INSTALL.md`).
- Alt agent'a **bu dosyayı okutma zorunluluğu yok**; lane brief'i kendi içinde yeterlidir.

**Uzak/bulut oturumu (claude.ai/code):** konteyner geçicidir — iş biter bitmez commit + push.
Worktree'ler oturumla birlikte kaybolur.

---

## 2. claude.ai (sohbet, Projects, Cowork)

**Yetenek:** dosya/analiz aracı var, shell çoğu zaman yok → **seri fleet veya danışman modu.**

- Skill'i hesap seviyesine yükle (bkz. `INSTALL.md` §2) → tüm sohbetlerde tetiklenir.
- Lane'leri sırayla çalıştır; her lane'in çıktısını bir sonrakine **özet** olarak taşı, ham log
  taşıma.
- Kod çalıştırılamıyorsa kabul komutlarını **üret ve kullanıcıya ver**; "test geçti" deme.
- Uzun fleet çalışmalarında her lane sonunda kısa durum tablosu ver, bağlam şişmesin.

---

## 3. Cursor / Windsurf / benzeri IDE agent'ları

**Yetenek:** dosya + shell, sınırlı veya tek agent → **seri fleet.**

- Lane brief'ini doğrudan sohbet penceresine yapıştır; `OWNS` / `DO NOT TOUCH` listesini
  **her lane'de tekrarla** (bu araçlar bağlamı agresif kırpar).
- Paralellik gerekiyorsa: her lane için ayrı IDE penceresi + ayrı `git worktree` dizini.
- Kalıcı kural olarak kurmak için `SKILL.md` özetini proje kuralları dosyasına koy
  (`.cursorrules`, `.windsurfrules` veya aracın rules dizini).

---

## 4. Codex CLI / başka bir agentic CLI

**Yetenek:** shell + dosya + sandbox modları → **tam fleet (harici süreç).**

Şablon (kurulu olduğu doğrulanırsa):

```bash
# salt okuma lane
codex exec --sandbox read-only -C "$WORKDIR" "<LANE BRIEF>"

# yazan lane
codex exec --sandbox workspace-write -C "$WORKDIR" "<LANE BRIEF>"
```

Paralel:

```bash
codex exec ... "LANE A" > /tmp/fleet-A.log 2>&1 & PID_A=$!
codex exec ... "LANE B" > /tmp/fleet-B.log 2>&1 & PID_B=$!
wait "$PID_A" "$PID_B"
```

- Önce `command -v codex` ile varlığını doğrula; yoksa uydurma.
- Yalnızca **kendi başlattığın PID'leri** yönet; başka süreçleri öldürme.
- Sürüm/model adını sabit varsayma; `--help` ile doğrula.

---

## 5. ChatGPT / Grok / Gemini / düz sohbet

**Yetenek:** genelde sadece metin → **danışman modu.**

- `references/portable-prompt.md` içindeki İngilizce sürümü sistem talimatı / özel talimat
  olarak yapıştır.
- Her "lane" ayrı bir sohbet penceresidir; sonuçları sen birleştirirsin.
- Bu araçlar dosya yazmaz: çıktı = lane brief'leri, sahiplik haritası, kabul komut listesi,
  bulgu raporu. Uygulama Claude Code veya IDE tarafında yapılır.

---

## 6. n8n / otomasyon zinciri

**Yetenek:** API çağrısı + webhook → **programatik fleet.**

- Her lane = bir HTTP node (model API çağrısı), lane brief'i prompt gövdesi.
- Bağımsız lane'ler paralel branch; bağımlı olanlar sıralı node.
- Sonuçları birleştiren bir "entegrasyon" node'u ekle; doğrulama komutlarını çalıştıran ayrı
  bir runner (self-hosted) olmadan "doğrulandı" deme.
- Secret'ları n8n credential store'da tut, prompt gövdesine yazma.

---

## 7. İşletim sistemi farkları

- `git worktree`, `git status`, `git diff` her platformda aynı.
- Yol ayracı ve kabuk farkı: Windows'ta PowerShell kullanıyorsan `&&` yerine `;`,
  `$VAR` yerine `$env:VAR`.
- macOS'a özel yardımcılar (ör. `caffeinate`) **önkoşul değildir**; varsa kullan:
  `command -v caffeinate >/dev/null 2>&1 && caffeinate -i <komut>`.
- Bir platformda çalışan komutun diğerinde aynı davrandığını varsayma.
