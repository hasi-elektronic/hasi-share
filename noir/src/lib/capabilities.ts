/**
 * Entscheidet einmalig, ob eine WebGL-Szene überhaupt gemountet werden darf.
 * Das Ergebnis wird gecacht: der Test kostet einen Kontext und soll nicht in
 * jedem Render laufen.
 */
let cached: boolean | null = null

export function supportsWebGL2(): boolean {
  if (cached !== null) return cached
  if (typeof window === 'undefined') return (cached = false)

  try {
    const canvas = document.createElement('canvas')
    const gl = canvas.getContext('webgl2')
    cached = Boolean(gl)
    // Kontext sofort wieder freigeben — Browser limitieren die Anzahl.
    const lose = gl?.getExtension('WEBGL_lose_context')
    lose?.loseContext()
  } catch {
    cached = false
  }
  return cached
}

/** Grobe Geräteklasse. Schwache Geräte bekommen das Poster statt der Szene. */
export function isLowPoweredDevice(): boolean {
  if (typeof navigator === 'undefined') return true
  const cores = navigator.hardwareConcurrency
  if (typeof cores === 'number' && cores < 4) return true
  const memory = (navigator as Navigator & { deviceMemory?: number }).deviceMemory
  if (typeof memory === 'number' && memory < 4) return true
  return false
}

/** Gesamturteil: 3D rendern oder Poster zeigen? */
export function canRender3D(reducedMotion: boolean): boolean {
  if (reducedMotion) return false
  return supportsWebGL2() && !isLowPoweredDevice()
}
