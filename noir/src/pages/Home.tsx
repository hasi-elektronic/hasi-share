import { useEffect } from 'react'
import { useLocation } from 'react-router-dom'
import { PageTransition } from '@/components/PageTransition'
import { scrollToId } from '@/app/lenis'
import { Preloader } from '@/sections/Preloader'
import { Hero } from '@/sections/Hero'
import { Manifest } from '@/sections/Manifest'
import { Menu } from '@/sections/Menu'
import { Chef } from '@/sections/Chef'
import { Gallery } from '@/sections/Gallery'
import { Reservation } from '@/sections/Reservation'

export function Home() {
  const location = useLocation()

  // Von /impressum kommend: Ziel-Sektion aus dem Router-State anspringen.
  useEffect(() => {
    const state = location.state as { scrollTo?: string } | null
    if (!state?.scrollTo) return
    const id = state.scrollTo
    const timer = window.setTimeout(() => scrollToId(id), 120)
    return () => window.clearTimeout(timer)
  }, [location.state])

  return (
    <PageTransition>
      <Preloader />
      <main id="inhalt">
        <Hero />
        <Manifest />
        <Menu />
        <Chef />
        <Gallery />
        <Reservation />
      </main>
    </PageTransition>
  )
}
