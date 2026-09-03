import { useEffect, useState } from 'react'

/**
 * Kleiner Signalgeber zwischen Preloader und Hero: der Hero darf erst
 * animieren, wenn der Vorhang oben ist. Beim zweiten Besuch in derselben
 * Session entfällt der Preloader — dann ist das Signal sofort gesetzt.
 */
const STORAGE_KEY = 'noir:intro-seen'
const EVENT = 'noir:intro-done'

let done = false

/**
 * Solange dieses Attribut gesetzt ist, hält CSS die Wörter der Hero-Zeile in
 * ihrer Maske. Es wird beim Laden des Moduls gesetzt — also vor dem ersten
 * Frame — und beim Abschluss des Intros wieder entfernt. Bleibt JavaScript
 * irgendwo hängen, ist die Überschrift trotzdem lesbar, sobald das Attribut
 * fällt; und wenn es nie gesetzt wird, ist sie von Anfang an sichtbar.
 */
const INTRO_ATTR = 'data-intro'

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
  document.documentElement.removeAttribute(INTRO_ATTR)
  try {
    sessionStorage.setItem(STORAGE_KEY, '1')
  } catch {
    /* kein Speicher verfügbar, egal */
  }
  window.dispatchEvent(new Event(EVENT))
}

/** Wird einmalig beim Import ausgeführt. */
if (typeof document !== 'undefined' && !hasSeenIntro()) {
  document.documentElement.setAttribute(INTRO_ATTR, 'pending')
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
