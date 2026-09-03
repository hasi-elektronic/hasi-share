import { Suspense, lazy, useEffect, useRef } from 'react'
import { gsap, ScrollTrigger } from '@/app/gsap'
import { setHeroProgress } from '@/app/sceneProgress'
import { useAppEnv } from '@/app/appContext'
import { useIntroReady } from '@/app/intro'
import { useCanvasActive } from '@/three/useCanvasActive'
import { SplitWords } from '@/lib/splitText'
import { collectWords } from '@/lib/wordMask'
import { Picture } from '@/components/Picture'
import { scrollToId } from '@/app/lenis'
import { heroCopy, heroPoster } from '@/data/hero'

// three.js landet in einem eigenen Chunk und wird erst hier angefordert.
const HeroScene = lazy(() => import('@/three/HeroScene'))

export function Hero() {
  const sectionRef = useRef<HTMLElement>(null)
  const stageRef = useRef<HTMLDivElement>(null)
  const headlineRef = useRef<HTMLHeadingElement>(null)
  const introRef = useRef<HTMLDivElement>(null)

  const { allow3D, reducedMotion } = useAppEnv()
  const introReady = useIntroReady()
  const canvasActive = useCanvasActive(stageRef)

  // Scroll-Fortschritt für die 3D-Szene + Weggleiten des Textes.
  useEffect(() => {
    const section = sectionRef.current
    if (!section) return

    const ctx = gsap.context(() => {
      ScrollTrigger.create({
        trigger: section,
        start: 'top top',
        end: 'bottom top',
        scrub: true,
        onUpdate: (self) => setHeroProgress(self.progress),
      })

      if (reducedMotion) return

      gsap.to(introRef.current, {
        yPercent: -18,
        opacity: 0,
        ease: 'none',
        scrollTrigger: {
          trigger: section,
          start: 'top top',
          end: '60% top',
          scrub: true,
        },
      })
    }, section)

    return () => {
      ctx.revert()
      setHeroProgress(0)
    }
  }, [reducedMotion])

  // Auftritt: Wörter steigen aus ihrer Maske, sobald der Vorhang oben ist.
  useEffect(() => {
    if (!introReady) return
    const headline = headlineRef.current
    const words = collectWords(headline)

    if (reducedMotion) {
      gsap.set(words, { yPercent: 0, opacity: 1 })
      gsap.set('[data-hero-fade]', { opacity: 1, y: 0 })
      return
    }

    const timeline = gsap.timeline({ defaults: { ease: 'power3.out' } })
    timeline
      .fromTo(words, { yPercent: 115 }, { yPercent: 0, duration: 1.3, stagger: 0.055 })
      .fromTo(
        '[data-hero-fade]',
        { opacity: 0, y: 20 },
        { opacity: 1, y: 0, duration: 1, stagger: 0.12 },
        '-=0.85',
      )

    return () => {
      timeline.kill()
    }
  }, [introReady, reducedMotion])

  return (
    <section
      ref={sectionRef}
      id="hero"
      aria-labelledby="hero-titel"
      className="relative min-h-[100svh] w-full overflow-hidden"
    >
      {/* --- Bühne: WebGL oder Standbild ---------------------------------- */}
      <div ref={stageRef} className="absolute inset-0 z-0">
        {allow3D ? (
          <Suspense fallback={<HeroPoster />}>
            <HeroScene active={canvasActive} />
          </Suspense>
        ) : (
          <HeroPoster />
        )}
      </div>

      {/* Verlauf, damit die Schrift auf jedem Untergrund lesbar bleibt. */}
      <div
        aria-hidden="true"
        className="absolute inset-0 z-10 bg-[radial-gradient(120%_90%_at_50%_10%,transparent_0%,rgb(var(--bg-rgb)/0.55)_65%,rgb(var(--bg-rgb)/0.95)_100%)]"
      />

      {/* --- Inhalt ------------------------------------------------------- */}
      <div
        ref={introRef}
        className="relative z-20 mx-auto flex min-h-[100svh] w-full max-w-shell flex-col justify-end px-gutter pb-24 pt-32 sm:pb-28"
      >
        <p data-hero-fade className="label label-accent mb-8 opacity-0">
          {heroCopy.eyebrow}
        </p>

        <h1
          ref={headlineRef}
          id="hero-titel"
          className="display max-w-[16ch] text-[clamp(3.5rem,12vw,11rem)] text-ink"
        >
          <SplitWords text={heroCopy.headline} />
        </h1>

        <div className="mt-10 grid gap-10 md:grid-cols-12 md:items-end">
          <p
            data-hero-fade
            className="max-w-[46ch] text-pretty text-base leading-relaxed text-muted opacity-0 md:col-span-6 lg:col-span-5"
          >
            {heroCopy.lead}
          </p>

          <div
            data-hero-fade
            className="flex flex-wrap items-center gap-x-10 gap-y-5 opacity-0 md:col-span-6 md:justify-end lg:col-span-7"
          >
            <button
              type="button"
              onClick={() => scrollToId('reservierung')}
              data-cursor="Reservieren"
              className="group relative inline-flex items-center justify-center overflow-hidden border border-accent px-8 py-4 text-[0.7rem] uppercase tracking-label text-accent transition-colors duration-500 ease-noir hover:text-bg"
            >
              <span
                aria-hidden="true"
                className="absolute inset-0 origin-bottom scale-y-0 bg-accent transition-transform duration-[600ms] ease-noir group-hover:scale-y-100"
              />
              <span className="relative z-10">Tisch reservieren</span>
            </button>

            <button
              type="button"
              onClick={() => scrollToId('menue')}
              data-cursor="Ansehen"
              className="link-underline text-[0.7rem] uppercase tracking-label text-ink transition-colors duration-500 ease-noir hover:text-accent"
            >
              Menü entdecken
            </button>
          </div>
        </div>
      </div>

      {/* --- Scroll-Hinweis ----------------------------------------------- */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 bottom-0 z-20 flex justify-center pb-8"
      >
        <span className="scroll-hint block h-16 w-px bg-gradient-to-b from-transparent via-accent to-transparent" />
      </div>
    </section>
  )
}

/** Statisches Hero-Bild — trägt die Seite, wenn keine Szene läuft. */
function HeroPoster() {
  return (
    <Picture
      image={heroPoster}
      priority
      sizes="100vw"
      className="h-full w-full"
      imgClassName="scale-105"
    />
  )
}
