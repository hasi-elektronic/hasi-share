import { Suspense, lazy, useRef, useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { Picture } from '@/components/Picture'
import { useAppEnv } from '@/app/appContext'
import { useCanvasActive } from '@/three/useCanvasActive'
import { EASE_NOIR, fadeUp, viewportOnce } from '@/lib/motion'
import { GALLERY } from '@/data/gallery'
import { HOTSPOTS } from '@/data/room'

const Lightbox = lazy(() => import('@/components/Lightbox'))
const RoomScene = lazy(() => import('@/three/RoomScene'))

type Tab = 'galerie' | 'raum'

const TABS: { id: Tab; label: string; hint: string }[] = [
  { id: 'galerie', label: 'Galerie', hint: 'Neun Aufnahmen aus dem Haus' },
  { id: 'raum', label: 'Der Raum', hint: 'Dreidimensional begehbar' },
]

export function Gallery() {
  const [tab, setTab] = useState<Tab>('galerie')
  const [openIndex, setOpenIndex] = useState<number | null>(null)
  const [hotspotId, setHotspotId] = useState<string | null>(null)

  const { allow3D, reducedMotion } = useAppEnv()
  const canvasWrapRef = useRef<HTMLDivElement>(null)
  const canvasActive = useCanvasActive(canvasWrapRef)

  const hotspot = HOTSPOTS.find((entry) => entry.id === hotspotId) ?? null

  return (
    <section id="galerie" aria-labelledby="galerie-titel" className="section-y">
      <div className="mx-auto w-full max-w-shell px-gutter">
        <div className="flex flex-wrap items-end justify-between gap-8 border-b border-hairline pb-6">
          <div>
            <p className="label label-accent">Einblick</p>
            <h2 id="galerie-titel" className="display mt-4 text-[clamp(2rem,5vw,3.5rem)]">
              Das Haus
            </h2>
          </div>

          <div role="tablist" aria-label="Ansicht wählen" className="flex gap-px bg-hairline">
            {TABS.map((entry) => {
              const selected = tab === entry.id
              return (
                <button
                  key={entry.id}
                  type="button"
                  role="tab"
                  id={`tab-${entry.id}`}
                  aria-selected={selected}
                  aria-controls={`panel-${entry.id}`}
                  onClick={() => setTab(entry.id)}
                  data-cursor="Ansehen"
                  className={`px-6 py-3 text-[0.7rem] uppercase tracking-label transition-colors duration-500 ease-noir ${
                    selected ? 'bg-accent text-bg' : 'bg-bg text-muted hover:text-ink'
                  }`}
                >
                  {entry.label}
                </button>
              )
            })}
          </div>
        </div>

        {/* --- Galerie ------------------------------------------------------ */}
        <div
          role="tabpanel"
          id="panel-galerie"
          aria-labelledby="tab-galerie"
          hidden={tab !== 'galerie'}
          className="mt-12"
        >
          {/* Echtes Masonry über CSS-Spalten — kein Skript, kein Nachmessen. */}
          <div className="columns-1 gap-4 sm:columns-2 sm:gap-6 lg:columns-3">
            {GALLERY.map((item, index) => (
              <motion.div
                key={item.bild.name}
                variants={fadeUp}
                initial="hidden"
                whileInView="visible"
                viewport={viewportOnce}
                custom={index % 3}
                className="mb-4 break-inside-avoid sm:mb-6"
              >
                <button
                  type="button"
                  onClick={() => setOpenIndex(index)}
                  data-cursor="Ansehen"
                  aria-label={`${item.titel} vergrößern`}
                  className="group block w-full text-left"
                >
                  <motion.div layoutId={`galerie-${item.bild.name}`} className="overflow-hidden">
                    <Picture
                      image={item.bild}
                      sizes="(min-width: 1024px) 30vw, (min-width: 640px) 46vw, 92vw"
                      className="w-full"
                      imgClassName="transition-transform duration-[1200ms] ease-noir group-hover:scale-[1.05]"
                    />
                  </motion.div>

                  <div className="mt-3 flex items-baseline justify-between gap-4 overflow-hidden">
                    <span className="font-display text-lg text-ink">{item.titel}</span>
                    <span className="translate-y-3 text-xs text-muted opacity-0 transition-all duration-500 ease-noir group-hover:translate-y-0 group-hover:opacity-100">
                      {item.bildunterschrift}
                    </span>
                  </div>
                </button>
              </motion.div>
            ))}
          </div>
        </div>

        {/* --- Der Raum ----------------------------------------------------- */}
        <div
          role="tabpanel"
          id="panel-raum"
          aria-labelledby="tab-raum"
          hidden={tab !== 'raum'}
          className="mt-12"
        >
          <div className="grid gap-8 lg:grid-cols-12">
            <div
              ref={canvasWrapRef}
              className="relative aspect-[4/3] w-full overflow-hidden border border-hairline bg-elevated lg:col-span-8 lg:aspect-[16/10]"
            >
              {tab === 'raum' && allow3D ? (
                <Suspense fallback={<RoomFallback />}>
                  <RoomScene
                    active={canvasActive}
                    autoRotate={!reducedMotion}
                    selectedId={hotspotId}
                    onSelect={setHotspotId}
                  />
                </Suspense>
              ) : (
                <RoomFallback withNotice={!allow3D} />
              )}

              <p className="label pointer-events-none absolute bottom-4 left-4 text-[0.6rem]">
                Ziehen zum Drehen · Scrollen zum Zoomen
              </p>
            </div>

            {/* Infokarte zum gewählten Punkt — bewusst außerhalb des Canvas,
                damit sie im DOM lesbar und fokussierbar bleibt. */}
            <div className="lg:col-span-4">
              <AnimatePresence mode="wait">
                <motion.div
                  key={hotspot?.id ?? 'leer'}
                  initial={{ opacity: 0, y: 16 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0, y: -12 }}
                  transition={{ duration: 0.45, ease: EASE_NOIR }}
                  aria-live="polite"
                >
                  {hotspot ? (
                    <>
                      <p className="label label-accent">Ausgewählt</p>
                      <h3 className="display mt-4 text-3xl">{hotspot.titel}</h3>
                      <p className="mt-5 text-sm leading-relaxed text-muted">{hotspot.text}</p>
                      <button
                        type="button"
                        onClick={() => setHotspotId(null)}
                        className="label link-underline mt-8 hover:text-accent"
                      >
                        Auswahl aufheben
                      </button>
                    </>
                  ) : (
                    <>
                      <p className="label label-accent">Drei Orte</p>
                      <h3 className="display mt-4 text-3xl">Wo Sie sitzen</h3>
                      <p className="mt-5 text-sm leading-relaxed text-muted">
                        Zwölf Plätze auf fünf Tischen. Wählen Sie einen der markierten Punkte im
                        Raum — oder direkt aus der Liste.
                      </p>
                    </>
                  )}
                </motion.div>
              </AnimatePresence>

              <ul className="mt-10 border-t border-hairline">
                {HOTSPOTS.map((entry) => (
                  <li key={entry.id} className="border-b border-hairline">
                    <button
                      type="button"
                      onClick={() => setHotspotId(entry.id)}
                      aria-pressed={hotspotId === entry.id}
                      data-cursor="Ansehen"
                      className={`flex w-full items-center justify-between py-4 text-left transition-colors duration-500 ease-noir ${
                        hotspotId === entry.id ? 'text-accent' : 'text-ink hover:text-accent'
                      }`}
                    >
                      <span className="font-display text-lg">{entry.titel}</span>
                      <span aria-hidden="true" className="label">
                        +
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            </div>
          </div>
        </div>
      </div>

      <AnimatePresence>
        {openIndex !== null ? (
          <Suspense fallback={null}>
            <Lightbox
              items={GALLERY}
              index={openIndex}
              onClose={() => setOpenIndex(null)}
              onNavigate={setOpenIndex}
            />
          </Suspense>
        ) : null}
      </AnimatePresence>
    </section>
  )
}

/** Fällt ein, solange die Szene lädt — oder wenn das Gerät sie nicht trägt. */
function RoomFallback({ withNotice = false }: { withNotice?: boolean }) {
  return (
    <div className="flex h-full w-full flex-col items-center justify-center gap-4 bg-elevated px-8 text-center">
      <span className="h-10 w-10 rounded-full border border-accent/40 border-t-accent motion-safe:animate-spin" />
      <p className="label">
        {withNotice
          ? 'Die 3-D-Ansicht benötigt WebGL2. Die Galerie zeigt denselben Raum als Foto.'
          : 'Raum wird geladen'}
      </p>
    </div>
  )
}
