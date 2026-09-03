import { useEffect } from 'react'
import { useLocation } from 'react-router-dom'
import { PageTransition } from '@/components/PageTransition'
import { scrollToId } from '@/app/lenis'

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
      <main id="inhalt">
        <section className="flex min-h-screen items-center justify-center">
          <p className="label">Aufbau läuft</p>
        </section>
      </main>
    </PageTransition>
  )
}
