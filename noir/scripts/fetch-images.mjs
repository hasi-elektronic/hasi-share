#!/usr/bin/env node
/**
 * Bildpipeline für NOIR.
 *
 *   npm run images              lädt die Fotos aus scripts/image-manifest.mjs,
 *                               wandelt sie in WebP (640 / 1280 / 1920 px) um
 *                               und schreibt die Blur-Vorschauen
 *   npm run images -- --offline überspringt alle Downloads und erzeugt nur
 *                               prozedurale Platzhalter
 *   npm run images -- --force   lädt auch Bilder neu, die schon vorliegen
 *
 * Das Skript ist absichtlich nachsichtig: Was nicht geladen werden kann,
 * bekommt ein stimmungsgleiches Platzhalterbild, damit die Seite nie mit
 * kaputten Bildern dasteht. Am Ende steht, was tatsächlich passiert ist.
 *
 * Ergebnis nach dem Lauf einchecken: public/img/*.webp und
 * src/data/generated-lqip.ts gehören ins Repository.
 */
import { access } from 'node:fs/promises'
import path from 'node:path'
import { IMAGES, WIDTHS } from './image-manifest.mjs'
import { makePlaceholder } from './lib/placeholder.mjs'
import { emitVariants, writeLqipModule } from './lib/emit.mjs'

const args = new Set(process.argv.slice(2))
const OFFLINE = args.has('--offline')
const FORCE = args.has('--force')
const TIMEOUT_MS = 20000

const exists = async (file) => {
  try {
    await access(file)
    return true
  } catch {
    return false
  }
}

/** Lädt ein Bild in der größten benötigten Breite. */
async function download(url) {
  const target = new URL(url)
  // Unsplash liefert direkt zugeschnitten aus — spart Bandbreite und Zeit.
  target.searchParams.set('w', String(Math.max(...WIDTHS)))
  target.searchParams.set('q', '82')
  target.searchParams.set('fm', 'jpg')
  target.searchParams.set('fit', 'crop')

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS)
  try {
    const response = await fetch(target, {
      signal: controller.signal,
      headers: { 'User-Agent': 'noir-image-script' },
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const type = response.headers.get('content-type') ?? ''
    if (!type.startsWith('image/')) throw new Error(`Unerwarteter Inhalt: ${type || 'unbekannt'}`)
    return Buffer.from(await response.arrayBuffer())
  } finally {
    clearTimeout(timer)
  }
}

async function main() {
  const lqip = {}
  const geladen = []
  const ersetzt = []
  const uebersprungen = []

  for (const spec of IMAGES) {
    const grosseDatei = path.resolve('public/img', `${spec.name}-${Math.max(...WIDTHS)}.webp`)

    if (!FORCE && (await exists(grosseDatei))) {
      // Vorschau trotzdem neu erzeugen, damit die Tabelle vollständig bleibt.
      uebersprungen.push(spec.name)
      lqip[spec.name] = await emitVariants(spec, grosseDatei)
      continue
    }

    let buffer = null
    let grund = ''

    if (!OFFLINE) {
      try {
        buffer = await download(spec.url)
      } catch (error) {
        grund = error instanceof Error ? error.message : String(error)
      }
    }

    if (buffer) {
      geladen.push(spec.name)
    } else {
      buffer = await makePlaceholder(spec)
      ersetzt.push(`${spec.name}${grund ? ` (${grund})` : ''}`)
    }

    lqip[spec.name] = await emitVariants(spec, buffer)
    process.stdout.write(`· ${spec.name}\n`)
  }

  await writeLqipModule(lqip)

  console.log('\n— Bildpipeline abgeschlossen —')
  console.log(`  ${IMAGES.length} Bilder × ${WIDTHS.length} Breiten in public/img/`)
  if (geladen.length) console.log(`  geladen:       ${geladen.length}`)
  if (uebersprungen.length) console.log(`  unveraendert:  ${uebersprungen.length} (mit --force neu laden)`)
  if (ersetzt.length) {
    console.log(`  Platzhalter:   ${ersetzt.length}`)
    for (const eintrag of ersetzt) console.log(`      - ${eintrag}`)
    console.log(
      '\n  Hinweis: Für diese Bilder wurde ein prozeduraler Platzhalter erzeugt.',
    )
    console.log(
      '  Adressen in scripts/image-manifest.mjs pruefen oder ersetzen, dann erneut ausfuehren.',
    )
  }
}

main().catch((error) => {
  console.error('Bildpipeline fehlgeschlagen:', error)
  process.exitCode = 1
})
