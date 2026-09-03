import { gsap } from 'gsap'
import { ScrollTrigger } from 'gsap/ScrollTrigger'

let registered = false

/** Plugins genau einmal registrieren — auch bei HMR. */
export function registerGsap(): void {
  if (registered) return
  gsap.registerPlugin(ScrollTrigger)
  // Lenis liefert die Zeitbasis; GSAP darf keine Frames "nachholen".
  gsap.ticker.lagSmoothing(0)
  gsap.defaults({ ease: 'power3.out', duration: 1 })
  registered = true
}

export { gsap, ScrollTrigger }
