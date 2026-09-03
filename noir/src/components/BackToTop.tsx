import { useEffect, useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { scrollToTop } from '@/app/lenis'
import { EASE_NOIR } from '@/lib/motion'

/** Erscheint erst, wenn wirklich weit gescrollt wurde — sonst ist es Deko. */
export function BackToTop() {
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    const onScroll = () => setVisible(window.scrollY > window.innerHeight * 2)
    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  return (
    <AnimatePresence>
      {visible ? (
        <motion.button
          type="button"
          onClick={scrollToTop}
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: 12 }}
          transition={{ duration: 0.5, ease: EASE_NOIR }}
          data-cursor="Nach oben"
          aria-label="Zurück nach oben"
          className="fixed bottom-6 right-6 z-40 flex h-12 w-12 items-center justify-center border border-hairline bg-bg/70 text-accent backdrop-blur transition-colors duration-500 ease-noir hover:border-accent"
        >
          <svg viewBox="0 0 16 16" className="h-4 w-4" fill="none" stroke="currentColor">
            <path d="M8 13V3M3.5 7.5 8 3l4.5 4.5" strokeWidth="1" />
          </svg>
        </motion.button>
      ) : null}
    </AnimatePresence>
  )
}
