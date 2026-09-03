import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { fileURLToPath, URL } from 'node:url'

/**
 * Build-Fassung für die Einzeldatei-Vorführung.
 *
 * Alles landet in einem Bündel: keine dynamischen Chunks, kein getrenntes
 * CSS, Schriften als data-URI. `scripts/build-single.mjs` fügt anschließend
 * die Bilder hinzu und schreibt die fertige HTML-Datei.
 */
export default defineConfig({
  plugins: [react()],
  define: {
    'import.meta.env.VITE_SINGLE_FILE': JSON.stringify('true'),
  },
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  build: {
    outDir: 'dist-single',
    emptyOutDir: true,
    target: 'es2020',
    cssTarget: 'safari15',
    // Schriften und sonstige Assets vollständig einbetten.
    assetsInlineLimit: 100_000_000,
    cssCodeSplit: false,
    chunkSizeWarningLimit: 4000,
    rollupOptions: {
      output: {
        // Ohne Server gibt es keine Adresse, von der ein Chunk nachgeladen
        // werden könnte — also alles in eine Datei.
        inlineDynamicImports: true,
      },
    },
  },
})
