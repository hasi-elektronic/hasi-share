# Teknoloji yığını → kabul kapıları ve tek sahipli dosyalar

Proje tipini tespit et, o satırın kapılarını kullan. Bilinmeyen yığında: `README`,
`package.json` script'leri veya CI dosyasındaki komutları kaynak al — komut uydurma.

---

## Tespit tablosu

| Bulgu | Proje tipi |
|---|---|
| `wrangler.toml` + `worker.js` / `src/index.ts` | Cloudflare Worker API |
| `wrangler.toml` + `pages/` veya `dist/` | Cloudflare Pages + Worker |
| `schema.sql`, `migrations/` | D1 / SQL veritabanı |
| `vite.config.*` + React/TS | Vite frontend |
| `next.config.*` | Next.js |
| `app.json` + `eas.json` | Expo / React Native |
| `supabase/` veya Supabase client | Supabase |
| `composer.json`, `wp-content/` | WordPress |
| `requirements.txt`, `pyproject.toml` | Python |
| `*.ps1`, GPO/AD script'leri | Windows/IT operasyon |

---

## Kabul kapıları

| Yığın | Hedefli kapı | Geniş kapı |
|---|---|---|
| Cloudflare Worker/Pages | `npx wrangler deploy --dry-run` | `npm run build` + smoke test (`/health`, upload akışı) |
| D1 / SQL | migration sırası + `schema.sql` diff okuması | staging DB'de dry-run; **production'da asla** |
| Vite / React / TS | `npx tsc --noEmit` | `npm run build`, `npm test` |
| Next.js | `npx tsc --noEmit` | `npm run build` |
| Expo / RN | `npx expo-doctor` | EAS build (yalnız gerekliyse — pahalı) |
| Supabase | RLS/policy okuması, tip üretimi | migration + policy testi |
| WordPress | PHP lint, tema/eklenti aktivasyon testi | staging'de sayfa render kontrolü |
| Python | `python -m compileall`, `ruff`/`flake8` | `pytest` |
| Windows/IT ops | komutu `-WhatIf` / dry-run ile çalıştır | test cihazında doğrulama, **production'a önce yedek** |
| Statik site / HTML | link ve asset kontrolü | Lighthouse, a11y kontrolü |

**Kural:** hedefli kapı önce, geniş kapı sonra. Pahalı geniş paketleri gereksiz çalıştırma.

---

## Tek sahipli (yüksek çakışmalı) dosyalar

Bu dosyalara **tek lane** yazar; birden çok lane ihtiyaç duyuyorsa paralel iş bitince
**tek entegrasyon lane'i** düzenler.

**Her projede:**
`package.json` · `package-lock.json` / `pnpm-lock.yaml` / `yarn.lock` · `tsconfig.json` ·
`.env` şablonları · CI workflow dosyaları · üretilmiş (generated) dosyalar

**Cloudflare:** `wrangler.toml` · `_routes.json` · `_redirects` · `worker.js` içindeki route
tablosu · D1 binding tanımları

**Veritabanı:** `schema.sql` · `migrations/` (sıra numarası çakışması en sık hata)

**Frontend:** router tanımı · barrel export (`index.ts`) · tema/tasarım token dosyası ·
i18n sözlükleri

**Expo:** `app.json` · `eas.json`

**WordPress:** `functions.php` · tema `style.css` başlığı

---

## Yığına özel tuzaklar

- **Cloudflare:** Worker bundle limiti; `nodejs_compat` bayrağı; D1 tek yazıcı davranışı;
  R2 anahtar isimlendirmesi. Deploy'u tek lane yapar, `--dry-run` olmadan canlıya çıkma.
- **D1/SQL:** iki lane aynı numaralı migration üretirse sessizce çakışır — numara sahipliğini
  önceden dağıt.
- **Vite/TS:** `tsc --noEmit` build'i geçen tip hatasını yakalar; sadece build'e güvenme.
- **Expo:** EAS build dakikalarca sürer ve kotalıdır — fleet içinde paralel EAS build açma.
- **Supabase:** RLS kapalı tablo = güvenlik bulgusu; salt-okuma güvenlik lane'i bunu kontrol eder.
- **WordPress:** eklenti güncellemesi ile tema özelleştirmesi aynı anda değiştirilmez.
