import { useEffect, useMemo, useRef, type ReactNode } from 'react'
import { MotionConfig } from 'framer-motion'
import { AppContext, type AppEnv } from './appContext'
import { useIsCoarsePointer, useReducedMotion } from '@/lib/useReducedMotion'
import { canRender3D } from '@/lib/capabilities'
import { destroyLenis, initLenis } from './lenis'
import { ScrollTrigger, registerGsap } from './gsap'
import { setPointer } from './sceneProgress'

export function Providers({ children }: { children: ReactNode }) {
  const reducedMotion = useReducedMotion()
  const coarsePointer = useIsCoarsePointer()
  const resizeTimer = useRef<number | null>(null)

  const env = useMemo<AppEnv>(
    () => ({
      reducedMotion,
      coarsePointer,
      allow3D: canRender3D(reducedMotion),
    }),
    [reducedMotion, coarsePointer],
  )

  // Lenis wird bei jeder Änderung der Bewegungs-Präferenz neu bewertet.
  useEffect(() => {
    registerGsap()
    initLenis(reducedMotion)
    return () => {
      destroyLenis()
    }
  }, [reducedMotion])

  // Pins hängen an gemessenen Höhen. Nach Font-Load und Resize neu vermessen.
  useEffect(() => {
    const refresh = () => ScrollTrigger.refresh()

    const onResize = () => {
      if (resizeTimer.current !== null) window.clearTimeout(resizeTimer.current)
      resizeTimer.current = window.setTimeout(refresh, 200)
    }

    document.fonts?.ready.then(refresh).catch(() => undefined)
    window.addEventListener('resize', onResize)
    window.addEventListener('orientationchange', onResize)

    return () => {
      if (resizeTimer.current !== null) window.clearTimeout(resizeTimer.current)
      window.removeEventListener('resize', onResize)
      window.removeEventListener('orientationchange', onResize)
    }
  }, [])

  // Zeigerposition zentral einsammeln — die 3D-Szene liest sie im Frame-Loop.
  useEffect(() => {
    if (coarsePointer) return
    const onMove = (event: PointerEvent) => {
      setPointer(
        (event.clientX / window.innerWidth) * 2 - 1,
        -((event.clientY / window.innerHeight) * 2 - 1),
      )
    }
    window.addEventListener('pointermove', onMove, { passive: true })
    return () => window.removeEventListener('pointermove', onMove)
  }, [coarsePointer])

  return (
    <AppContext.Provider value={env}>
      <MotionConfig reducedMotion="user">{children}</MotionConfig>
    </AppContext.Provider>
  )
}
