import { useEffect, useState } from 'react'
import { AnimatePresence } from 'framer-motion'
import { Link, useLocation } from 'react-router-dom'
import { Wordmark } from './Wordmark'
import { MenuOverlay } from './MenuOverlay'
import { useSectionNav } from '@/lib/useSectionNav'

/**
 * Minimale Leiste: Schriftzug links, Reservieren + Menü rechts.
 * Ab 80 px Scroll legt sich eine unscharfe Fläche darunter.
 */
export function Nav() {
  const [open, setOpen] = useState(false)
  const [condensed, setCondensed] = useState(false)
  const goToSection = useSectionNav()
  const { pathname } = useLocation()

  useEffect(() => {
    const onScroll = () => setCondensed(window.scrollY > 80)
    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  // Ein Routenwechsel schließt das Overlay immer.
  useEffect(() => setOpen(false), [pathname])

  return (
    <>
      <header
        className={`fixed inset-x-0 top-0 z-[80] transition-colors duration-700 ease-noir ${
          condensed && !open ? 'border-b border-hairline bg-bg/80 backdrop-blur-md' : ''
        }`}
      >
        <div className="mx-auto flex h-20 w-full max-w-shell items-center justify-between px-gutter sm:h-24">
          <Link
            to="/"
            aria-label="NOIR — zur Startseite"
            data-cursor="Start"
            className="relative z-[75]"
          >
            <Wordmark />
          </Link>

          <div className="relative z-[75] flex items-center gap-3 sm:gap-6">
            <button
              type="button"
              onClick={() => {
                setOpen(false)
                goToSection('reservierung')
              }}
              data-cursor="Reservieren"
              className="hidden border border-accent px-6 py-3 text-[0.7rem] uppercase tracking-label text-accent transition-colors duration-500 ease-noir hover:bg-accent hover:text-bg sm:inline-flex"
            >
              Tisch reservieren
            </button>

            <button
              type="button"
              onClick={() => setOpen((value) => !value)}
              aria-expanded={open}
              aria-controls="hauptmenue"
              aria-label={open ? 'Menü schließen' : 'Menü öffnen'}
              data-cursor={open ? 'Schließen' : 'Menü'}
              className="flex h-11 w-11 flex-col items-center justify-center gap-[7px]"
            >
              <span
                className={`block h-px w-7 bg-ink transition-transform duration-500 ease-noir ${
                  open ? 'translate-y-[4px] rotate-45' : ''
                }`}
              />
              <span
                className={`block h-px w-7 bg-ink transition-transform duration-500 ease-noir ${
                  open ? '-translate-y-[4px] -rotate-45' : ''
                }`}
              />
            </button>
          </div>
        </div>
      </header>

      <div id="hauptmenue">
        <AnimatePresence>
          {open ? <MenuOverlay onClose={() => setOpen(false)} onNavigate={goToSection} /> : null}
        </AnimatePresence>
      </div>
    </>
  )
}
