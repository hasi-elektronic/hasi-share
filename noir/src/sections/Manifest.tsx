import { useEffect, useRef } from 'react'
import { motion } from 'framer-motion'
import { gsap } from '@/app/gsap'
import { useAppEnv } from '@/app/appContext'
import { SplitWords } from '@/lib/splitText'
import { collectWords } from '@/lib/wordMask'
import { MANIFEST } from '@/data/manifest'
import { EASE_NOIR } from '@/lib/motion'

/**
 * Gepinnte Haltung in drei Sätzen.
 *
 * Die Sätze liegen übereinander; der Scroll schiebt sie einzeln durch ihre
 * Wortmasken hinein und wieder hinaus. Bei reduzierter Bewegung wird nichts
 * gepinnt — die Sätze stehen dann schlicht untereinander.
 */
export function Manifest() {
  const sectionRef = useRef<HTMLElement>(null)
  const stageRef = useRef<HTMLDivElement>(null)
  const counterRef = useRef<HTMLSpanElement>(null)
  const railRef = useRef<HTMLSpanElement>(null)
  const { reducedMotion } = useAppEnv()

  useEffect(() => {
    if (reducedMotion) return
    const section = sectionRef.current
    const stage = stageRef.current
    if (!section || !stage) return

    const ctx = gsap.context(() => {
      const blocks = gsap.utils.toArray<HTMLElement>('[data-statement]')

      // Startzustand: alles unten in der Maske, nur der erste Block sichtbar.
      blocks.forEach((block, index) => {
        gsap.set(block, { autoAlpha: index === 0 ? 1 : 0 })
        gsap.set(collectWords(block), { yPercent: 115 })
      })

      const timeline = gsap.timeline({
        defaults: { ease: 'power3.out' },
        scrollTrigger: {
          trigger: section,
          start: 'top top',
          end: 'bottom bottom',
          scrub: 1,
          pin: stage,
          pinSpacing: false,
          anticipatePin: 1,
          onUpdate: (self) => {
            if (railRef.current) railRef.current.style.transform = `scaleX(${self.progress})`
            if (counterRef.current) {
              const current = Math.min(MANIFEST.length, Math.floor(self.progress * MANIFEST.length) + 1)
              counterRef.current.textContent = String(current).padStart(2, '0')
            }
          },
        },
      })

      blocks.forEach((block, index) => {
        const words = collectWords(block)
        const caption = block.querySelector('[data-caption]')

        if (index > 0) timeline.set(block, { autoAlpha: 1 })
        timeline.to(words, { yPercent: 0, duration: 1, stagger: 0.035 })
        if (caption) timeline.fromTo(caption, { opacity: 0 }, { opacity: 1, duration: 0.5 }, '<0.3')
        timeline.to({}, { duration: 0.8 })

        // Der letzte Satz bleibt stehen, bis die Sektion verlassen wird.
        if (index < blocks.length - 1) {
          if (caption) timeline.to(caption, { opacity: 0, duration: 0.3 })
          timeline.to(words, { yPercent: -115, duration: 0.8, stagger: 0.025 }, '<')
          timeline.set(block, { autoAlpha: 0 })
        }
      })
    }, section)

    return () => ctx.revert()
  }, [reducedMotion])

  if (reducedMotion) {
    return (
      <section id="manifest" className="shell section-y" aria-label="Unsere Haltung">
        <ul className="space-y-24">
          {MANIFEST.map((statement, index) => (
            <li key={statement.text}>
              <motion.div
                initial={{ opacity: 0 }}
                whileInView={{ opacity: 1 }}
                viewport={{ once: true, amount: 0.4 }}
                transition={{ duration: 0.6, ease: EASE_NOIR }}
              >
                <span className="label label-accent">{String(index + 1).padStart(2, '0')}</span>
                <p className="display mt-6 text-[clamp(2rem,7vw,5.5rem)] italic text-ink">
                  {statement.text.split('|').join(' ')}
                </p>
                <p className="mt-6 max-w-[46ch] text-sm text-muted">{statement.caption}</p>
              </motion.div>
            </li>
          ))}
        </ul>
      </section>
    )
  }

  return (
    <section
      ref={sectionRef}
      id="manifest"
      aria-label="Unsere Haltung"
      // Drei Bildschirmhöhen Scrollweg für drei Sätze.
      className="relative h-[340svh]"
    >
      <div ref={stageRef} className="flex h-[100svh] items-center overflow-hidden">
        <div className="relative mx-auto w-full max-w-shell px-gutter">
          <div className="pointer-events-none absolute -top-24 left-gutter flex items-baseline gap-3">
            <span ref={counterRef} className="font-display text-2xl text-accent">
              01
            </span>
            <span className="label">/ 0{MANIFEST.length}</span>
          </div>

          {/* Alle Sätze liegen in derselben Rasterzelle — der längste
              bestimmt die Höhe, nichts springt beim Wechsel. */}
          <div className="grid">
            {MANIFEST.map((statement) => (
              <div key={statement.text} data-statement className="[grid-area:1/1]">
                <p className="display text-[clamp(2rem,7.5vw,6rem)] italic text-ink">
                  <SplitWords text={statement.text} />
                </p>
                <p data-caption className="mt-10 max-w-[44ch] text-sm text-muted opacity-0">
                  {statement.caption}
                </p>
              </div>
            ))}
          </div>

          <div className="absolute -bottom-28 left-gutter right-gutter h-px bg-hairline">
            <span
              ref={railRef}
              className="block h-px w-full origin-left bg-accent"
              style={{ transform: 'scaleX(0)' }}
            />
          </div>
        </div>
      </div>
    </section>
  )
}
