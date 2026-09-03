# NOIR — Fine Dining

Demo-Website für **Hasi Site Studio**. Ein erfundenes Fine-Dining-Restaurant in
Stuttgart, gebaut als Verkaufsstück: Sie zeigen einem Gastronomen, einem Hotel
oder einem Handwerksbetrieb in den ersten drei Sekunden, was eine Website sein
kann, die nicht nach Baukasten aussieht.

> **Alles auf dieser Seite ist erfunden** — Name, Küchenchef, Anschrift,
> Telefonnummer, Preise, Erzeuger. Impressum und Datenschutzerklärung sind oben
> sichtbar als Demo-Inhalt gekennzeichnet. Für ein echtes Haus müssen beide
> Seiten vollständig ersetzt und rechtlich geprüft werden.

---

## Schnellstart

Voraussetzung: **Node 20 LTS oder neuer** (entwickelt mit Node 22).

```bash
cd noir
npm install
npm run dev        # http://localhost:5173
```

| Befehl | Wirkung |
| --- | --- |
| `npm run dev` | Entwicklungsserver mit Hot Reload |
| `npm run build` | Typprüfung (App **und** Pages-Function) + Produktions-Build nach `dist/` |
| `npm run preview` | Gebaute Seite lokal ausliefern |
| `npm run lint` | ESLint, keine Warnungen erlaubt |
| `npm run format` | Prettier über `src/` |
| `npm run images` | Bilder laden, in WebP wandeln, Blur-Vorschauen schreiben |
| `npm run og` | `public/og.jpg` und `public/apple-touch-icon.png` neu erzeugen |

---

## Bilder austauschen — der wichtigste Schritt

Im Repository liegen **prozedurale Platzhalter**: dunkle, unscharfe
Lichtstimmungen im Farbklang der Seite. Sie tragen das Layout, sind aber keine
Fotos. Die Bausandbox, in der diese Seite entstanden ist, hat keinen Zugriff auf
Unsplash — deshalb der Zwischenstand.

So kommen echte Fotos hinein:

1. `scripts/image-manifest.mjs` öffnen. Dort steht für jedes der 22 Bilder ein
   Eintrag mit `name`, Seitenverhältnis und `url`.
2. Bild auf unsplash.com suchen → Rechtsklick auf das Foto → **Grafikadresse
   kopieren**. Die Adresse beginnt mit `https://images.unsplash.com/photo-…`.
   Alles hinter dem `?` können Sie weglassen, die Parameter setzt das Skript.
3. `npm run images -- --force` ausführen.
4. `npm run og` ausführen, damit die Social-Media-Vorschau das echte Hero-Bild
   zeigt.
5. `public/img/` **und** `src/data/generated-lqip.ts` einchecken.

Das Skript ist nachsichtig: Was sich nicht laden lässt, bekommt automatisch
wieder einen Platzhalter, und am Ende steht eine Liste, welche Bilder betroffen
waren. Die Seite ist also nie kaputt, auch wenn eine Adresse veraltet ist.

Nützliche Schalter:

```bash
npm run images                  # nur fehlende Bilder holen
npm run images -- --force       # alle neu holen
npm run images -- --offline     # ohne Netz, nur Platzhalter erzeugen
```

Jedes Bild wird in **640 / 1280 / 1920 px als WebP** abgelegt und bekommt eine
20 px breite Base64-Vorschau, die als Unschärfe liegt, bis das echte Bild
dekodiert ist. Breite und Höhe stehen fest im Markup — dadurch springt beim
Laden nichts (CLS ≈ 0).

---

## Deploy auf Cloudflare Pages

Diese Demo liegt im Unterordner `noir/` eines Repositories, das im Wurzelver-
zeichnis eine andere Anwendung enthält. Das **Stammverzeichnis** in den
Build-Einstellungen ist deshalb entscheidend:

| Einstellung | Wert |
| --- | --- |
| Framework preset | None / Vite |
| **Root directory** | `noir` |
| Build command | `npm run build` |
| Build output directory | `dist` |
| Node version | `20` oder höher (`NODE_VERSION` als Variable setzen) |

