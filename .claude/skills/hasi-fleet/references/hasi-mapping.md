# Hasi ortamına özel eşleme

Bu dosya **yalnızca Hasi Elektronic ortamında** geçerlidir. Skill'i genel/üçüncü parti bir
platformda kullanacaksan bu dosyayı yükleme — `references/portable-prompt.md` yeterlidir.

---

## 1. Lane → Hasi KI-System agent eşlemesi

Claude Code `.claude/agents/` altındaki 11 agent'lı sistem:

| Fleet lane | Hasi agent | Not |
|---|---|---|
| Orkestrasyon | `hasi-orchestrator` | brief analizi, delegasyon, denetim |
| Frontend | `builder` | React, Vue, Vite, Tailwind, Flutter |
| Backend/API | `builder` + `backend-architect` | Worker route'ları, validation, CORS |
| Veritabanı | `backend-architect` | D1, multi-tenant, FTS5, Supabase RLS |
| Güvenlik (salt okuma) | `security-guardian` | DSGVO, auth, CSP/header, backup, credential rotasyonu |
| Performans | `builder` | bundle, cache, cold start, R2 transfer |
| QA | `qa-reviewer` | Lighthouse, a11y, **Almanca dil kontrolü**; onayı olmadan deploy yok |
| UI/UX | `designer` | konsept, logo, layout, animasyon, marka |
| Deploy | `hasi-devops` | GitHub, Pages/Workers, DNS, SSL — **tek lane** |
| Planlama | `planner` | sprint, öncelik, "hangisi ciro getirir" |
| Araştırma | `researcher` | pazar, rakip, domain (RDAP), regülasyon |
| Müşteri metni / doküman | `hasi-customer-comms` | Angebot, Arbeitsbericht, Kundenbericht, PDF |

**Kural:** `qa-reviewer` onayı olmadan `hasi-devops` deploy etmez.

---

## 2. Diğer Hasi skill'leriyle ilişki

| Skill | Rol | Fleet ile ilişki |
|---|---|---|
| `hasi-os` | Ana router — *ne* yapılacağını yönlendirir | Fleet, `hasi-os`'un seçtiği işi *kaç lane'le* yapacağını belirler |
| `hasi-context` | Kişi/proje/müşteri arka planı | Lane brief'ine bağlam çekerken kaynak |
| `hasi-site-studio` | Müşteri sitesi üretimi | Toplu üretimde her site = bir lane |
| `hasi-app-creator` | Expo cross-platform app | EAS build'ler paralel açılmaz |
| `hasi-angebot` / `hasi-arbeitsbericht` / `hasi-kundenbericht` | Belge üretimi | Doküman lane'i bunları çağırır |
| `hasi-social-media` | Instagram/Facebook içerik + karussell | Görsel lane'inin ana aracı |
| `hasi-notion-wissensbasis` | Kalıcı bilgi | Fleet sonucu önemliyse kaydetmeyi öner |
| `hasi-anwalt`, `hasi-dxf-generator`, `hasi-meta-ads` | Uzman alanlar | Fleet'e sokma; tek agent işi |

---

## 3. Görsel varlık araç sırası

1. **Higgsfield MCP** — `generate_image`, `generate_video` (kampanya, Reel, UGC)
2. **Canva MCP** — marka şablonu, brand kit, Angebot görseli
3. **`hasi-social-media`** — Instagram karussell (HTML → PNG, 1080x1350)
4. **`gunar-angebot` / `gunar-campaign-pro`** — Gün-Ar Market kampanyaları

Sıralı Reel kareleri **paralel üretilmez.** Bağımsız postlar paralel üretilebilir.

---

## 4. Teknik ortam varsayılanları

- **Ana mimari:** Cloudflare Pages (frontend) + Worker (API) + D1 (DB) + R2 (dosya)
- **Repo:** GitHub org `hasi-elektronic`
- **Deploy aracı:** Wrangler CLI; canlıya çıkan her şey `hasi-devops` lane'inden geçer
- **Otomasyon:** n8n (self-hosted), Resend (mail), Stripe (ödeme)
- **Bağlı MCP'ler:** Notion, Gmail, Google Drive, Canva, Cloudflare, Supabase, Microsoft 365,
  n8n, Shopify, Stripe, Malwarebytes, Higgsfield, GitHub

---

## 5. Müşteri işine dokunan lane'lerde dil ve marka kuralları

- Müşteri metni: **Almanca B1–B2**, kısa cümle, müşteriye `Sie`
- Hamdi ile iletişim: sorunun dilinde (Türkçe soru → Türkçe cevap)
- Varsayılan işçilik: **96,00 € netto** (asla 84 €); net/brüt açık yazılır
- Kesin olmayan teşhis kesinmiş gibi yazılmaz; korku/satış baskısı dili yok
- Lisans anahtarı, parola, BitLocker key, erişim kodu müşteri metnine **girmez**

---

## 6. Gizlilik uyarısı

Bu dosya müşteri, fiyat ve iç mimari bilgisi içerir. Üçüncü parti bir platforma (ChatGPT,
Grok, ajans, harici geliştirici) aktarma. Aktarım gerekiyorsa önce bu dosyayı çıkar.
