# hasi-fleet

Çok-agent (paralel) çalışma, delegasyon ve doğrulama skill'i.
Kaynak: harici **codex-fleet v2** skill'i — Hasi ortamına uyarlanmış ve
**platformdan bağımsız** hale getirilmiş sürümü.

## Sürüm geçmişi

- **2.0.0** — platformdan bağımsız yapı: yetenek tespiti (Adım 0), çekirdek + referans
  dosyaları ayrımı, her platform için adaptör, Claude dışı araçlar için İngilizce
  kopyala-yapıştır sürüm, kurulum rehberi.
- **1.0.0** — codex-fleet v2'nin Hasi/Cloudflare ortamına ilk uyarlaması.

## Uyarlama farkları (orijinale göre)

| Orijinal (codex-fleet) | Bu sürüm (hasi-fleet) |
|---|---|
| Codex CLI'ye sabitlenmiş (`codex exec --sandbox ...`) | Yetenek tespitiyle **her ortam**: Claude Code, claude.ai, Cursor, Codex CLI, ChatGPT/Grok, n8n |
| Tek çalışma modu varsayımı | Tam fleet / seri fleet / danışman modu |
| Genel sandbox bayrakları | Yetki merdiveni: salt okuma → workspace yazma → ağ → deploy |
| Genel test/build kapıları | Yığın bazlı kapı tablosu (`references/stacks.md`) |
| Genel "shared files" listesi | Yığın bazlı tek sahipli dosya listesi |
| Codex image-generation | Ortamda gerçek görsel yeteneği varsa; Hasi'de Higgsfield/Canva/`hasi-social-media` |
| İngilizce, tek dosya | Türkçe çekirdek + referanslar + İngilizce taşınabilir sürüm |

## Korunanlar

Lane sahiplik sözleşmesi (OWNS / DO NOT TOUCH), git worktree izolasyonu, liveness kurtarma,
entegrasyon kapısı, yapılandırılmış rapor formatı, hata politikası, secret kuralları.

## Kurulum

Bkz. `INSTALL.md` — Claude Code (proje/kullanıcı), claude.ai hesap yüklemesi (zip),
Cursor rules, Codex CLI, ChatGPT/Grok özel talimat, n8n.