Pages erkennt `noir/functions/` automatisch und stellt `/api/reserve` bereit.
`public/_redirects` sorgt dafür, dass `/impressum` und `/datenschutz` auch beim
direkten Aufruf funktionieren; Functions werden davor ausgewertet und bleiben
unberührt. `public/_headers` setzt Cache- und Sicherheits-Header inklusive einer
engen Content-Security-Policy — die Seite lädt ausschließlich eigene Ressourcen.

### Umgebungsvariablen

Alle **optional**. Ohne sie läuft die Demo vollständig; das Formular
protokolliert die Anfrage und antwortet mit einer Referenznummer.

| Variable | Zweck |
| --- | --- |
| `TURNSTILE_SECRET` | Aktiviert die Turnstile-Prüfung in der Function. Ist sie nicht gesetzt, wird die Prüfung übersprungen. |
| `RESEND_API_KEY` | Für den echten E-Mail-Versand (Block in `functions/api/reserve.ts` einkommentieren). |
| `RESERVATION_INBOX` | Zieladresse der Reservierungsmails. |

Als Secret anlegen, nie ins Repository schreiben.

### Lokal mit echter Function testen

`npm run preview` liefert nur die statischen Dateien aus — `/api/reserve`
antwortet dort nicht. Für den vollständigen Durchlauf:

```bash
npm run build
npx wrangler pages dev dist --compatibility-date=2024-11-01
```

---

## Wie die Seite gebaut ist

### Eine Schleife für alles

Lenis besitzt die einzige `requestAnimationFrame`-Schleife: sie wird vom
GSAP-Ticker getrieben und meldet jeden Scroll an `ScrollTrigger.update()`.
Dadurch laufen Smoothing und Scroll-Animationen garantiert im selben Frame.

Der Fortschritt für die WebGL-Szene liegt in einem veränderlichen Modul-Objekt
(`src/app/sceneProgress.ts`), nicht in React-State. ScrollTrigger schreibt dort
bis zu 60-mal pro Sekunde hinein, `useFrame` liest daraus — **kein einziger
Re-Render pro Scroll-Frame**. Dasselbe Muster trägt die Fortschrittsschiene im
Menü: der Gang-Index läuft über State (sieben Wechsel), die feine Bewegung über
direkte Stil-Zuweisungen.

GSAP-Plugins werden beim **Import** des Moduls registriert, nicht in einem
Effekt. React führt Effekte von innen nach außen aus; eine Registrierung im
Provider käme nach dem ersten `ScrollTrigger.create()` einer Sektion.

### Drei Stufen statt einer

| Gerät | Hero | Raum |
| --- | --- | --- |
| WebGL2, ≥ 4 Kerne | 3-D-Szene | 3-D-Szene, dreht langsam |
| Bewegung reduziert | Poster | 3-D-Szene, dreht nicht |
| kein WebGL2 / schwaches Gerät | Poster | Hinweis + Galerie |

three.js liegt in einem eigenen Chunk hinter `React.lazy` und wird auf den
unteren beiden Stufen **nie geladen**. Der Frame-Loop hält an, sobald der Canvas
den Sichtbereich verlässt oder der Tab in den Hintergrund geht.

Beide Szenen sind vollständig prozedural: der Teller ist ein Lathe-Profil, der
Rauch eine Punktwolke mit eigenem Shader, das Umgebungslicht besteht aus drei
`Lightformer`n statt einer HDR-Datei. Es wird **keine externe 3-D-Datei
geladen** — der Raum liegt bei rund 5.000 Dreiecken.

### Reduzierte Bewegung

`prefers-reduced-motion: reduce` schaltet die Seite vollständig um: kein Lenis,
kein Pinning, kein Scrubbing, keine Auto-Rotation, kein Preloader, kein eigener
Cursor. Manifest und Menü rendern dann als schlichte Listen — der gesamte Inhalt
bleibt erreichbar, nichts verschwindet.

### Barrierefreiheit

