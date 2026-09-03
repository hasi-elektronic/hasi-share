/// <reference types="vite/client" />

/**
 * Zusätzliche Build-Schalter. `VITE_SINGLE_FILE` wird nur von
 * `npm run build:single` gesetzt — der Fassung, die alles in eine einzelne
 * HTML-Datei packt (Kundenvorführung ohne Server oder Netz).
 */
interface ImportMetaEnv {
  readonly VITE_SINGLE_FILE?: string
}
