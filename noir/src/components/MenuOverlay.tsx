import { useRef } from 'react'
import { motion } from 'framer-motion'
import { Link } from 'react-router-dom'
import { EASE_NOIR } from '@/lib/motion'
import { useFocusTrap } from '@/lib/useFocusTrap'
import { useScrollLock } from '@/lib/useScrollLock'
import { SECTION_LINKS } from '@/lib/useSectionNav'

type MenuOverlayProps = {
  onClose: () => void
  onNavigate: (id: string) => void
}

const listItem = {
  hidden: { y: '110%' },
  visible: (index: number) => ({
    y: '0%',
    transition: { duration: 1, delay: 0.15 + index * 0.06, ease: EASE_NOIR },
  }),
}

export function MenuOverlay({ onClose, onNavigate }: MenuOverlayProps) {
  const panelRef = useRef<HTMLDivElement>(null)
  useFocusTrap(panelRef, true, onClose)
  useScrollLock(true)

  const go = (id: string) => {
    onClose()
    // Erst schließen, dann scrollen — sonst kämpft der Scroll-Lock dagegen.
    window.setTimeout(() => onNavigate(id), 260)
  }

  return (
    <motion.div
      ref={panelRef}
      role="dialog"
      aria-modal="true"
      aria-label="Hauptmenü"
      tabIndex={-1}
      initial={{ clipPath: 'inset(0% 0% 100% 0%)' }}
      animate={{ clipPath: 'inset(0% 0% 0% 0%)', transition: { duration: 0.9, ease: EASE_NOIR } }}
      exit={{ clipPath: 'inset(0% 0% 100% 0%)', transition: { duration: 0.6, ease: EASE_NOIR } }}
      className="fixed inset-0 z-[70] flex flex-col justify-between bg-bg px-gutter pb-10 pt-28 sm:pt-32"
    >
      <nav aria-label="Sektionen">
        <ul className="mx-auto w-full max-w-shell">
          {SECTION_LINKS.map((link, index) => (
            <li key={link.id} className="overflow-hidden border-b border-hairline">
              <motion.button
                type="button"
                custom={index}
                variants={listItem}
                initial="hidden"
                animate="visible"
                onClick={() => go(link.id)}
                data-cursor="Ansehen"
                className="group flex w-full items-baseline gap-6 py-4 text-left sm:py-6"
              >
                <span className="label w-8 shrink-0 text-accent">
                  {String(index + 1).padStart(2, '0')}
                </span>
                <span className="display text-[clamp(2rem,8vw,4.5rem)] text-ink transition-colors duration-500 ease-noir group-hover:text-accent">
                  {link.label}
                </span>
              </motion.button>
            </li>
          ))}
        </ul>
      </nav>

      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1, transition: { delay: 0.6, duration: 0.8, ease: EASE_NOIR } }}
        className="mx-auto flex w-full max-w-shell flex-col gap-6 sm:flex-row sm:items-end sm:justify-between"
      >
        <address className="not-italic text-sm leading-relaxed text-muted">
          Königstraße 12 · 70173 Stuttgart
          <br />
          <a href="tel:+497119028440" className="link-underline hover:text-ink">
            +49 711 9028440
          </a>
        </address>

        <ul className="flex flex-wrap gap-x-8 gap-y-2">
          <li>
            <Link to="/impressum" onClick={onClose} className="label link-underline hover:text-ink">
              Impressum
            </Link>
          </li>
          <li>
            <Link
              to="/datenschutz"
              onClick={onClose}
              className="label link-underline hover:text-ink"
            >
              Datenschutz
            </Link>
          </li>
        </ul>
      </motion.div>
    </motion.div>
  )
}
