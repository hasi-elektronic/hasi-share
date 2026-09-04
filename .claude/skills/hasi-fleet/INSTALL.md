# Kurulum — her platformda kullanım

Skill klasörü:

```
hasi-fleet/
├── SKILL.md                       # çekirdek doktrin (platformdan bağımsız)
├── INSTALL.md                     # bu dosya
├── README.md                      # uyarlama notu
└── references/
    ├── platforms.md               # Claude Code, claude.ai, Cursor, Codex, ChatGPT, n8n
    ├── stacks.md                  # proje tipi → kabul kapıları, tek sahipli dosyalar
    ├── hasi-mapping.md            # Hasi KI-System agent'ları (ÖZEL — dışarı verme)
    └── portable-prompt.md         # İngilizce kopyala-yapıştır sürüm
```

---

## 1. Claude Code — tüm projeler (önerilen)

```bash
mkdir -p ~/.claude/skills
cp -r .claude/skills/hasi-fleet ~/.claude/skills/
```

Yeni oturumda otomatik yüklenir, her repoda tetiklenir.

## 2. Claude Code — sadece tek proje

Klasörü olduğu gibi projenin `.claude/skills/` altında bırak (bu repoda zaten öyle).
Proje seviyesi, kullanıcı seviyesini ezer.

## 3. claude.ai / Cowork — hesap seviyesi (mobil ve web dahil)

Klasörü zip'le ve claude.ai → Settings → Capabilities → Skills → Upload ile yükle:

```bash
cd .claude/skills && zip -r hasi-fleet.zip hasi-fleet -x '*.DS_Store'
```

Yüklendikten sonra diğer `hasi-*` skill'leri gibi tüm sohbetlere ve projelere senkronlanır.

> Yüklemeden önce karar ver: `references/hasi-mapping.md` müşteri/fiyat bilgisi içerir.
> Kendi hesabın için sorun değil; paylaşılacak bir kopya hazırlıyorsan bu dosyayı çıkar:
> `zip -r hasi-fleet-public.zip hasi-fleet -x 'hasi-fleet/references/hasi-mapping.md'`

## 4. Cursor / Windsurf / IDE agent'ları

`SKILL.md`'in 1, 4, 6, 9 ve 14. bölümlerini proje kuralları dosyasına koy
(`.cursorrules`, `.windsurfrules` veya aracın rules dizini). Tam metin gerekiyorsa
dosyayı repoda tut ve agent'a "önce `.claude/skills/hasi-fleet/SKILL.md` dosyasını oku" de.

## 5. Codex CLI veya başka agentic CLI

`references/portable-prompt.md` içeriğini sistem talimatı olarak ver, lane çalıştırma
şablonları için `references/platforms.md` §4.

## 6. ChatGPT / Grok / Gemini

`references/portable-prompt.md` bloğunu özel talimat (custom instructions) alanına yapıştır.
Bu sürüm bilinçli olarak müşteri, fiyat ve iç mimari bilgisi **içermez**.

## 7. n8n / otomasyon

Lane brief'ini prompt gövdesi olarak kullan, bağımsız lane'leri paralel branch yap.
Detay: `references/platforms.md` §6.

---

## Güncelleme

Tek kaynak bu repodur. Değişiklik sonrası kopyaları tazele:

```bash
cp -r .claude/skills/hasi-fleet ~/.claude/skills/     # Claude Code
cd .claude/skills && zip -r hasi-fleet.zip hasi-fleet # claude.ai yeniden yükleme
```
