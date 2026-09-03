import { useEffect, useRef } from 'react'
import { motion } from 'framer-motion'
import { gsap } from '@/app/gsap'
import { useAppEnv } from '@/app/appContext'
import { Picture } from '@/components/Picture'
import { Signature } from '@/components/Signature'
import { EASE_NOIR, fadeUp, viewportOnce } from '@/lib/motion'
import { chef, chefHands, chefPortrait } from '@/data/chef'

/**
 * Küchenchef & Geschichte.
 *
 * Asymmetrisch: das Porträt läuft in einer eigenen Spalte langsamer mit als
 * der Text daneben. Beim Hover verliert es seine Entsättigung.
 */
export function Chef() {
  const sectionRef = useRef<HTMLElement>(null)
  const portraitRef = useRef<HTMLDivElement>(null)
  const { reducedMotion } = useAppEnv()

  useEffect(() => {
    if (reducedMotion) return
    const section = sectionRef.current
    const portrait = portraitRef.current
    if (!section || !portrait) return

    const ctx = gsap.context(() => {
      // Sanfte Parallaxe — das Bild bewegt sich gegen die Leserichtung.
      gsap.fromTo(
        portrait,
        { yPercent: -6 },
        {
          yPercent: 8,
          ease: 'none',
          scrollTrigger: {
            trigger: section,
            start: 'top bottom',
            end: 'bottom top',
            scrub: true,
          },
        },
      )
    }, section)

    return () => ctx.revert()
  }, [reducedMotion])

  return (
    <section ref={sectionRef} id="chef" aria-labelledby="chef-titel" className="section-y relative">
      <div className="mx-auto w-full max-w-shell px-gutter">
        <div className="grid gap-12 lg:grid-cols-12 lg:gap-16">
          {/* --- Porträt ---------------------------------------------------- */}
          <div className="lg:col-span-5">
            <div className="group relative overflow-hidden">
              <div ref={portraitRef} className="will-change-transform">
                <Picture
                  image={chefPortrait}
                  sizes="(min-width: 1024px) 40vw, 100vw"
                  className="aspect-[4/5]"
                  imgClassName="grayscale transition-[filter,transform] duration-[1200ms] ease-noir group-hover:grayscale-0 group-hover:scale-[1.03]"
                />
              </div>
              <span
                aria-hidden="true"
                className="pointer-events-none absolute inset-0 bg-gradient-to-t from-bg/70 via-transparent to-transparent"
              />
            </div>

            <div className="mt-6 flex items-baseline justify-between border-t border-hairline pt-5">
              <p className="label">{chef.rolle}</p>
              <p className="font-display text-lg text-accent">{chef.name}</p>
            </div>
          </div>

          {/* --- Text ------------------------------------------------------- */}
          <div className="lg:col-span-6 lg:col-start-7">
            <motion.p
              variants={fadeUp}
              initial="hidden"
              whileInView="visible"
              viewport={viewportOnce}
              className="label label-accent"
            >
              Der Küchenchef
            </motion.p>

            <motion.h2
              variants={fadeUp}
              initial="hidden"
              whileInView="visible"
              viewport={viewportOnce}
              custom={1}
              id="chef-titel"
              className="display mt-6 text-[clamp(2.5rem,7vw,5rem)]"
            >
              Elias Roth
            </motion.h2>

            <div className="mt-10 space-y-6">
              {chef.absaetze.map((absatz, index) => (
                <motion.p
                  key={absatz.slice(0, 24)}
                  variants={fadeUp}
                  initial="hidden"
                  whileInView="visible"
                  viewport={viewportOnce}
                  custom={index + 2}
                  className="max-w-[58ch] text-pretty leading-relaxed text-muted"
                >
                  {absatz}
                </motion.p>
              ))}
            </div>

            {/* Pull-Quote */}
            <motion.blockquote
              initial={{ opacity: 0 }}
              whileInView={{ opacity: 1 }}
              viewport={viewportOnce}
              transition={{ duration: 1, ease: EASE_NOIR }}
              className="my-14 border-l border-accent pl-8"
            >
              <p className="display text-[clamp(1.5rem,3.4vw,2.5rem)] italic leading-tight text-ink">
                „{chef.zitat}“
              </p>
            </motion.blockquote>

            <Signature className="h-16 w-56 text-accent" />
          </div>
        </div>

        {/* --- Zeitleiste ---------------------------------------------------- */}
        <div className="mt-24 border-t border-hairline pt-16 sm:mt-32">
          <h3 className="label label-accent">Stationen</h3>
          <ol className="mt-12 grid gap-px bg-hairline sm:grid-cols-2 lg:grid-cols-4">
            {chef.milestones.map((milestone, index) => (
              <motion.li
                key={milestone.jahr}
                variants={fadeUp}
                initial="hidden"
                whileInView="visible"
                viewport={viewportOnce}
                custom={index}
                className="bg-bg p-6 sm:p-8"
              >
                <p className="font-display text-[clamp(2.5rem,5vw,3.5rem)] leading-none text-accent">
                  {milestone.jahr}
                </p>
                <p className="label mt-4">{milestone.ort}</p>
                <p className="mt-4 text-sm leading-relaxed text-muted">{milestone.text}</p>
              </motion.li>
            ))}
          </ol>
        </div>

        {/* --- Breites Zwischenbild ------------------------------------------ */}
        <div className="mt-24 sm:mt-32">
          <Picture
            image={chefHands}
            sizes="100vw"
            className="aspect-[16/9] w-full sm:aspect-[21/9]"
          />
          <p className="label mt-4">Am Pass, kurz vor dem vierten Gang</p>
        </div>
      </div>
    </section>
  )
}
