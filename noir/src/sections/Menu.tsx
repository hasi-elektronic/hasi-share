import { useCallback, useEffect, useRef, useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { gsap } from '@/app/gsap'
import { useAppEnv } from '@/app/appContext'
import { Picture } from '@/components/Picture'
import { EASE_NOIR } from '@/lib/motion'
import { MENU_PRICE, VEGETARIAN_SWAPS, coursesFor, type Course } from '@/data/menu'

/**
 * Das Degustationsmenü — die Signatur-Sektion.
 *
 * Die Bühne wird über sieben Bildschirmhöhen gepinnt; der Scroll bestimmt,
 * welcher Gang in der Mitte steht. Der aktive Index läuft über React-State
 * (er wechselt sieben Mal, nicht pro Frame), die feine Bewegung innerhalb
 * eines Gangs über direkte Stil-Zuweisungen im ScrollTrigger.
 */
export function Menu() {
  const { reducedMotion } = useAppEnv()
  const [vegetarian, setVegetarian] = useState(false)
  const [active, setActive] = useState(0)

  const sectionRef = useRef<HTMLElement>(null)
  const stageRef = useRef<HTMLDivElement>(null)
  const frameRef = useRef<HTMLDivElement>(null)
  const railRef = useRef<HTMLSpanElement>(null)

  const courses = coursesFor(vegetarian)
  const total = courses.length
  const current = courses[active] ?? courses[0]

  useEffect(() => {
    if (reducedMotion) return
    const section = sectionRef.current
    const stage = stageRef.current
    if (!section || !stage) return

    const ctx = gsap.context(() => {
      gsap.timeline({
        scrollTrigger: {
          trigger: section,
          start: 'top top',
          end: 'bottom bottom',
          scrub: true,
          pin: stage,
          pinSpacing: false,
          anticipatePin: 1,
          onUpdate: (self) => {
            const raw = self.progress * total
            const index = Math.min(total - 1, Math.max(0, Math.floor(raw)))
            // setState ist hier billig: React bricht identische Werte ab.
            setActive(index)

            // Feinbewegung innerhalb eines Gangs, ohne Re-Render.
            const within = raw - index
            if (frameRef.current) {
              frameRef.current.style.transform = `translate3d(0, ${(within - 0.5) * -26}px, 0)`
            }
            if (railRef.current) {
              railRef.current.style.transform = `scaleY(${self.progress})`
            }
          },
        },
      })
    }, section)

    return () => ctx.revert()
  }, [reducedMotion, total])

  // Beim Wechsel der Menü-Fassung nicht den Gang verlieren.
  const toggleVegetarian = useCallback(() => setVegetarian((value) => !value), [])

  if (reducedMotion) {
    return (
      <section id="menue" className="shell section-y" aria-labelledby="menue-titel">
        <MenuHeader
          vegetarian={vegetarian}
          onToggle={toggleVegetarian}
          active={0}
          total={total}
          showRail={false}
        />
        <ol className="mt-20 space-y-24">
          {courses.map((course) => (
            <li key={course.nummer} className="grid gap-8 md:grid-cols-12 md:items-center">
              <Picture
                image={course.bild}
                sizes="(min-width: 768px) 40vw, 100vw"
                className="aspect-[4/5] md:col-span-5"
              />
              <div className="md:col-span-7">
                <CourseText course={course} />
              </div>
            </li>
          ))}
        </ol>
        <PriceBlock />
      </section>
    )
  }

  return (
    <>
      <section
        ref={sectionRef}
        id="menue"
        aria-labelledby="menue-titel"
        // Eine Bildschirmhöhe Scrollweg pro Gang.
        style={{ height: `${(total + 1) * 100}svh` }}
        className="relative"
      >
        <div ref={stageRef} className="h-[100svh] overflow-hidden">
          <div className="mx-auto flex h-full w-full max-w-shell flex-col px-gutter pb-10 pt-24 sm:pt-28">
            <MenuHeader
              vegetarian={vegetarian}
              onToggle={toggleVegetarian}
              active={active}
              total={total}
              showRail
            />

            <div className="relative mt-8 grid flex-1 grid-cols-12 items-center gap-6 lg:gap-10">
              {/* Fortschrittsschiene mit sieben Punkten */}
              <div
                aria-hidden="true"
                className="col-span-1 hidden h-full max-h-[60vh] flex-col items-center justify-between md:flex"
              >
                <div className="relative flex h-full w-px justify-center bg-hairline">
                  <span
                    ref={railRef}
                    className="absolute inset-x-0 top-0 h-full origin-top bg-accent"
                    style={{ transform: 'scaleY(0)' }}
                  />
                  <ul className="absolute inset-y-0 flex flex-col justify-between">
                    {courses.map((course, index) => (
                      <li key={course.nummer}>
                        <span
                          className={`block h-1.5 w-1.5 rounded-full transition-all duration-500 ease-noir ${
                            index <= active ? 'bg-accent' : 'bg-hairline'
                          } ${index === active ? 'scale-[2.2]' : ''}`}
                        />
                      </li>
                    ))}
                  </ul>
                </div>
              </div>

              {/* Text */}
              <div className="col-span-12 md:col-span-6 lg:col-span-5">
                <AnimatePresence mode="wait">
                  <motion.div
                    key={`${vegetarian ? 'v' : 'k'}-${current?.nummer ?? '00'}`}
                    initial={{ opacity: 0, y: 28 }}
                    animate={{ opacity: 1, y: 0 }}
                    exit={{ opacity: 0, y: -14 }}
                    // Kurz halten: beim schnellen Scrollen darf der Wechsel
                    // dem Fortschritt nicht hinterherlaufen.
                    transition={{ duration: 0.4, ease: EASE_NOIR }}
                  >
                    {current ? <CourseText course={current} /> : null}
                  </motion.div>
                </AnimatePresence>
              </div>

              {/* Bildrahmen — feste Größe, der Inhalt blendet darin über. */}
              <div className="col-span-12 md:col-span-5 lg:col-span-6">
                <div
                  ref={frameRef}
                  className="relative ml-auto aspect-[4/5] w-full max-w-[26rem] will-change-transform lg:max-w-[32rem]"
                >
                  <span
                    aria-hidden="true"
                    className="absolute -inset-x-4 -inset-y-4 border border-hairline"
                  />
                  <AnimatePresence>
                    {current ? (
                      <motion.div
                        key={current.bild.name}
                        initial={{ opacity: 0, scale: 1.06 }}
                        animate={{ opacity: 1, scale: 1 }}
                        exit={{ opacity: 0 }}
                        transition={{ duration: 0.7, ease: EASE_NOIR }}
                        className="absolute inset-0"
                      >
                        <Picture
                          image={current.bild}
                          sizes="(min-width: 1024px) 32rem, (min-width: 768px) 40vw, 100vw"
                          className="h-full w-full"
                        />
                      </motion.div>
                    ) : null}
                  </AnimatePresence>
                </div>
              </div>
            </div>

            <p className="label mt-6 hidden md:block">
              Gang {String(active + 1).padStart(2, '0')} von {String(total).padStart(2, '0')} ·
              weiterscrollen
            </p>
          </div>
        </div>
      </section>

      <div className="shell pb-section">
        <PriceBlock />
      </div>
    </>
  )
}

/* ------------------------------------------------------------------ Teile */

function MenuHeader({
  vegetarian,
  onToggle,
  active,
  total,
  showRail,
}: {
  vegetarian: boolean
  onToggle: () => void
  active: number
  total: number
  showRail: boolean
}) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-6 border-b border-hairline pb-6">
      <div>
        <p className="label label-accent">Degustationsmenü</p>
        <h2 id="menue-titel" className="display mt-4 text-[clamp(2rem,5vw,3.5rem)]">
          Sieben Gänge
        </h2>
      </div>

      <div className="flex items-center gap-5">
        {showRail ? (
          <span className="label">
            {String(active + 1).padStart(2, '0')} / {String(total).padStart(2, '0')}
          </span>
        ) : null}

        <div className="text-right">
          <button
            type="button"
            role="switch"
            aria-checked={vegetarian}
            onClick={onToggle}
            data-cursor={vegetarian ? 'Klassisch' : 'Vegetarisch'}
            className="group inline-flex items-center gap-3 border border-hairline px-4 py-2.5 transition-colors duration-500 ease-noir hover:border-accent"
          >
            <span
              aria-hidden="true"
              className={`relative block h-3 w-7 border transition-colors duration-500 ease-noir ${
                vegetarian ? 'border-accent' : 'border-hairline'
              }`}
            >
              <span
                className={`absolute top-1/2 block h-1.5 w-1.5 -translate-y-1/2 rounded-full transition-all duration-500 ease-noir ${
                  vegetarian ? 'left-[calc(100%-0.5rem)] bg-accent' : 'left-1 bg-muted'
                }`}
              />
            </span>
            <span
              className={`text-[0.7rem] uppercase tracking-label transition-colors duration-500 ease-noir ${
                vegetarian ? 'text-accent' : 'text-muted group-hover:text-ink'
              }`}
            >
              Vegetarisch
            </span>
          </button>
          <p className="label mt-2 text-[0.55rem] normal-case tracking-normal">
            {VEGETARIAN_SWAPS} von {total} Gängen werden getauscht
          </p>
        </div>
      </div>
    </div>
  )
}

