import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter, HashRouter } from 'react-router-dom'

// Selbst gehostete Schriften — keine Laufzeit-Anfrage an Google Fonts (DSGVO).
import '@fontsource/cormorant-garamond/latin-300.css'
import '@fontsource/cormorant-garamond/latin-300-italic.css'
import '@fontsource/cormorant-garamond/latin-400.css'
import '@fontsource/cormorant-garamond/latin-400-italic.css'
import '@fontsource/cormorant-garamond/latin-600.css'
import '@fontsource/inter/latin-400.css'
import '@fontsource/inter/latin-500.css'

import './styles/tokens.css'
import './styles/globals.css'

import { Providers } from './app/Providers'
import { App } from './app/App'

const container = document.getElementById('root')
if (!container) throw new Error('Root-Element nicht gefunden.')

// Die Einzeldatei-Fassung läuft ohne Server: dort kann kein Pfad-Routing
// funktionieren, /impressum liegt dann hinter #/impressum.
const Router = import.meta.env.VITE_SINGLE_FILE === 'true' ? HashRouter : BrowserRouter

createRoot(container).render(
  <StrictMode>
    <Router>
      <Providers>
        <App />
      </Providers>
    </Router>
  </StrictMode>,
)
