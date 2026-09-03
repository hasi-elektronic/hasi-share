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
    rollupOptions: {
      output: {
        // Keep three.js + R3F out of the initial chunk. They are only ever
        // pulled in by the lazily mounted WebGL scenes.
        manualChunks(id) {
          if (id.includes('node_modules')) {
            if (/three|@react-three/.test(id)) return 'three'
            if (/gsap/.test(id)) return 'gsap'
            if (/framer-motion/.test(id)) return 'motion'
          }
          return undefined
        },
      },
    },
  },
})
