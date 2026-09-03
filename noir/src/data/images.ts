import { LQIP } from './generated-lqip'

/** Bildbeschreibung, wie sie `scripts/fetch-images.mjs` erzeugt. */
export type ImageAsset = {
  /** Dateiname ohne Breite und Endung, z. B. "dish-01". */
  name: string
  alt: string
  /** Intrinsische Maße der größten Variante — verhindert Layout-Shift. */
  width: number
  height: number
  /** Winziges Base64-WebP als Blur-Platzhalter. */
  lqip: string
}

/** Die Breiten, die das Bildskript erzeugt. */
export const IMAGE_WIDTHS = [640, 1280, 1920] as const

/** Neutraler dunkler Platzhalter, falls das Bildskript noch nicht lief. */
const FALLBACK_LQIP =
  'data:image/svg+xml;charset=utf-8,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%274%27 height=%273%27%3E%3Crect width=%274%27 height=%273%27 fill=%27%23141416%27/%3E%3C/svg%3E'

/** Baut einen Bildeintrag und zieht die Blur-Vorschau aus der generierten Tabelle. */
export function asset(name: string, alt: string, width: number, height: number): ImageAsset {
  return { name, alt, width, height, lqip: LQIP[name] ?? FALLBACK_LQIP }
}
