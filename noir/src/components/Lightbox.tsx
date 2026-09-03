import { useCallback, useEffect, useRef } from 'react'
import { motion } from 'framer-motion'
import { Picture } from './Picture'
import { EASE_NOIR } from '@/lib/motion'
import { useFocusTrap } from '@/lib/useFocusTrap'
import { useScrollLock } from '@/lib/useScrollLock'
import type { GalleryItem } from '@/data/gallery'

type LightboxProps = {
  items: GalleryItem[]
  index: number
  onClose: () => void
  onNavigate: (nextIndex: number) => void
}

/**
 * Vollbildansicht mit geteiltem Element: das angeklickte Bild wandert über
 * `layoutId` aus dem Raster in die Mitte. Fokus bleibt gefangen, Escape und
 * die Pfeiltasten funktionieren, der Hintergrund scrollt nicht mit.
 */
export default function Lightbox({ items, index, onClose, onNavigate }: LightboxProps) {
  const panelRef = useRef<HTMLDivElement>(null)
  useFocusTrap(panelRef, true, onClose)
  useScrollLock(true)

  const item = items[index]
  const total = items.length

  const go = useCallback(
    (direction: 1 | -1) => {
      onNavigate((index + direction + total) % total)
    },
    [index, onNavigate, total],
  )

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'ArrowRight') {
        event.preventDefault()
        go(1)
      } else if (event.key === 'ArrowLeft') {
        event.preventDefault()
        go(-1)
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [go])

  if (!item) return null

  return (
    <motion.div
      ref={panelRef}
      role="dialog"
      aria-modal="true"
      aria-label={`Galerie, Bild ${index + 1} von ${total}: ${item.titel}`}
      tabIndex={-1}
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={{ duration: 0.35, ease: EASE_NOIR }}
      className="fixed inset-0 z-[85] flex flex-col bg-bg/97 backdrop-blur-sm"
    >
      <div className="flex items-center justify-between border-b border-hairline px-gutter py-5">
        <p className="label">
          {String(index + 1).padStart(2, '0')} / {String(total).padStart(2, '0')}
        </p>
        <button
          type="button"
          onClick={onClose}
          data-cursor="Schließen"
          className="label link-underline hover:text-accent"
        >
          Schließen
        </button>
      </div>

      <div className="flex min-h-0 flex-1 items-center justify-center px-gutter py-6">
        <motion.figure
          layoutId={`galerie-${item.bild.name}`}
          transition={{ duration: 0.6, ease: EASE_NOIR }}
          className="flex max-h-full w-full max-w-4xl flex-col"
        >
          <Picture
            image={item.bild}
            priority
            sizes="(min-width: 1024px) 56rem, 92vw"
            className="max-h-[62vh] w-full"
            imgClassName="max-h-[62vh] object-contain"
          />
          <figcaption className="mt-5 flex flex-wrap items-baseline justify-between gap-3">
            <span className="font-display text-xl text-ink">{item.titel}</span>
            <span className="text-sm text-muted">{item.bildunterschrift}</span>
          </figcaption>
        </motion.figure>
      </div>

      <div className="flex items-center justify-between border-t border-hairline px-gutter py-5">
        <button
          type="button"
          onClick={() => go(-1)}
          data-cursor="Zurück"
          className="label link-underline hover:text-accent"
        >
          ← Vorheriges
        </button>
        <button
          type="button"
          onClick={() => go(1)}
          data-cursor="Weiter"
          className="label link-underline hover:text-accent"
        >
          Nächstes →
        </button>
      </div>
    </motion.div>
  )
}
