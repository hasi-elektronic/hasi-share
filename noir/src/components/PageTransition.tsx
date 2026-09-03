import { motion } from 'framer-motion'
import type { ReactNode } from 'react'
import { EASE_NOIR } from '@/lib/motion'

/**
 * Seitenwechsel: kein Slide, nur ein ruhiges Auf- und Abblenden —
 * schneller beim Verlassen als beim Betreten.
 */
export function PageTransition({ children }: { children: ReactNode }) {
  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1, transition: { duration: 0.6, ease: EASE_NOIR, delay: 0.1 } }}
      exit={{ opacity: 0, transition: { duration: 0.3, ease: 'linear' } }}
    >
      {children}
    </motion.div>
  )
}
