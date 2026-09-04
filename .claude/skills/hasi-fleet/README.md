# hasi-fleet

Çok-agent (paralel) çalışma ve delegasyon skill'i. Kaynak: harici "codex-fleet v2"
skill'inin Hasi ortamına uyarlanmış hali.

## Uyarlama farkları

| Orijinal (codex-fleet) | Bu sürüm (hasi-fleet) |
|---|---|
| Codex CLI çağrıları (`codex exec --sandbox ...`) | Claude Code subagent'ları + Hasi KI-System'in 11 agent'ı |
| Genel sandbox bayrakları | Salt okuma → workspace yazma → ağ → deploy yetki merdiveni |
| Genel test/build kapıları | `tsc --noEmit`, `npm run build`, `wrangler deploy --dry-run`, D1 şema kontrolü |
| Genel "shared files" listesi | `wrangler.toml`, `schema.sql`, `worker.js` route tablosu, `_routes.json`, `_redirects` |
| Codex image-generation yeteneği | Higgsfield MCP, Canva MCP, `hasi-social-media`, `gunar-*` skill'leri |
| İngilizce | Türkçe (Hamdi'nin çalışma dili), Almanca/Türkçe tetikleyiciler |
| React/Next/Supabase preset | Cloudflare Pages + Workers + D1 + R2 preset, Site Studio toplu üretim preset'i |

## Kurulum

Bu skill'i tüm projelerde kullanmak için:

```bash
mkdir -p ~/.claude/skills/hasi-fleet
cp .claude/skills/hasi-fleet/SKILL.md ~/.claude/skills/hasi-fleet/
```

Ya da claude.ai → Skills üzerinden hesap seviyesinde yükle (diğer `hasi-*` skill'leri
gibi senkronlansın). Repo içinde bırakılırsa yalnızca bu proje için geçerli olur.
