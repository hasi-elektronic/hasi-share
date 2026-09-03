import { motion } from 'framer-motion'
import { EASE_NOIR } from '@/lib/motion'

/**
 * Die Signatur wird beim Eintritt gezeichnet: `pathLength` von 0 auf 1
 * entspricht der klassischen stroke-dashoffset-Animation, nur ohne
 * Handarbeit an den Dash-Werten.
 */
export function Signature({ className = '' }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 260 74"
      fill="none"
      role="img"
      aria-label="Unterschrift von Elias Roth"
      className={className}
    >
      <motion.path
        d="M14 54c10-24 18-38 27-40 7-1 8 6 3 12-6 7-16 11-24 12 12 1 24-1 34-6M62 40c-3 6-6 12-7 17 4-1 9-6 13-12M74 24c1 0 2 0 2 1M84 46c4-2 8-7 10-12-4 6-6 12-4 14 3 3 9-2 13-9-3 7-3 12 1 12 5 0 11-9 13-17-2 8-1 14 3 14 6 0 12-11 12-21 0-6-3-8-6-5-4 4-5 15-2 22M150 60c2-18 6-33 11-42 4-7 9-6 9 1 0 8-8 15-17 17 6 0 10 4 12 10 2 5 5 8 9 6M196 44c-5 1-9 6-9 11 0 4 3 6 7 5 6-2 10-9 10-15-1 6 1 10 5 10 5 0 9-6 11-13M222 40c-4 8-6 14-5 17M216 30h14M238 52c2-9 5-15 8-17 3-1 4 2 3 6"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
        initial={{ pathLength: 0, opacity: 0 }}
        whileInView={{ pathLength: 1, opacity: 1 }}
        viewport={{ once: true, amount: 0.6 }}
        transition={{ pathLength: { duration: 2.4, ease: EASE_NOIR }, opacity: { duration: 0.2 } }}
      />
    </svg>
  )
}
