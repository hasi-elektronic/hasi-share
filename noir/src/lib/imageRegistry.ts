declare global {
  interface Window {
    /**
     * Bild-Register der Einzeldatei-Fassung: Schlüssel „name-breite“,
     * Wert eine data-URI. Wird dort von einem eingebetteten Skript gesetzt,
     * bevor das Bundle startet.
     */
    __NOIR_IMG__?: Record<string, string>
  }
}

/**
 * Liefert die Adresse einer Bildvariante.
 *
 * Im Normalfall ist das schlicht der Pfad unter /img. Läuft die Seite als
 * einzelne HTML-Datei (ohne Server, etwa als Anhang beim Kunden), gibt es
 * keinen /img-Ordner — dann steht das Bild als data-URI im Register.
 */
export function resolveImageSrc(name: string, width: number): string {
  const path = `/img/${name}-${width}.webp`
  if (typeof window === 'undefined') return path
  return window.__NOIR_IMG__?.[`${name}-${width}`] ?? path
}
