import { gsap } from 'gsap'
import { ScrollTrigger } from 'gsap/ScrollTrigger'

/**
 * Registrierung beim Import des Moduls, nicht in einem Effekt.
 *
 * React führt Effekte von innen nach außen aus: der Effekt einer Sektion läuft
 * vor dem des Providers. Eine Registrierung im Provider käme also zu spät —
 * ScrollTrigger.create würde vorher aufgerufen und zur Laufzeit scheitern.
 */
gsap.registerPlugin(ScrollTrigger)

// Lenis liefert die Zeitbasis; GSAP darf keine Frames "nachholen".
gsap.ticker.lagSmoothing(0)
gsap.defaults({ ease: 'power3.out', duration: 1 })

export { gsap, ScrollTrigger }