Semantische Landmarken, „Zum Inhalt springen“ als erster Fokus, Fokusring in
Messing, echte `<label>` an jedem Formularfeld, Fehlermeldungen mit
`role="alert"`. Lightbox und Menü-Overlay fangen den Fokus, schließen mit
Escape, sperren den Hintergrund und geben den Fokus danach zurück. Die
Hotspot-Infokarte des 3-D-Raums liegt im DOM statt im Canvas und ist damit
vorlesbar; dieselben drei Orte stehen zusätzlich als Liste darunter. Die
Wortmasken der Überschriften geben den Text als `sr-only`-Kopie aus, damit kein
Wort einzeln vorgelesen wird.

---

## Was geprüft ist — und was Sie noch prüfen sollten

**Automatisiert geprüft** (Chromium, Playwright, gegen den Produktions-Build):

- Hero rendert die WebGL-Szene; bei reduzierter Bewegung erscheint das Poster
  und der Preloader entfällt
- kein horizontales Überlaufen bei 360 px Breite, keine Konsolenfehler
- Formular: alle Pflichtfeld-Meldungen auf Deutsch, Montag wird abgewiesen,
  Personenzähler arbeitet
- Lightbox: Fokusfalle, Pfeiltasten, Escape, Scroll-Sperre wird sauber gelöst
- Menü-Overlay: öffnet, schließt mit Escape
- `/impressum` und `/datenschutz` erreichbar, auch beim direkten Aufruf
- Pages-Function gegen sechs Fälle: gültig, Montag, Vergangenheit, leere
  Pflichtfelder, zu viele Personen, gefüllter Honigtopf

**Bitte lokal nachmessen** — dafür fehlten in der Bauumgebung Browser-Profiling
und echte Geräte:

1. **Lighthouse** (Chrome DevTools → Lighthouse → Mobile, gegen
   `npm run preview` oder die Pages-URL). Zielwerte: Performance ≥ 85,
   Barrierefreiheit ≥ 95, Best Practices ≥ 95, SEO ≥ 95.
2. **60 fps im Menü und im 3-D-Raum** auf Ihrem Notebook (DevTools →
   Performance, während des gepinnten Scrollens aufzeichnen).
3. **Mobile Safari** auf einem echten iPhone: `100svh` im Hero, Trägheitsscroll
   mit Lenis, das Datumsfeld.
4. **Reservierung Ende zu Ende** mit `npx wrangler pages dev dist`.

Erst danach würde ich die Seite einem Kunden zeigen.

---

## Bewusst nicht enthalten (nächste Ausbaustufe)

Der Auftrag war eng gefasst; diese Punkte gehören in eine spätere Runde:

- **Sprachumschalter** (DE/EN) — betrifft Texte, Routen und `hreflang`
- **CMS-Anbindung**, damit das Menü ohne Deploy änderbar wird (Sanity oder
  Cloudflare D1 mit kleinem Admin)
- **Echte Verfügbarkeitsprüfung** statt Anfrageformular: Tischplan, Kontingente
  pro Abend, Bestätigungs- und Absagemails
- **Turnstile scharf schalten** (Widget im Formular, Secret in Pages)
- **Analytics ohne Cookies**, falls gewünscht (Cloudflare Web Analytics) — dann
  muss die Datenschutzerklärung ergänzt werden
- **Bildersatz durch eine echte Foto-Produktion**; die Unsplash-Auswahl trägt
  eine Demo, aber kein Haus

---

Website: **Hasi Site Studio** — hasi-elektronic.de

---

## Anhang: Einzeldatei-Fassung für die Vorführung

```bash
npm run build:single
# -> dist-single/noir-einzeldatei.html (rund 2,6 MB)
```

Eine einzige HTML-Datei mit allem darin: Skript, Stile, Schriften und alle 66
Bildvarianten als data-URI. Zum Mailen an einen Kunden, für den Stick oder für
den Termin ohne WLAN — Doppelklick genügt, kein Server nötig.

Bewusste Unterschiede zur gehosteten Fassung:

- Routing über den Hash (`#/impressum` statt `/impressum`), weil ohne Server
  kein Pfad ausgeliefert werden kann
- keine Code-Aufteilung: three.js liegt im selben Bündel und wird immer
  geladen, auch auf Geräten, die sonst das Poster bekämen
- `/api/reserve` antwortet nicht — das Formular zeigt einen Verbindungsfehler
  statt der Bestätigungskarte

Für Kunden und Messungen zählt weiterhin `npm run build`.
