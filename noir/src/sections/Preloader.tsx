import { useEffect, useRef, useState } from 'react'
import { gsap } from '@/app/gsap'
import { hasSeenIntro, markIntroDone } from '@/app/intro'
import { useAppEnv } from '@/app/appContext'

/**
 * Zähler 0 → 100 in Messing, Schriftzug schiebt sich über eine Clip-Maske
 * herein, danach fährt der Vorhang nach oben.
 *
 * Läuft höchstens einmal pro Session und bei reduzierter Bewegung gar nicht.
 */
export function Preloader() {
  const { reducedMotion } = useAppEnv()
  const [skip] = useState(() => reducedMotion || hasSeenIntro())
  const rootRef = useRef<HTMLDivElement>(null)
  const counterRef = useRef<HTMLSpanElement>(null)
  const markRef = useRef<HTMLDivElement>(null)
  const barRef = useRef<HTMLSpanElement>(null)

  useEffect(() => {
    if (skip) {
      document.documentElement.removeAttribute('data-preloading')
      markIntroDone()
      return
    }

    document.documentElement.setAttribute('data-preloading', 'true')
    const counter = { value: 0 }

    const timeline = gsap.timeline({
      defaults: { ease: 'power3.out' },
      onComplete: () => {
        document.documentElement.removeAttribute('data-preloading')
        markIntroDone()
      },
    })

    timeline
      .to(counter, {
        value: 100,
        duration: 1.5,
        ease: 'power2.inOut',
        onUpdate: () => {
          if (counterRef.current) {
            counterRef.current.textContent = String(Math.round(counter.value)).padStart(3, '0')
          }
        },
      })
      .to(barRef.current, { scaleX: 1, duration: 1.5, ease: 'power2.inOut' }, 0)
      // Schriftzug von unten in die Maske schieben.
      .fromTo(
        markRef.current,
        { clipPath: 'inset(100% 0% 0% 0%)', yPercent: 12 },
        { clipPath: 'inset(0% 0% 0% 0%)', yPercent: 0, duration: 0.9 },
        0.55,
      )
      .to([counterRef.current, barRef.current], { opacity: 0, duration: 0.4 }, 1.6)
      .to(markRef.current, { opacity: 0, duration: 0.5 }, 1.85)
      // Vorhang nach oben.
      .to(
        rootRef.current,
        {
          clipPath: 'inset(0% 0% 100% 0%)',
          duration: 1,
          ease: 'expo.inOut',
        },
        1.95,
      )
      .set(rootRef.current, { display: 'none' })

    return () => {
      timeline.kill()
      document.documentElement.removeAttribute('data-preloading')
    }
  }, [skip])

  if (skip) return null

  return (
    <div
      ref={rootRef}
      // Rein dekorativ: der Screenreader liest bereits die Seite dahinter.
      aria-hidden="true"
      className="fixed inset-0 z-[95] flex flex-col items-center justify-center bg-bg"
      style={{ clipPath: 'inset(0% 0% 0% 0%)' }}
    >
      <div ref={markRef} className="text-center">
        <span className="font-display text-[clamp(2.5rem,9vw,5rem)] tracking-[0.42em] text-ink">
          NOIR
        </span>
        <span className="label mt-4 block tracking-[0.32em]">Fine Dining · Stuttgart</span>
      </div>

      <div className="absolute bottom-10 left-0 right-0 px-gutter">
        <div className="mx-auto flex w-full max-w-shell items-end justify-between">
          <span
            ref={counterRef}
            className="font-display text-[clamp(2rem,6vw,3.5rem)] leading-none text-accent"
          >
            000
          </span>
          <span className="label">Wird gedeckt</span>
        </div>
        <div className="mx-auto mt-5 h-px w-full max-w-shell bg-hairline">
          <span
            ref={barRef}
            className="block h-px w-full origin-left scale-x-0 bg-accent"
            style={{ transform: 'scaleX(0)' }}
          />
        </div>
      </div>
    </div>
  )
}
