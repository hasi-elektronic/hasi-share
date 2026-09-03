import { useEffect, useState } from 'react'

/**
 * Kleiner Signalgeber zwischen Preloader und Hero: der Hero darf erst
 * animieren, wenn der Vorhang oben ist. Beim zweiten Besuch in derselben
 * Session entfällt der Preloader — dann ist das Signal sofort gesetzt.
 */
const STORAGE_KEY = 'noir:intro-seen'
const EVENT = 'noir:intro-done'

let done = false

export function hasSeenIntro(): boolean {
  try {
    return sessionStorage.getItem(STORAGE_KEY) === '1'
  } catch {
    // Privater Modus o. Ä. — dann läuft der Preloader eben jedes Mal.
    return false
  }
}

export function markIntroDone(): void {
  done = true
  try {
    sessionStorage.setItem(STORAGE_KEY, '1')
  } catch {
    /* kein Speicher verfügbar, egal */
  }
  window.dispatchEvent(new Event(EVENT))
}

export function useIntroReady(): boolean {
  const [ready, setReady] = useState(() => done || hasSeenIntro())

  useEffect(() => {
    if (ready) return
    const onDone = () => setReady(true)
    window.addEventListener(EVENT, onDone)
    return () => window.removeEventListener(EVENT, onDone)
  }, [ready])

  return ready
}
