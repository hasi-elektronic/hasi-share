#!/usr/bin/env node
/**
 * Erzeugt das Vorschaubild für soziale Netzwerke (public/og.jpg, 1200×630)
 * und das Touch-Icon (public/apple-touch-icon.png, 180×180).
 *
 *   npm run og
 *
 * Als Hintergrund dient das Hero-Bild aus public/img. Nach einem Lauf von
 * `npm run images` mit echten Fotos also einfach erneut ausführen — dann
 * steckt das richtige Foto in der Vorschau.
 */
import { access } from 'node:fs/promises'
import path from 'node:path'
import sharp from 'sharp'

const HERO = path.resolve('public/img/hero-poster-1280.webp')
const OG = path.resolve('public/og.jpg')
const TOUCH = path.resolve('public/apple-touch-icon.png')

const W = 1200
const H = 630

// Serif-Familien, die auf den meisten Systemen vorhanden sind. Das Rendering
// hier ist nur für die Vorschaukarte — die Website selbst nutzt Cormorant.
const SERIF = 'Liberation Serif, DejaVu Serif, Georgia, serif'
const SANS = 'Liberation Sans, DejaVu Sans, Helvetica, sans-serif'

const overlay = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
  <defs>
    <linearGradient id="veil" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#0A0A0B" stop-opacity="0.55"/>
      <stop offset="55%" stop-color="#0A0A0B" stop-opacity="0.82"/>
      <stop offset="100%" stop-color="#0A0A0B" stop-opacity="0.97"/>
    </linearGradient>
  </defs>
  <rect width="${W}" height="${H}" fill="url(#veil)"/>
  <circle cx="${W / 2}" cy="150" r="27" fill="none" stroke="#C8A96A" stroke-width="1.5" opacity="0.85"/>
  <text x="${W / 2}" y="272" text-anchor="middle" font-family="${SERIF}"
        font-size="72" letter-spacing="28" fill="#F4F1EA">NOIR</text>
  <text x="${W / 2}" y="326" text-anchor="middle" font-family="${SANS}"
        font-size="18" letter-spacing="7" fill="#C8A96A">FINE DINING · STUTTGART</text>
  <line x1="${W / 2 - 170}" y1="392" x2="${W / 2 + 170}" y2="392" stroke="#C8A96A" stroke-width="1" opacity="0.5"/>
  <text x="${W / 2}" y="462" text-anchor="middle" font-family="${SERIF}"
        font-size="42" font-style="italic" fill="#F4F1EA">Sieben Gänge. Ein Abend.</text>
  <text x="${W / 2}" y="540" text-anchor="middle" font-family="${SANS}"
        font-size="16" letter-spacing="5" fill="#9A968E">DEGUSTATIONSMENÜ · 185 €</text>
</svg>`

const icon = `<svg xmlns="http://www.w3.org/2000/svg" width="180" height="180">
  <rect width="180" height="180" rx="28" fill="#0A0A0B"/>
  <circle cx="90" cy="90" r="59" fill="none" stroke="#C8A96A" stroke-width="5"/>
  <path d="M70 118V62l40 56V62" fill="none" stroke="#F4F1EA" stroke-width="9"
        stroke-linecap="square"/>
</svg>`

const exists = async (file) => {
  try {
    await access(file)
    return true
  } catch {
    return false
  }
}

async function main() {
  const base = (await exists(HERO))
    ? sharp(HERO).resize(W, H, { fit: 'cover', position: 'centre' })
    : sharp({ create: { width: W, height: H, channels: 3, background: '#0A0A0B' } })

  await base
    .composite([{ input: Buffer.from(overlay), top: 0, left: 0 }])
    .jpeg({ quality: 86, mozjpeg: true })
    .toFile(OG)

  await sharp(Buffer.from(icon)).png().toFile(TOUCH)

  console.log(`og.jpg (${W}×${H}) und apple-touch-icon.png geschrieben.`)
}

main().catch((error) => {
  console.error('OG-Bild fehlgeschlagen:', error)
  process.exitCode = 1
})
