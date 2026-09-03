import { useMediaQuery } from './useMediaQuery'

/** true, wenn das System weniger Bewegung anfordert. */
export function useReducedMotion(): boolean {
  return useMediaQuery('(prefers-reduced-motion: reduce)')
}

/** true auf Geräten ohne feinen Zeiger (Touch) — Cursor & Hover entfallen dort. */
export function useIsCoarsePointer(): boolean {
  return useMediaQuery('(hover: none), (pointer: coarse)')
}