function CourseText({ course }: { course: Course }) {
  return (
    <article>
      <p className="font-display text-[clamp(4rem,11vw,9rem)] leading-[0.8] text-accent">
        {course.nummer}
      </p>
      <h3 className="display mt-6 text-[clamp(1.75rem,3.4vw,2.75rem)] text-ink">{course.name}</h3>
      <p className="mt-5 max-w-[42ch] text-pretty text-sm leading-relaxed text-muted sm:text-base">
        {course.beschreibung}
      </p>
      <dl className="mt-8 space-y-3 border-t border-hairline pt-6">
        <div className="flex gap-4">
          <dt className="label w-24 shrink-0">Herkunft</dt>
          <dd className="text-sm text-ink/80">{course.herkunft}</dd>
        </div>
        <div className="flex gap-4">
          <dt className="label w-24 shrink-0">Begleitung</dt>
          <dd className="text-sm text-ink/80">{course.weinbegleitung}</dd>
        </div>
      </dl>
    </article>
  )
}

function PriceBlock() {
  return (
    <div className="mt-16 border-t border-hairline pt-10 sm:mt-24">
      <div className="flex flex-col gap-8 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="label label-accent">Preis</p>
          <p className="display mt-4 text-[clamp(2rem,6vw,4rem)]">
            Sieben Gänge — {MENU_PRICE.menue}
          </p>
        </div>
        <dl className="space-y-2 text-sm text-muted sm:text-right">
          <div className="flex gap-4 sm:justify-end">
            <dt>Weinbegleitung</dt>
            <dd className="text-ink">{MENU_PRICE.weinbegleitung}</dd>
          </div>
          <div className="flex gap-4 sm:justify-end">
            <dt>Alkoholfreie Begleitung</dt>
            <dd className="text-ink">{MENU_PRICE.alkoholfrei}</dd>
          </div>
          <p className="pt-2 text-xs">Pro Person, inklusive Wasser und Aufschlag. Ohne Trinkgeld.</p>
        </dl>
      </div>
    </div>
  )
}
