import type { Transition, Variants } from 'framer-motion'

/** Nichts federt zurück — eine einzige Kurve für die ganze Seite. */
export const EASE_NOIR: [number, number, number, number] = [0.16, 1, 0.3, 1]

export const transition = (duration = 0.8, delay = 0): Transition => ({
  duration,
  delay,
  ease: EASE_NOIR,
})

export const fadeUp: Variants = {
  hidden: { opacity: 0, y: 24 },
  visible: (custom: number = 0) => ({
    opacity: 1,
    y: 0,
    transition: transition(1, custom * 0.08),
  }),
}

export const fade: Variants = {
  hidden: { opacity: 0 },
  visible: { opacity: 1, transition: transition(0.9) },
}

export const staggerParent: Variants = {
  hidden: {},
  visible: { transition: { staggerChildren: 0.07, delayChildren: 0.1 } },
}

/** Wird für Sektionen genutzt, die einmalig beim Eintritt erscheinen. */
export const viewportOnce = { once: true, amount: 0.25 } as const
