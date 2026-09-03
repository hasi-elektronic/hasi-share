import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'
import sharp from 'sharp'
import { WIDTHS } from '../image-manifest.mjs'

const OUT_DIR = path.resolve('public/img')
const LQIP_MODULE = path.resolve('src/data/generated-lqip.ts')

/**
 * Schreibt alle Breitenvarianten als WebP und liefert die Base64-Vorschau
 * (LQIP) zurück, die im Blur-Platzhalter steckt.
 *
 * @param {{ name: string, width: number, height: number }} spec
 * @param {Buffer} input
 * @returns {Promise<string>} data:-URI der Vorschau
 */
export async function emitVariants(spec, input) {
  await mkdir(OUT_DIR, { recursive: true })

  const aspect = spec.height / spec.width

  await Promise.all(
    WIDTHS.map(async (width) => {
      const height = Math.round(width * aspect)
      const buffer = await sharp(input)
        .resize(width, height, { fit: 'cover', position: 'centre' })
        // Effort 5 ist der brauchbare Kompromiss aus Dateigröße und Laufzeit.
        .webp({ quality: 72, effort: 5 })
        .toBuffer()
      await writeFile(path.join(OUT_DIR, `${spec.name}-${width}.webp`), buffer)
    }),
  )

  const lqip = await sharp(input)
    .resize(20, Math.max(1, Math.round(20 * aspect)), { fit: 'cover' })
    .webp({ quality: 28 })
    .toBuffer()

  return `data:image/webp;base64,${lqip.toString('base64')}`
}

/** Schreibt die generierte LQIP-Tabelle, die src/data/images.ts einliest. */
export async function writeLqipModule(entries) {
  const body = Object.keys(entries)
    .sort()
    .map((key) => `  '${key}':\n    '${entries[key]}',`)
    .join('\n')

  const source = `/**
 * AUTOMATISCH ERZEUGT — nicht von Hand bearbeiten.
 * Wird von \`npm run images\` (scripts/fetch-images.mjs) neu geschrieben.
 */
export const LQIP: Record<string, string> = {
${body}
}
`
  await writeFile(LQIP_MODULE, source, 'utf8')
}
