import sharp from 'sharp'

/**
 * Erzeugt ein prozedurales Ersatzbild im Stil der Seite: dunkler Stein mit
 * einem warmen Lichtkegel und weichen Schlieren. Kein Foto — aber es trägt
 * die Stimmung, statt ein leeres Kästchen zu hinterlassen.
 *
 * Gerechnet wird in kleiner Auflösung und anschließend hochskaliert. Das ist
 * schnell und ergibt genau die weiche Unschärfe, die hier gewünscht ist.
 */

/** Deterministischer 32-Bit-Hash — gleicher Name, gleiches Bild. */
function hash(text) {
  let value = 2166136261
  for (let i = 0; i < text.length; i += 1) {
    value ^= text.charCodeAt(i)
    value = Math.imul(value, 16777619)
  }
  return value >>> 0
}

/** Kleiner, seed-basierter Zufallsgenerator (mulberry32). */
function rng(seed) {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/** HSL → RGB, beide im Bereich 0…1 beziehungsweise 0…255. */
function hslToRgb(h, s, l) {
  const c = (1 - Math.abs(2 * l - 1)) * s
  const hp = (((h % 360) + 360) % 360) / 60
  const x = c * (1 - Math.abs((hp % 2) - 1))
  const [r1, g1, b1] =
    hp < 1 ? [c, x, 0] : hp < 2 ? [x, c, 0] : hp < 3 ? [0, c, x] : hp < 4 ? [0, x, c] : hp < 5 ? [x, 0, c] : [c, 0, x]
  const m = l - c / 2
  return [Math.round((r1 + m) * 255), Math.round((g1 + m) * 255), Math.round((b1 + m) * 255)]
}

/**
 * @param {{ name: string, width: number, height: number, hue?: number }} spec
 * @returns {Promise<Buffer>} PNG-Puffer in der angegebenen Größe
 */
export async function makePlaceholder(spec) {
  const seed = hash(spec.name)
  const random = rng(seed)

  // Die Palette bleibt eng: warmes Kerzenlicht, für Fensterszenen ein kühler
  // Ton. Ein bunter Fleck wäre schlimmer als gar kein Bild.
  const raw_hue = spec.hue ?? 32
  const kuehl = raw_hue > 170 && raw_hue < 260
  const hue = kuehl ? 206 + (raw_hue % 7) : 22 + (raw_hue % 17)

  // Grob rechnen, fein skalieren.
  const gw = 128
  const gh = Math.max(24, Math.round((gw * spec.height) / spec.width))
  const raw = Buffer.alloc(gw * gh * 3)

  // Mehrere kleine, elliptische Lichtquellen statt eines großen Flecks.
  const lights = Array.from({ length: 3 + Math.floor(random() * 2) }, () => ({
    x: 0.12 + random() * 0.76,
    y: 0.1 + random() * 0.7,
    rx: 0.09 + random() * 0.14,
    ry: 0.06 + random() * 0.13,
    i: 0.3 + random() * 0.5,
  }))

  for (let y = 0; y < gh; y += 1) {
    for (let x = 0; x < gw; x += 1) {
      const u = x / gw
      const v = y / gh

      // Grundton: fast schwarzer, leicht warmer Stein.
      let light = 0.022 + 0.012 * Math.sin(u * 6.3 + seed) * Math.cos(v * 4.1 + seed * 0.5)

      for (const source of lights) {
        const dx = (u - source.x) / source.rx
        const dy = (v - source.y) / source.ry
        light += source.i * Math.exp(-(dx * dx + dy * dy) / 2) * 0.2
      }

      // Vignette plus abfallendes Licht nach unten — wie eine Tischkante.
      const vignette = 1 - 0.9 * Math.pow(Math.hypot(u - 0.5, v - 0.5) * 1.45, 2.2)
      const fall = 1 - 0.35 * Math.pow(Math.max(0, v - 0.45) / 0.55, 1.6)
      light = Math.max(0.01, light * Math.max(0.04, vignette) * fall)

      // Je heller, desto wärmer — aber nie bunt.
      const saturation = Math.min(kuehl ? 0.16 : 0.26, 0.06 + light * 0.7)
      const [r, g, b] = hslToRgb(hue, saturation, Math.min(0.38, light))

      const index = (y * gw + x) * 3
      raw[index] = r
      raw[index + 1] = g
      raw[index + 2] = b
    }
  }

  return sharp(raw, { raw: { width: gw, height: gh, channels: 3 } })
    .resize(spec.width, spec.height, { fit: 'fill', kernel: 'cubic' })
    .blur(Math.max(2, spec.width / 200))
    .png()
    .toBuffer()
}
