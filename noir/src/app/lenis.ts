import Lenis from 'lenis'
import { gsap, ScrollTrigger, registerGsap } from './gsap'

let instance: Lenis | null = null

const tick = (time: number): void => {
  // GSAP tickt in Sekunden, Lenis erwartet Millisekunden.
  instance?.raf(time * 1000)
}

/**
 * Lenis ist die einzige RAF-Schleife der Seite: sie treibt sich selbst über den
 * GSAP-Ticker und meldet jeden Scroll an ScrollTrigger weiter. Dadurch laufen
 * Smoothing und Scroll-Animationen garantiert im selben Frame.
 */
export function initLenis(reducedMotion: boolean): Lenis | null {
  registerGsap()

  if (reducedMotion) {
    destroyLenis()
    return null
  }
  if (instance) return instance

  instance = new Lenis({
    duration: 1.1,
    easing: (t: number) => Math.min(1, 1.001 - Math.pow(2, -10 * t)),
    orientation: 'vertical',
    gestureOrientation: 'vertical',
    smoothWheel: true,
    wheelMultiplier: 1,
    touchMultiplier: 1.6,
  })

  instance.on('scroll', ScrollTrigger.update)
  gsap.ticker.add(tick)
  return instance
}

export function destroyLenis(): void {
  if (!instance) return
  gsap.ticker.remove(tick)
  instance.destroy()
  instance = null
}

export function getLenis(): Lenis | null {
  return instance
}

export function lockLenis(): void {
  instance?.stop()
}

export function unlockLenis(): void {
  instance?.start()
}

/** Scrollt zu einem Anker — mit Lenis weich, ohne Lenis sofort. */
export function scrollToId(id: string, offset = 0): void {
  const target = document.getElementById(id)
  if (!target) return

  if (instance) {
    instance.scrollTo(target, { offset, duration: 1.4 })
  } else {
    target.scrollIntoView({ behavior: 'auto', block: 'start' })
  }
}

export function scrollToTop(): void {
  if (instance) {
    instance.scrollTo(0, { duration: 1.2 })
  } else {
    window.scrollTo(0, 0)
  }
}
