import { useEffect, useState, type RefObject } from 'react'

/**
 * Eine WebGL-Szene darf nur rechnen, wenn sie sichtbar ist: außerhalb des
 * Viewports oder im versteckten Tab wird der Frame-Loop komplett angehalten.
 */
export function useCanvasActive(ref: RefObject<HTMLElement>): boolean {
  const [inView, setInView] = useState(false)
  const [tabVisible, setTabVisible] = useState(
    () => typeof document === 'undefined' || document.visibilityState !== 'hidden',
  )

  useEffect(() => {
    const node = ref.current
    if (!node) return
    if (typeof IntersectionObserver === 'undefined') {
      setInView(true)
      return
    }

    const observer = new IntersectionObserver(
      ([entry]) => setInView(Boolean(entry?.isIntersecting)),
      { rootMargin: '120px' },
    )
    observer.observe(node)
    return () => observer.disconnect()
  }, [ref])

  useEffect(() => {
    const onVisibility = () => setTabVisible(document.visibilityState !== 'hidden')
    document.addEventListener('visibilitychange', onVisibility)
    return () => document.removeEventListener('visibilitychange', onVisibility)
  }, [])

  return inView && tabVisible
}
