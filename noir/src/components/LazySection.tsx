import { Suspense, useEffect, useRef, useState, type ReactNode } from 'react'
import { ScrollTrigger } from '@/app/gsap'

type LazySectionProps = {
  children: ReactNode
  /** Platzhalterhöhe, bis der Abschnitt geladen ist — verhindert Sprünge. */
  minHeight?: string
  /** Wie früh vor dem Sichtbarwerden geladen wird. */
  rootMargin?: string
  id?: string
}

/**
 * Rendert einen Abschnitt erst, wenn er in die Nähe des Sichtfensters kommt.
 *
 * Für das Reservierungsformular gedacht: react-hook-form und Zod wandern
 * dadurch aus dem Erst-Bundle, ohne dass der Gast je auf sie warten müsste —
 * der Ladevorgang startet mehrere Bildschirmhöhen vorher.
 */
export function LazySection({
  children,
  minHeight = '80svh',
  rootMargin = '800px',
  id,
}: LazySectionProps) {
  const sentinel = useRef<HTMLDivElement>(null)
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    if (visible) return
    const node = sentinel.current
    if (!node || typeof IntersectionObserver === 'undefined') {
      // Ohne Observer lieber sofort laden als gar nicht.
      setVisible(true)
      return
    }

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) setVisible(true)
      },
      { rootMargin },
    )
    observer.observe(node)
    return () => observer.disconnect()
  }, [rootMargin, visible])

  // Der Abschnitt verändert die Seitenhöhe — gepinnte Trigger neu vermessen.
  useEffect(() => {
    if (!visible) return
    const raf = requestAnimationFrame(() => ScrollTrigger.refresh())
    return () => cancelAnimationFrame(raf)
  }, [visible])

  if (visible) return <Suspense fallback={<Platzhalter minHeight={minHeight} />}>{children}</Suspense>

  return (
    <div ref={sentinel} id={id}>
      <Platzhalter minHeight={minHeight} />
    </div>
  )
}

function Platzhalter({ minHeight }: { minHeight: string }) {
  return <div aria-hidden="true" style={{ minHeight }} />
}
