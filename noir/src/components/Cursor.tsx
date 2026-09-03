import { useEffect, useRef } from 'react'
import { useAppEnv } from '@/app/appContext'

/**
 * Punkt + nachlaufender Ring. Der Ring interpoliert in einer eigenen
 * RAF-Schleife, damit kein React-State pro Mausbewegung geschrieben wird.
 * Auf Touch-Geräten und bei reduzierter Bewegung wird gar nichts gemountet.
 */
export function Cursor() {
  const { coarsePointer, reducedMotion } = useAppEnv()
  const dotRef = useRef<HTMLDivElement>(null)
  const ringRef = useRef<HTMLDivElement>(null)
  const labelRef = useRef<HTMLSpanElement>(null)
  const enabled = !coarsePointer && !reducedMotion

  useEffect(() => {
    if (!enabled) return
    const dot = dotRef.current
    const ring = ringRef.current
    const label = labelRef.current
    if (!dot || !ring || !label) return

    document.body.classList.add('has-custom-cursor')

    const pointer = { x: window.innerWidth / 2, y: window.innerHeight / 2 }
    const ringPos = { ...pointer }
    let frame = 0
    let visible = false

    const onMove = (event: PointerEvent) => {
      pointer.x = event.clientX
      pointer.y = event.clientY
      if (!visible) {
        visible = true
        dot.style.opacity = '1'
        ring.style.opacity = '1'
      }
    }

    const onLeave = () => {
      visible = false
      dot.style.opacity = '0'
      ring.style.opacity = '0'
    }

    // Delegation statt Listener pro Element: [data-cursor] setzt den Text.
    const onOver = (event: PointerEvent) => {
      const target = (event.target as HTMLElement | null)?.closest<HTMLElement>('[data-cursor]')
      const interactive = (event.target as HTMLElement | null)?.closest(
        'a, button, input, select, textarea, [role="button"]',
      )
      const text = target?.dataset['cursor'] ?? ''
      label.textContent = text
      ring.dataset['state'] = text ? 'labelled' : interactive ? 'active' : 'idle'
    }

    const loop = () => {
      // Weiche Verfolgung: 0.16 fühlt sich schwer an, ohne zu schleppen.
      ringPos.x += (pointer.x - ringPos.x) * 0.16
      ringPos.y += (pointer.y - ringPos.y) * 0.16
      dot.style.transform = `translate3d(${pointer.x}px, ${pointer.y}px, 0)`
      ring.style.transform = `translate3d(${ringPos.x}px, ${ringPos.y}px, 0)`
      frame = requestAnimationFrame(loop)
    }
    frame = requestAnimationFrame(loop)

    window.addEventListener('pointermove', onMove, { passive: true })
    window.addEventListener('pointerover', onOver, { passive: true })
    document.addEventListener('pointerleave', onLeave)

    return () => {
      cancelAnimationFrame(frame)
      window.removeEventListener('pointermove', onMove)
      window.removeEventListener('pointerover', onOver)
      document.removeEventListener('pointerleave', onLeave)
      document.body.classList.remove('has-custom-cursor')
    }
  }, [enabled])

  if (!enabled) return null

  return (
    <div aria-hidden="true" className="pointer-events-none fixed inset-0 z-[90]">
      <div
        ref={dotRef}
        className="absolute left-0 top-0 h-1 w-1 -translate-x-1/2 -translate-y-1/2 rounded-full bg-accent opacity-0 transition-opacity duration-300"
        style={{ marginLeft: '-2px', marginTop: '-2px' }}
      />
      <div
        ref={ringRef}
        data-state="idle"
        className="cursor-ring absolute left-0 top-0 flex items-center justify-center rounded-full border border-accent/60 opacity-0"
      >
        <span ref={labelRef} className="cursor-label label label-accent whitespace-nowrap" />
      </div>
    </div>
  )
}
