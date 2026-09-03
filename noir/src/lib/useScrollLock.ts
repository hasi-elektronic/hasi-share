import { useEffect } from 'react'
import { lockLenis, unlockLenis } from '@/app/lenis'

let lockCount = 0

/**
 * Sperrt das Scrollen, solange mindestens ein Overlay offen ist.
 * Zählt Sperren mit, damit sich Lightbox und Menü nicht gegenseitig aufheben.
 */
export function useScrollLock(active: boolean): void {
  useEffect(() => {
    if (!active) return
    lockCount += 1
    document.body.dataset['scrollLocked'] = 'true'
    lockLenis()

    return () => {
      lockCount = Math.max(0, lockCount - 1)
      if (lockCount === 0) {
        delete document.body.dataset['scrollLocked']
        unlockLenis()
      }
    }
  }, [active])
}
