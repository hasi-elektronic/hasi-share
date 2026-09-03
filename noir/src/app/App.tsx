import { useEffect } from 'react'
import { AnimatePresence } from 'framer-motion'
import { Route, Routes, useLocation } from 'react-router-dom'

import { Nav } from '@/components/Nav'
import { Cursor } from '@/components/Cursor'
import { BackToTop } from '@/components/BackToTop'
import { Footer } from '@/sections/Footer'
import { Home } from '@/pages/Home'
import { Impressum } from '@/pages/Impressum'
import { Datenschutz } from '@/pages/Datenschutz'
import { NotFound } from '@/pages/NotFound'
import { ScrollTrigger } from './gsap'
import { getLenis } from './lenis'

export function App() {
  const location = useLocation()

  // Jede Route startet oben — und die Pins müssen danach neu vermessen werden.
  useEffect(() => {
    const lenis = getLenis()
    if (lenis) {
      lenis.scrollTo(0, { immediate: true })
    } else {
      window.scrollTo(0, 0)
    }
    const raf = requestAnimationFrame(() => ScrollTrigger.refresh())
    return () => cancelAnimationFrame(raf)
  }, [location.pathname])

  return (
    <div className="grain relative min-h-screen bg-bg">
      <a
        href="#inhalt"
        className="sr-only focus:not-sr-only focus:fixed focus:left-6 focus:top-6 focus:z-[100] focus:rounded-none focus:border focus:border-accent focus:bg-bg focus:px-5 focus:py-3 focus:text-sm focus:text-accent"
      >
        Zum Inhalt springen
      </a>

      <Cursor />
      <Nav />

      <AnimatePresence mode="wait" initial={false}>
        <Routes location={location} key={location.pathname}>
          <Route path="/" element={<Home />} />
          <Route path="/impressum" element={<Impressum />} />
          <Route path="/datenschutz" element={<Datenschutz />} />
          <Route path="*" element={<NotFound />} />
        </Routes>
      </AnimatePresence>

      <Footer />
      <BackToTop />
    </div>
  )
}
