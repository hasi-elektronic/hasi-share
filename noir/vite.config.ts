import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { fileURLToPath, URL } from 'node:url'

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  build: {
    target: 'es2020',
    cssTarget: 'safari15',
    assetsInlineLimit: 2048,
    // Kein manualChunks: die dynamischen Imports der WebGL-Szenen erzeugen von
    // sich aus eigene Chunks. Eine erzwungene Aufteilung zog React in den
    // three.js-Chunk und ließ ihn dadurch beim ersten Laden mitgeladen werden.
    chunkSizeWarningLimit: 1200,
  },
})
