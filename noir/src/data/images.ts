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
