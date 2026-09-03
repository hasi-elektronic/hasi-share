#!/usr/bin/env node
/**
 * Baut die Seite in eine einzige HTML-Datei.
 *
 *   npm run build:single
 *
 * Gedacht für die Vorführung ohne Server und ohne Netz: eine Datei, die man
 * per Mail verschickt oder auf einen Stick legt und beim Kunden im Browser
 * öffnet. Schriften, Skript, Stile und alle 66 Bildvarianten stecken als
 * data-URI darin.
 *
 * Unterschiede zur gehosteten Fassung:
 *   - Routing über den Hash (#/impressum statt /impressum), weil ohne Server
 *     kein Pfad ausgeliefert werden kann
 *   - keine Code-Aufteilung: three.js liegt im selben Bündel und wird immer
 *     geladen, auch auf Geräten, die das Poster bekämen
 *   - /api/reserve antwortet nicht; das Formular meldet einen Verbindungs-
 *     fehler statt der Bestätigungskarte
 *
 * Für den echten Betrieb gilt weiterhin `npm run build`.
 */
import { readFile, readdir, writeFile, mkdir } from 'node:fs/promises'
import path from 'node:path'

const DIST = path.resolve('dist-single')
const IMG_DIR = path.resolve('public/img')
const OUT = path.join(DIST, 'noir-einzeldatei.html')

/** `</script>` im Bundle würde den Inline-Block vorzeitig beenden. */
const escapeScript = (code) => code.replace(/<\/script/gi, '<\\/script')

async function main() {
  const html = await readFile(path.join(DIST, 'index.html'), 'utf8')

  const jsMatch = html.match(/<script[^>]+src="([^"]+\.js)"/)
  const cssMatch = html.match(/<link[^>]+href="([^"]+\.css)"[^>]*>/)
  if (!jsMatch?.[1] || !cssMatch?.[1]) {
    throw new Error('Skript- oder Stil-Datei nicht gefunden — lief `vite build --config vite.config.single.ts`?')
  }

  const js = await readFile(path.join(DIST, jsMatch[1].replace(/^\//, '')), 'utf8')
  const css = await readFile(path.join(DIST, cssMatch[1].replace(/^\//, '')), 'utf8')

  if (/<\/style/i.test(css)) {
    throw new Error('Die CSS-Datei enthält </style — das würde den Inline-Block zerreißen.')
  }

  // --- Bilder einsammeln -------------------------------------------------
  const dateien = (await readdir(IMG_DIR)).filter((name) => name.endsWith('.webp'))
  const register = {}
  let bildBytes = 0

  for (const datei of dateien) {
    const buffer = await readFile(path.join(IMG_DIR, datei))
    bildBytes += buffer.length
    // "dish-01-1280.webp" -> Schlüssel "dish-01-1280"
    register[datei.replace(/\.webp$/, '')] = `data:image/webp;base64,${buffer.toString('base64')}`
  }

  // Kurzer Name statt des SEO-Titels: die Datei taucht in Übersichten und
  // Tableisten auf, dort trägt der Name mehr als die Ortsangabe dahinter.
  const titel = 'NOIR Fine Dining'

  // Der Artifact-Wrapper liefert <!doctype>, <html>, <head> und <body>.
  // Deshalb nur der Inhalt — und der Titel zuerst, er wird vorne gesucht.
  // Die Zeichensatz-Angabe muss ganz vorne stehen: wird die Datei direkt vom
  // Dateisystem oder von einem Server ohne charset-Kopfzeile geöffnet, rät der
  // Browser sonst Latin-1 und aus „—“ wird „â€\u2014“.
  const out = `<meta charset="utf-8">
<title>${titel}</title>

<style>
  /* Vor allem anderen: kein weißer Blitz. */
  html { background: #0a0a0b; }
  body { margin: 0; background: #0a0a0b; color: #f4f1ea; }
</style>

<style>
${css}
</style>

<div id="root"></div>

<script>
/* Bildregister der Einzeldatei-Fassung — siehe src/lib/imageRegistry.ts */
window.__NOIR_IMG__ = ${escapeScript(JSON.stringify(register))};
</script>

<script type="module">
${escapeScript(js)}
</script>
`

  await mkdir(DIST, { recursive: true })
  await writeFile(OUT, out, 'utf8')

  const kb = (n) => `${(n / 1024).toFixed(0)} kB`
  console.log(`\n${path.relative(process.cwd(), OUT)} geschrieben`)
  console.log(`  Skript ${kb(js.length)} · Stile ${kb(css.length)} · ${dateien.length} Bilder ${kb(bildBytes)}`)
  console.log(`  Gesamt ${kb(Buffer.byteLength(out))}`)
}

main().catch((error) => {
  console.error('Einzeldatei-Build fehlgeschlagen:', error)
  process.exitCode = 1
})
